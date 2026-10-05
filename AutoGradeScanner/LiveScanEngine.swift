import UIKit
import simd

// Live grading session for one bundled demo template: camera frames come in,
// XFeat aligns each against the cached template features, the template's
// answer boxes are projected onto the frame, and per-question verdicts
// accumulate across frames ("掃到哪改到哪"). Alignment runs off the main
// thread at whatever rate it can sustain; frames arriving while busy are
// dropped. Verdicts are canned (demo mode) and lock in once a question has
// been seen in two consecutive aligned frames, so panning across the paper
// fills in colors progressively without flicker.
//
// While locked on, tracking state (last window + last homography) feeds the
// matcher's fast path: one window instead of three, and a least-squares
// refine of the previous solution instead of full RANSAC.
/// What the camera was doing while one frame was exposed.
struct FrameMotion {
    /// How fast it was turning, radians per second; nil when the gyro had no
    /// samples covering that moment (simulator, motion stopped).
    let angularSpeed: Double?
    /// The lens was moving to refocus.
    let isFocusing: Bool
}

@MainActor
final class LiveScanEngine {

    /// The shared three-state verdict. Aliased rather than redeclared so the
    /// state the overlay draws is literally the state the result carries —
    /// it used to be flattened to a bool the moment 完成 was pressed, which
    /// quietly threw the yellow "couldn't read" cells in with the wrong ones.
    typealias Verdict = GradingVerdict

    struct Box: Identifiable {
        let id: Int               // question index
        let quad: [CGPoint]       // projected corners (tl,tr,br,bl), normalized in the upright frame
        let rect: CGRect          // axis-aligned bounds of quad
        let templateRect: CGRect  // the box on the master sheet, in template coordinates
        let verdict: Verdict?     // nil while pending (not yet decided)
        let expectedText: String  // the template's answer, shown on wrong/unsure boxes
        let readText: String?     // what the model actually read, for the debug overlay
        /// Ink groups a single-character cell dropped, most any frame saw.
        /// Zero for everything else. Surfaced so a stray blob that is now
        /// silently discarded is still visible as a thing to fix at source.
        let discarded: Int
        /// How far this cell sits from the keypoints the alignment was fitted
        /// to, in units of how far those keypoints spread.
        ///
        /// A homography's angular error becomes position error in proportion
        /// to this, which is why the 是非題 column slides off the page while
        /// the 選擇題 column beside it holds still: measured on 社會1-1 the
        /// two sit 0.454 and 0.023 from the keypoint centroid. Shown, not yet
        /// acted on — the number it would be turned into a weight by has no
        /// measurement behind it, and inventing one would hide the effect
        /// under a guess.
        let leverage: Double
    }

    /// One side of the paper, as the scanner chrome needs it.
    struct PageState: Identifiable {
        let id: Int               // page index
        let label: String         // 正面/背面, or a page number
        let graded: Int
        let total: Int

        var isComplete: Bool { total > 0 && graded == total }
        var isUntouched: Bool { graded == 0 }
    }

    struct Update {
        let boxes: [Box]
        let aligned: Bool         // last processed frame aligned OK
        /// Graded/total for the WHOLE paper, every page counted. The finish
        /// button reports the paper, not the side you happen to be looking at.
        let gradedCount: Int
        let totalCount: Int
        let pages: [PageState]
        let currentPage: Int
        let frameSize: CGSize     // upright frame dimensions, for overlay mapping
        let isReady: Bool         // template features loaded
        let alignMillis: Double   // last alignment wall time (0 until first result)
        let inlierCount: Int      // last alignment inliers (0 when missed)
        /// Share of matched keypoints the last homography kept. A fit built
        /// from sixteen inliers at 0.3 and one built from two hundred at 0.8
        /// are treated identically today; this is the number that says which
        /// one you are looking at.
        let inlierRatio: Double
        /// Median leverage over the cells on this page — how far they sit from
        /// the evidence, in spreads. See `Box.leverage`.
        let medianLeverage: Double
        let frameTimestamp: TimeInterval      // capture time of the anchor frame (0 = none)
        let intrinsics: simd_double3x3?       // upright-normalized K of the anchor frame
        // The whole master sheet projected through the anchor homography.
        // Alignment error is a rigid error of THIS quad — every box inherits
        // it coherently — so the overlay smooths this and re-derives the
        // boxes from it, rather than smoothing eight boxes independently.
        let sheetQuad: [CGPoint]?
        /// Long side in pixels of the last cell recognition actually saw.
        /// 0 before anything has been read.
        let cellPixels: Int
        /// Long side of the capture buffer those cells were cropped from.
        /// Around 1080 means the device fell back from 4K, which caps every
        /// cell on it regardless of how the paper is framed.
        let framePixels: Int

        /// Typical cell width, in camera pixels, across the cells read so far.
        /// 0 before anything has been read. Steadier than `cellPixels`, which
        /// is whichever cell the last frame happened to measure.
        let typicalCellPixels: Int
        /// Cells looked at repeatedly without reaching an answer. Something is
        /// stopping them, and it is usually not the model.
        let stuckCells: Int

        /// The camera's rotation rate on the last aligned frame, rad/s.
        let angularSpeed: Double?
        /// The lens was refocusing on the last aligned frame.
        let isFocusing: Bool
        /// The last aligned frame was still enough to read from.
        let isSteady: Bool
        /// Cells are waiting to be read and the camera has not held still for
        /// long enough to read any of them.
        let waitingForSteady: Bool
        /// On the last aligned frame: cells whose print was found and agreed
        /// with, out of those looked for.
        let registered: Int
        let registrationAttempts: Int

        /// What, if anything, is worth telling the teacher about the framing.
        ///
        /// Cell size and blur are different problems with different fixes, and
        /// a hint that names the wrong one is worse than none — someone who
        /// moves closer because they were told to, and sees no improvement,
        /// stops believing the next hint too.
        enum Framing { case fine, tooFar, tooShaky }

        var framing: Framing {
            // First, because until the camera holds still nothing is read at
            // all, and the cell-size figures below are taken from reads.
            if aligned && waitingForSteady { return .tooShaky }
            guard aligned, typicalCellPixels > 0 else { return .fine }
            if typicalCellPixels < Sampling.minUsefulCellPixels { return .tooFar }
            // Cells big enough to read, still not being read.
            return stuckCells > 0 ? .tooShaky : .fine
        }
    }

    var onUpdate: ((Update) -> Void)?

    /// Whether a finished page turns itself.
    ///
    /// Read at the moment the turn would happen rather than captured when the
    /// session starts, so flipping it in Settings takes effect on the next
    /// page instead of the next scan.
    ///
    /// Note what this cannot change: a verdict locks in and is never revisited,
    /// and the page only turns once every cell on it has one. Staying longer
    /// cannot improve a reading. What the switch decides is whether the
    /// teacher gets to see the page settle before the view moves on.
    static let autoAdvanceKey = "scan.autoAdvancePage"

    private static var autoAdvanceEnabled: Bool {
        UserDefaults.standard.object(forKey: autoAdvanceKey) as? Bool ?? true
    }

    private let template: ResolvedTemplate
    private let boxes: [CGRect]
    /// The same cells, widened — for reading only, never for drawing.
    ///
    /// `boxes` says where the answer is *printed*: it is what gets drawn over
    /// the paper, and what the results page matches a stored answer against.
    /// But children do not write inside the lines. Measured over 65 real
    /// answers lifted off a flatbed scan, sampling the box itself clipped 43
    /// of them, and cut away a sixth of the ink in the median case.
    ///
    /// A clipped mark is not a smaller mark, it is a different shape. A closed
    /// ○ with its top cut off is an arc, and the enclosure test that would
    /// have settled it finds nothing; a ✕ missing two of its four endpoints
    /// reads as two strokes meeting rather than four. Nine of the ten cells
    /// the recogniser got confidently wrong on that scan were circles with
    /// their tops outside the box.
    private let readBoxes: [CGRect]
    private let expected: [String]
    /// What the template says each cell is, parallel to `expected`.
    private let answerTypes: [String]
    /// Each multiple-choice cell's options — its alphabet, not its answer —
    /// parallel to `expected`; nil for every other kind of cell.
    private let choiceOptions: [[String]?]

    /// Which page each flat question slot belongs to, and the reverse lookup.
    /// The flat slot stays the index space the whole session works in — every
    /// verdict, accumulator and cell crop is keyed by it — so adding pages
    /// costs a filter, not a rewrite.
    private let pageOf: [Int]
    private let slotsByPage: [[Int]]

    /// One matcher per page, built on demand. Building one runs XFeat over
    /// three windows of that page's master, so building six up front would
    /// stall the camera for seconds before the first frame could be graded.
    private var matchers: [Int: XFeatTemplateMatcher] = [:]
    private var currentPage = 0

    /// Bumped on every page change.
    ///
    /// Alignment runs off the main thread and takes long enough for the
    /// teacher to turn the page while a frame is still in flight. That result
    /// was computed against the OLD side's master, so integrating it would
    /// project the new side's boxes through the wrong homography — scattering
    /// them across the paper and feeding one frame of garbage crops into the
    /// accumulators. The generation is what lets a stale result be dropped.
    private var pageGeneration = 0
    private var busy = false
    private var missStreak = 0
    private var verdicts: [Int: Verdict] = [:]   // question -> outcome, locked in
    private var seenStreak: [Int: Int] = [:]     // consecutive aligned sightings
    private var visibleQuads: [Int: [CGPoint]] = [:]
    private var visibleRects: [Int: CGRect] = [:]
    private var trackingHint: (windowIndex: Int, matrix: simd_double3x3)?
    private var supportHistory: [CGRect] = []    // recent inlier bounds (template space)
    private var grace: [Int: Int] = [:]          // per-box frames of display grace left
    private var lastFrame: UIImage?
    private var lastFrameSize = CGSize(width: 3, height: 4)
    /// Set when the teacher arrives on a page that is already finished — they
    /// came back to look at it. Auto-advance sits out that visit, otherwise
    /// checking page 2 bounces straight off it again.
    private var arrivedOnCompletePage = false
    private var advanceTask: Task<Void, Never>?
    private var lastAlignMillis: Double = 0
    private var lastInlierCount = 0
    private var lastInlierRatio = 0.0
    private var anchorTimestamp: TimeInterval = 0
    private var anchorIntrinsics: simd_double3x3?
    private var anchorSheetQuad: [CGPoint]?

    /// The best full-page look the camera got during this session.
    ///
    /// `finish()` used to hand back `lastFrame` — whatever happened to be in
    /// view when the teacher pressed 完成, which is a close-up of wherever
    /// they stopped. Questions outside it had no rect at all and drew no box,
    /// so the result page showed a partial paper with most of the grading
    /// missing. Keeping the best whole-sheet frame costs nothing: the guide
    /// frame already asks for the full page, so one goes by before anyone
    /// moves in to read the answers.
    ///
    /// Kept per page, because each side gets photographed separately and the
    /// best look at the front says nothing about where the back's cells are.
    private var pageKeyframes: [Int: PageKeyframe] = [:]

    private struct PageKeyframe {
        let image: UIImage
        let homography: XFeatMatcher.Homography
        let score: Double
    }

    // On-device recognition. A cell is seen dozens of times while the camera
    // pans and roughly one frame in five carries enough alignment drift to
    // misread it, so readings are accumulated and voted on rather than acted
    // on individually — see AnswerAccumulator.
    private let recognizer = AnswerRecognizer()
    private var accumulators: [Int: AnswerAccumulator] = [:]
    private var recognizedText: [Int: String] = [:]
    /// The most ink groups any frame dropped for a cell. See `Box.discarded`.
    private var discardedGroups: [Int: Int] = [:]
    /// Alignment leverage at each cell on the most recent aligned frame.
    private var cellLeverage: [Int: Double] = [:]
    private var blankStreak: [Int: Int] = [:]
    /// Consecutive aligned frames on which each cell was steady (see
    /// `Steadiness`), and where its centre was on the last one, in frame
    /// pixels.
    private var steadyStreak: [Int: Int] = [:]
    private var lastCellCentre: [Int: CGPoint] = [:]
    /// Aligned frames in a row on which no waiting cell was steady.
    private var unsteadyFrames = 0
    private var lastMotion: FrameMotion?
    private var lastFrameSteady = true

    // Registration (see CellRegistration). The master's print per page, built
    // with its matcher; per cell, what to search for and the window to read
    // through once found, built on first use.
    private var masterInk: [Int: MasterInk] = [:]
    private var cellTemplates: [Int: CellTemplate] = [:]
    private var cellWindows: [Int: ReadWindow] = [:]
    private var unregistrable: Set<Int> = []
    /// Steady looks in a row on which a cell's print could not be found.
    private var registrationMisses: [Int: Int] = [:]
    /// Each cell's read window, capped so it never reaches a neighbour.
    private let windowPads: [(left: Double, right: Double, top: Double, bottom: Double)]
    private var lastRegistered = 0
    private var lastRegistrationAttempts = 0

    /// The crop each question was last read from, kept so a teacher reviewing
    /// a verdict sees what the model saw. Only the most recent one per
    /// question is held — a cell is sampled dozens of times and keeping them
    /// all would be memory spent on frames nobody will ever look at.
    private var cellImages: [Int: UIImage] = [:]
    /// The best look held for each cell, and the best per reading — see
    /// `keepCrop`.
    private var heldCrops: [Int: CropCandidate] = [:]
    private var cropsByText: [Int: [String: CropCandidate]] = [:]
    /// Alignment leverage on the frame the held crop came from.
    ///
    /// Not the same as `cellLeverage`, which every aligned frame overwrites —
    /// that one ends up describing wherever the camera happened to stop. The
    /// crop a teacher is shown came from one specific frame, and the honest
    /// question about it is how far THAT frame's evidence was from this cell.
    ///
    /// It is what separates "the student left it blank" from "the box landed
    /// on blank paper", which a teacher looking at the crop cannot tell
    /// apart — the two look identical — and which the machine can.
    private var cellCropLeverage: [Int: Double] = [:]
    /// How wide each cell was, in camera pixels, on the frame its crop was
    /// kept from. The basis for the sampling-quality check at the end.
    private var cellSampledPixels: [Int: Int] = [:]
    /// One entry per page — a booklet's sides need not share a shape.
    private let masterAspect: [CGFloat]
    /// Long side, in pixels, of the last cell handed to recognition. Surfaced
    /// on screen because it is the number that decides whether an answer is
    /// readable at all — measured on real handwriting, 128px scores 6/6 and
    /// 64px scores 3/6 — and because framing is the only lever the person
    /// holding the camera has over it.
    private var lastCellPixels = 0
    private var lastFramePixels = 0

    /// Cap on the crop rendered per cell. CellPatch samples to 128; rendering
    /// past double that is work the model cannot use, so moving closer to the
    /// paper stops costing anything here.
    private static let cellRenderSide = 256

    /// How far past its own edge a cell is read, as a fraction of its size.
    ///
    /// Swept over 65 hand-marked cells: sampling the bare box lost a sixth of
    /// the ink in the median case, 10% still lost 2.2%, and by 20% the median
    /// cell lost none. Past that the gain is only in the tail — 17 cells still
    /// lost something at 20%, 11 at 30% — while every extra pixel is another
    /// chance to pick up ink belonging to someone else, which nothing
    /// downstream can currently reject. 25% clears the median with a little
    /// room and stops short of the greedy end.
    private static let readPad: CGFloat = 0.25

    private let minInliers: Int
    private let minRatio: Double

    /// Takes a resolved template and asks no questions about where it came
    /// from. Reaching into DemoData here is what used to confine live grading
    /// to 示範模式: with the toggle off the engine refused to build, the
    /// scanner silently fell back to the one-shot server path, and a teacher
    /// using a real template saw a different product from the one in the demo.
    init(template: ResolvedTemplate) {
        self.template = template
        let questions = template.questions
        let rects = questions.map(\.box)
        let pages = questions.map(\.pageIndex)
        self.boxes = rects
        self.readBoxes = Self.widened(rects, pageOf: pages)
        self.windowPads = Self.pads(rects, pageOf: pages,
                                    padX: CGFloat(ReadWindow.Tuning.padX),
                                    padY: CGFloat(ReadWindow.Tuning.padY))
        self.expected = questions.map(\.answer)
        self.answerTypes = questions.map(\.answerType)
        self.choiceOptions = questions.map { Self.options(for: $0, in: template) }
        self.pageOf = pages

        var slots = Array(repeating: [Int](), count: template.pages.count)
        for (slot, question) in questions.enumerated() {
            let page = template.pages.firstIndex { $0.index == question.pageIndex } ?? 0
            slots[page].append(slot)
        }
        self.slotsByPage = slots

        self.masterAspect = template.pages.map {
            $0.master.size.height > 0 ? $0.master.size.width / $0.master.size.height : 1
        }

        var inliers = 16
        var ratio = 0.3
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        inliers = env["DEMO_GATE_INLIERS"].flatMap(Int.init) ?? inliers
        ratio = env["DEMO_GATE_RATIO"].flatMap(Double.init) ?? ratio
        #endif
        minInliers = inliers
        minRatio = ratio

        build(page: 0)
    }

    /// Builds one page's matcher off the main thread, then speculatively
    /// builds the one after it. Prebuilding the neighbour is what makes turning
    /// the paper over feel instant: by the time anyone has physically flipped
    /// it, the features for that side are already extracted.
    ///
    /// Exactly ONE page of lookahead, and only after the current page is done.
    /// Letting the prefetch chain itself onwards would quietly extract every
    /// page in the booklet — eighteen XFeat passes on a six-page paper —
    /// competing with live alignment for the whole session to prepare sides
    /// nobody may reach.
    private func build(page: Int, prefetchingNext: Bool = true) {
        guard template.pages.indices.contains(page), matchers[page] == nil else { return }
        let master = template.pages[page].master
        Task.detached(priority: .userInitiated) { [weak self] in
            let built = try? XFeatTemplateMatcher(template: master)
            // The page's print, for registering cells against. Built here, off
            // the main thread and before the first frame can align, so it is
            // always ready by the time a cell is read.
            let ink = MasterInk(master)
            // The inner closure captures `self` again rather than reaching
            // for the outer `weak var` — referencing that from concurrent
            // code is an error under Swift 6.
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A page that failed to build is simply left unbuilt: it has
                // no matcher, so `isReady` reports false for it and switching
                // to it tries again.
                if let built { self.matchers[page] = built }
                if let ink { self.masterInk[page] = ink }
                self.publish()
                if prefetchingNext, let next = self.pageAfter(page) {
                    self.build(page: next, prefetchingNext: false)
                }
            }
        }
    }

    private func pageAfter(_ page: Int) -> Int? {
        let next = page + 1
        return template.pages.indices.contains(next) ? next : nil
    }

    var isReady: Bool { matchers[currentPage] != nil }

    // Entry point for camera frames; drops the frame when a previous one is
    // still being aligned. Timestamp and intrinsics ride along so the overlay
    // can propagate this anchor with camera motion measured after it.
    func submit(frame: UIImage,
                timestamp: TimeInterval = CACurrentMediaTime(),
                intrinsics: simd_double3x3? = nil,
                pixels: CellPixelSource? = nil,
                motion: FrameMotion? = nil) {
        guard !busy, let matcher = matchers[currentPage] else { return }
        busy = true
        let hint = trackingHint
        let generation = pageGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = CACurrentMediaTime()
            let tracked = try? matcher.alignTracked(scan: frame, hint: hint)
            let millis = (CACurrentMediaTime() - started) * 1000
            // The inner closure captures `self` again rather than reaching
            // for the outer `weak var` — referencing that from concurrent
            // code is an error under Swift 6.
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Released first, so a frame dropped for being stale cannot
                // wedge the pipeline.
                self.busy = false
                guard self.pageGeneration == generation else { return }
                self.integrate(frame: frame, tracked: tracked ?? nil, millis: millis,
                               timestamp: timestamp, intrinsics: intrinsics, pixels: pixels,
                               motion: motion)
            }
        }
    }

    // Same as submit, but awaits the frame's integration — for headless tests.
    func process(frame: UIImage) async {
        guard let matcher = matchers[currentPage] else { return }
        busy = true
        let hint = trackingHint
        let generation = pageGeneration
        let started = CACurrentMediaTime()
        let tracked = try? await Task.detached(priority: .userInitiated) {
            try matcher.alignTracked(scan: frame, hint: hint)
        }.value
        busy = false
        guard pageGeneration == generation else { return }
        integrate(frame: frame, tracked: tracked ?? nil,
                  millis: (CACurrentMediaTime() - started) * 1000,
                  timestamp: CACurrentMediaTime(), intrinsics: nil)
    }

    func reset() {
        verdicts = [:]
        seenStreak = [:]
        accumulators = [:]
        recognizedText = [:]
        discardedGroups = [:]
        cellLeverage = [:]
        blankStreak = [:]
        cellImages = [:]
        heldCrops = [:]
        cropsByText = [:]
        registrationMisses = [:]
        cellCropLeverage = [:]
        cellSampledPixels = [:]
        steadyStreak = [:]
        lastCellCentre = [:]
        unsteadyFrames = 0
        lastCellPixels = 0
        lastFramePixels = 0
        pageKeyframes = [:]
        advanceTask?.cancel()
        advanceTask = nil
        arrivedOnCompletePage = false
        currentPage = 0
        pageGeneration += 1
        clearTracking()
        lastFrame = nil
        lastAlignMillis = 0
        publish()
    }

    /// Everything that describes *where the paper is*, as opposed to what has
    /// been graded on it. Turning the page invalidates all of it — the boxes
    /// on screen were projected through the old page's master and would be
    /// wrong the moment the next frame arrives.
    private func clearTracking() {
        visibleQuads = [:]
        visibleRects = [:]
        seenStreak = [:]
        grace = [:]
        supportHistory = []
        trackingHint = nil
        missStreak = 0
        lastInlierCount = 0
        lastInlierRatio = 0
        anchorTimestamp = 0
        anchorIntrinsics = nil
        anchorSheetQuad = nil
        steadyStreak = [:]
        lastCellCentre = [:]
        unsteadyFrames = 0
    }

    // MARK: - Pages

    /// Turn to another side. Verdicts, accumulators and cell crops all survive
    /// — they belong to the paper, not to the side being looked at — so coming
    /// back to check a page shows it exactly as it was left.
    func switchTo(page: Int) {
        guard template.pages.indices.contains(page), page != currentPage else { return }
        advanceTask?.cancel()
        advanceTask = nil
        currentPage = page
        pageGeneration += 1
        arrivedOnCompletePage = isComplete(page: page)
        clearTracking()
        // Usually already built by the prefetch; when it is not — the teacher
        // jumped several pages, or the prefetch failed — this is the retry.
        build(page: page)
        publish()
    }

    /// A page with no answer cells counts as done. It is not a distinction
    /// worth arguing about on screen, but auto-advance would otherwise treat
    /// an empty page as unfinished, turn to it, and have nothing there that
    /// could ever complete it — a page the loop could not leave.
    private func isComplete(page: Int) -> Bool {
        let slots = slotsByPage.indices.contains(page) ? slotsByPage[page] : []
        return slots.allSatisfy { verdicts[$0] != nil }
    }

    /// The next page still carrying ungraded cells, searched forward and
    /// wrapping. Strictly `+1` would land on a page that is already finished
    /// whenever someone grades out of order, and turning the paper to a side
    /// with nothing left to do is exactly the wasted motion this is for.
    private func nextUnfinishedPage() -> Int? {
        let count = template.pages.count
        guard count > 1 else { return nil }
        for step in 1..<count {
            let candidate = (currentPage + step) % count
            if !isComplete(page: candidate) { return candidate }
        }
        return nil
    }

    /// Turns the page once the current one is fully graded.
    ///
    /// The delay is not politeness: the last cell's verdict lands on the same
    /// frame that completes the page, and jumping instantly means nobody ever
    /// sees it resolve. Any manual tap during the wait cancels — the teacher
    /// overrides the automation, never the other way round.
    private func scheduleAdvanceIfPageDone() {
        guard Self.autoAdvanceEnabled, template.pages.count > 1, advanceTask == nil,
              !arrivedOnCompletePage, isComplete(page: currentPage),
              let next = nextUnfinishedPage() else { return }

        // Inherits this actor, so no hop and no detachment: the whole point is
        // to run back here, in order, after the pause.
        advanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.advanceTask = nil
            self.switchTo(page: next)
        }
    }

    /// What finishing now would leave ungraded on the sides NOT in view.
    ///
    /// Only the other pages, deliberately. A half-graded page in front of the
    /// camera is visible — the empty cells are right there on screen and
    /// stopping anyway is a choice. A page nobody has turned to is invisible,
    /// and forgetting to turn it over is the whole failure this catches.
    struct LeftBehind {
        let pages: [(index: Int, label: String)]
        let remaining: Int

        var isEmpty: Bool { pages.isEmpty }
    }

    /// When a frame is still enough to read from.
    ///
    /// Reading used to start on the second frame that saw a cell, whatever
    /// the camera was doing. On the sixteen real scans that meant cells were
    /// read while the phone was still being brought into position — the
    /// teacher's own description of the 111s and the crops that slid off the
    /// answer. Waiting is cheap when it is measured: a fixed delay costs time
    /// on a phone already held still and is not long enough on one that is
    /// not, so the wait here lasts exactly until the camera stops moving.
    enum Steadiness {
        /// Above this rotation rate the frame is smeared. At 4K a cell is
        /// some 300px wide on a sensor with a ~2800px focal length, so 0.15
        /// rad/s moves the image about 14px over a 1/30s exposure — around
        /// a stroke's width once the cell is sampled down to recognition's
        /// 128px. Hands held still turn at a few hundredths.
        static let maxAngularSpeed = 0.15
        /// How far a cell may have moved since the previous aligned frame, in
        /// cell widths. Catches what the gyro cannot see — the phone sliding
        /// without turning — and alignment that jitters between frames, which
        /// is not a fit to read through either.
        static let maxCellShift = 0.15
        /// Steady looks in a row before a cell is first read: about a quarter
        /// of a second at tracking cadence.
        static let looksBeforeReading = 2
        /// Aligned frames in a row with nothing steady enough to read before
        /// the scanner says 拿穩一點 — about a second.
        static let shakyFramesBeforeHint = 10
    }

    enum Registration {
        /// Steady looks at a cell whose print cannot be found before it is
        /// read the old way, where the homography says. A cell is never left
        /// stuck behind registration — but it waits most of a second first,
        /// because a print that cannot be found is usually a frame that is
        /// not on the cell.
        static let fallbackAfter = 6
        /// Cells placed in the same frame are compared once there are this
        /// many…
        static let minCellsToCompare = 3
        /// …and one whose correction is further than this, in cells, from the
        /// frame's median correction is not trusted. Across a frame the
        /// homography's error changes by a fraction of a cell; a placement a
        /// row away has found some other row's print.
        static let maxDisagreement = 0.35
        /// The neighbourhood is rendered this much finer than the canonical
        /// grid it is sampled onto, so the sampling does not alias.
        static let renderScale = 1.5
    }

    enum Sampling {
        /// Measured on real papers: at 64px across a cell the recogniser got
        /// 3 of 6, at 96px it got 6 of 6. The fall-off is steep and it is not
        /// the model — below about this width the printed-rule filter cannot
        /// tell a box border from ink, because the border is one or two pixels
        /// wide. Warning below 80 puts the line inside the bad half.
        static let minUsefulCellPixels = 80
        /// Looks at a cell this many times without settling and something is
        /// stopping it — motion, focus, glare. `givesUpAfter` is 8, so this
        /// fires while there is still time to act rather than after the cell
        /// has already been written off.
        static let stuckSamples = 5
        /// Consecutive clear looks that yielded nothing before a cell is
        /// written off as holding no answer.
        ///
        /// Was two. Two is what a cell entering or leaving frame during a pan
        /// produces on its own, so a box the camera merely swept past was
        /// retired on the strength of never having been looked at properly —
        /// and retired permanently, because a verdict is what stops the cell
        /// being read again. The teacher's experience of that is an app which
        /// glanced twice, gave up, and then ignored the cell no matter how
        /// steadily they held the camera on it.
        ///
        /// Six is the same order as `givesUpAfter`'s eight, and for the same
        /// reason: at tracking cadence it is a fraction of a second, which is
        /// long enough to outlast a pan and short enough that a genuinely
        /// empty cell still settles while the page is on screen.
        static let blankLooks = 6
    }

    var pagesLeftBehind: LeftBehind {
        var pages: [(index: Int, label: String)] = []
        var remaining = 0
        for page in template.pages.indices where page != currentPage {
            let ungraded = slotsByPage[page].filter { verdicts[$0] == nil }
            guard !ungraded.isEmpty else { continue }
            pages.append((page, template.pageLabel(page)))
            remaining += ungraded.count
        }
        return LeftBehind(pages: pages, remaining: remaining)
    }

    // Freeze the session into a GradingResult: every question graded so far,
    // across every page, with rects placed on whichever page's keyframe saw
    // them.
    func finish() -> GradingResult? {
        guard !verdicts.isEmpty else { return nil }

        // The backdrop is only a representative frame — the results page draws
        // on the cached masters, one per page, so it needs no photograph at
        // all. Prefer a whole-sheet keyframe anyway, lowest page first, so
        // what does get carried is a full page rather than a close-up.
        let backdrop = template.pages.indices
            .compactMap { pageKeyframes[$0]?.image }
            .first ?? lastFrame
        guard let backdrop else { return nil }

        let answers = verdicts.keys.sorted().map { i -> GradedAnswer in
            let exp = i < expected.count ? expected[i] : ""
            let recognized = recognizedText[i] ?? scriptedAnswer(i) ?? ""
            // `id` carries the template's own question number, not this
            // array's index, so a paper whose questions are not numbered 1..n
            // still reports the number the teacher sees on the page.
            let number = i < template.questions.count ? template.questions[i].number : i + 1
            let serverPage = i < pageOf.count ? pageOf[i] : 0
            let slot = template.pages.firstIndex { $0.index == serverPage } ?? 0
            let rect = pageKeyframes[slot].map { $0.homography.project(boxes[i]) }
                ?? visibleRects[i]
            let question = i < template.questions.count ? template.questions[i] : nil
            return GradedAnswer(id: number - 1, expected: exp, recognized: recognized,
                                verdict: verdicts[i] ?? .unsure,
                                rect: rect,
                                templateRect: i < boxes.count ? boxes[i] : nil,
                                pageIndex: slot,
                                answerType: question?.answerType,
                                options: question.map { Self.options(for: $0, in: template) } ?? nil,
                                alignmentLeverage: cellCropLeverage[i])
        }
        // Every page had to be framed whole for the result to claim it shows
        // whole pages.
        let full = template.pages.indices.allSatisfy { pageKeyframes[$0] != nil }
        return GradingResult(image: backdrop, answers: answers,
                             templateTitle: template.title, date: Date(),
                             isFullPage: full)
    }

    /// The crops recognition read, keyed by question number (not array index),
    /// to be filed alongside the verdicts.
    func capturedCells() -> [Int: UIImage] {
        var result: [Int: UIImage] = [:]
        for (index, image) in cellImages {
            let number = index < template.questions.count
                ? template.questions[index].number : index + 1
            result[number] = image
        }
        return result
    }

    /// Everything the session knows, in the form the store keeps it.
    var templateIdentifier: Int { template.id }

    /// Every option this question offers, or nil when it does not offer a set.
    ///
    /// Only multiple choice has one. The set is the distinct answers the
    /// template's own choice cells hold, sorted — so a paper labelled 1–4
    /// yields 1–4 and one labelled A–D yields A–D, without anyone having to
    /// declare which convention this school uses.
    ///
    /// Reading the answer key to learn the ALPHABET is not reading it to
    /// learn the answer: which four options exist is a fact about the
    /// question, and the correction screen needs it to ask anything at all.
    static func options(for question: ResolvedTemplate.Question,
                        in template: ResolvedTemplate) -> [String]? {
        guard question.answerType == "choice" else { return nil }
        let set = Set(template.questions
            .filter { $0.answerType == "choice" }
            .map { AnswerKind.canonical($0.answer) }
            .filter { !$0.isEmpty })
        // Two is not a set of options, it is a paper where everyone happened
        // to be right twice. Below three, offering "the options" would be
        // offering a guess.
        guard set.count >= 3 else { return nil }
        return set.sorted()
    }

    /// The paper's sides, for the record to keep. Labels are resolved here
    /// rather than at display time because the template's page count is known
    /// now and may not be later.
    var storedPages: [StoredPage] {
        template.pages.indices.map { slot in
            StoredPage(index: slot,
                       imageID: template.pages[slot].imageID,
                       label: template.pageLabel(slot))
        }
    }

    // MARK: - Frame integration

    private func integrate(frame: UIImage,
                           tracked: XFeatTemplateMatcher.TrackedAlignment?,
                           millis: Double,
                           timestamp: TimeInterval,
                           intrinsics: simd_double3x3?,
                           pixels: CellPixelSource? = nil,
                           motion: FrameMotion? = nil) {
        lastAlignMillis = millis
        guard let tracked else { return miss() }
        let h = tracked.homography
        guard h.inlierCount >= minInliers, h.inlierRatio >= minRatio else { return miss() }
        missStreak = 0
        trackingHint = (tracked.windowIndex, h.matrix)
        lastInlierCount = h.inlierCount
        lastInlierRatio = h.inlierRatio
        lastFrame = frame
        lastFrameSize = frame.size
        anchorTimestamp = timestamp
        anchorIntrinsics = intrinsics
        anchorSheetQuad = h.projectedCorners(of: CGRect(x: 0, y: 0, width: 1, height: 1))
        considerKeyframe(frame: frame, homography: h)

        // Support = where the paper was actually observed. The per-frame
        // inlier bounds are noisy at tracking cadence (subsets of ~1024
        // keypoints), so gate against the union of the last few frames and
        // only require the box CENTER inside it — per-frame whole-rect
        // containment made boxes strobe in and out.
        supportHistory.append(h.sourceInlierBounds)
        if supportHistory.count > 4 {
            supportHistory.removeFirst(supportHistory.count - 4)
        }
        let support = supportHistory
            .reduce(supportHistory[0]) { $0.union($1) }
            .insetBy(dx: -0.05, dy: -0.05)

        var nowQuads: [Int: [CGPoint]] = [:]
        var nowRects: [Int: CGRect] = [:]
        var rawQuads: [Int: [CGPoint]] = [:]
        var readQuads: [Int: [CGPoint]] = [:]
        var confirmedNow = Set<Int>()
        // Only this page's cells. The homography maps THIS page's master onto
        // the frame, so projecting another side's boxes through it would scatter
        // them across the paper at plausible-looking coordinates.
        for i in currentSlots {
            let box = boxes[i]
            let corners = h.projectedCorners(of: box)
            // Recognition samples the UNsmoothed corners: smoothing exists to
            // stop the drawn overlay twitching, and applying it here would
            // feed the model a cell lagging behind where the paper actually is.
            rawQuads[i] = corners
            // Reading gets its own quad. The gate, the overlay and the
            // cell-size readout all stay on the printed box: widening is a
            // fact about how much paper the model needs to see, not about
            // where the answer is or how big it looks on screen.
            readQuads[i] = h.projectedCorners(of: readBoxes[i])
            cellLeverage[i] = h.leverage(of: CGPoint(x: box.midX, y: box.midY))
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!,
                              width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let inFrame = rect.minX >= -0.02 && rect.minY >= -0.02
                && rect.maxX <= 1.02 && rect.maxY <= 1.02
            let supported = support.contains(CGPoint(x: box.midX, y: box.midY))

            // Existence hysteresis: a box that just passed keeps a few frames
            // of display grace, so one noisy gate result can't blink it off.
            // Grace frames still project through the CURRENT homography —
            // the box stays glued, it just isn't treated as fresh evidence.
            if inFrame && supported {
                grace[i] = 6
                confirmedNow.insert(i)
            } else if inFrame, grace[i, default: 0] > 0 {
                grace[i] = grace[i, default: 0] - 1
            } else {
                grace[i] = 0
                continue
            }
            nowQuads[i] = smoothed(corners, previous: visibleQuads[i])
            let sxs = nowQuads[i]!.map(\.x), sys = nowQuads[i]!.map(\.y)
            nowRects[i] = CGRect(x: sxs.min()!, y: sys.min()!,
                                 width: sxs.max()! - sxs.min()!, height: sys.max()! - sys.min()!)
        }

        // Is this frame one to read from? The camera itself first — turning,
        // or refocusing — then, per cell, whether it is where it was on the
        // previous aligned frame. Frames without motion data (the headless
        // self-test, the simulator) are judged on the second test alone.
        let framePixels = pixels?.frameSize ?? lastFrameSize
        let frameSteady = !(motion?.isFocusing ?? false)
            && (motion?.angularSpeed ?? 0) <= Steadiness.maxAngularSpeed
        lastMotion = motion
        lastFrameSteady = frameSteady
        var waiting = false, waitingSteady = false
        for i in currentSlots {
            guard confirmedNow.contains(i), let quad = rawQuads[i], quad.count == 4 else {
                steadyStreak[i] = 0
                lastCellCentre[i] = nil
                continue
            }
            let centre = CGPoint(x: quad.map(\.x).reduce(0, +) / 4 * framePixels.width,
                                 y: quad.map(\.y).reduce(0, +) / 4 * framePixels.height)
            let cellWidth = hypot((quad[1].x - quad[0].x) * framePixels.width,
                                  (quad[1].y - quad[0].y) * framePixels.height)
            let shift = lastCellCentre[i].map {
                hypot(centre.x - $0.x, centre.y - $0.y) / max(cellWidth, 1)
            }
            lastCellCentre[i] = centre
            let steady = frameSteady && (shift.map { $0 <= Steadiness.maxCellShift } ?? false)
            steadyStreak[i] = steady ? steadyStreak[i, default: 0] + 1 : 0
            if verdicts[i] == nil {
                waiting = true
                if steady { waitingSteady = true }
            }
        }
        unsteadyFrames = waiting && !waitingSteady ? unsteadyFrames + 1 : 0

        // Recognition reads from the capture buffer at sensor resolution when
        // one came with the frame, and from the downscaled alignment image
        // otherwise. Building the fallback costs a full-frame grayscale pass,
        // so it is only built when a cell is actually waiting to be read.
        let pending = confirmedNow.contains { verdicts[$0] == nil && seenStreak[$0, default: 0] >= 1 }
        let source: CellPixelSource? = pending ? (pixels ?? ImageCellSource(frame)) : nil

        // Diagnostics update on every aligned frame, not only while a cell is
        // waiting to be read. Their whole job is to tell the person holding
        // the camera whether to move closer, and a figure frozen at whatever
        // the last recognised cell happened to measure is advice about a
        // moment that has already passed — it stops responding at exactly the
        // point someone starts adjusting their framing.
        //
        // Deriving the cell size geometrically rather than from a rendered
        // crop is what makes that affordable: it is arithmetic on a quad we
        // already projected, so it costs nothing on frames where no cell
        // needs reading.
        lastFramePixels = Int(max(framePixels.width, framePixels.height))
        if let firstVisible = confirmedNow.sorted().first, let quad = rawQuads[firstVisible] {
            lastCellPixels = Self.sampledSide(of: quad, in: framePixels)
        }

        // Which cells are read on this frame.
        var toRead: [Int] = []
        for i in currentSlots {
            guard confirmedNow.contains(i) else {
                seenStreak[i] = 0
                // A streak that was interrupted is not a streak. Without this
                // the count survives the cell leaving frame, so two separate
                // bad glimpses on two separate passes add up to a verdict —
                // which is how a box the camera only swept past got retired.
                blankStreak[i] = 0
                continue
            }
            seenStreak[i, default: 0] += 1
            guard seenStreak[i, default: 0] >= 2, verdicts[i] == nil else { continue }
            // Not until the camera has held still on this cell for a moment.
            // A frame skipped here is not a look: it neither votes nor counts
            // towards writing the cell off as blank.
            guard steadyStreak[i, default: 0] >= Steadiness.looksBeforeReading else { continue }
            let exp = i < expected.count ? expected[i] : ""
            guard !exp.isEmpty else { continue }
            toRead.append(i)
        }

        // Where each of them is actually printed in this frame — see
        // CellRegistration. Found first for all of them, because one cell's
        // placement is checked against the others' before any is trusted.
        var placed: [Int: (placement: CellRegistration.Placement, region: FrameRegion)] = [:]
        var attempted = 0
        if let source {
            for i in toRead {
                guard let prepared = registration(for: i) else { continue }
                attempted += 1
                let t = prepared.template
                let searchQuad = h.projectedCorners(of: t.searchRect)
                let side = Int(Double(max(t.fieldWidth, t.fieldHeight)) * Registration.renderScale)
                guard let region = source.region(covering: searchQuad, maxSide: side),
                      let field = CellPatch(bitmap: region.bitmap, quad: searchQuad.map(region.pixel),
                                            width: t.fieldWidth, height: t.fieldHeight),
                      let placement = CellRegistration.locate(t, in: field) else { continue }
                placed[i] = (placement, region)
            }
            // The homography's error varies smoothly across the page, so cells
            // read together need about the same correction. One that wants a
            // very different one has locked onto something else.
            if placed.count >= Registration.minCellsToCompare {
                var shifts: [Int: (x: Double, y: Double)] = [:]
                for (i, hit) in placed {
                    guard let t = cellTemplates[i] else { continue }
                    shifts[i] = (Double(hit.placement.dx) / Double(t.cellPixels.width),
                                 Double(hit.placement.dy) / Double(t.cellPixels.height))
                }
                let mx = Self.median(shifts.values.map(\.x))
                let my = Self.median(shifts.values.map(\.y))
                for i in Array(placed.keys) {
                    guard let shift = shifts[i] else { continue }
                    if hypot(shift.x - mx, shift.y - my) > Registration.maxDisagreement {
                        placed[i] = nil
                    }
                }
            }
        }
        lastRegistered = placed.count
        lastRegistrationAttempts = attempted

        for i in toRead {
            let exp = expected[i]
            let type = i < answerTypes.count ? answerTypes[i] : nil
            var reading: AnswerRecognizer.Reading?

            if let hit = placed[i], let t = cellTemplates[i], let window = cellWindows[i] {
                // Placed: read through the cell's own window, moved to where
                // its print was found, with that print erased.
                registrationMisses[i] = 0
                let corrected = boxes[i].offsetBy(dx: CGFloat(Double(hit.placement.dx) / t.scaleX),
                                                  dy: CGFloat(Double(hit.placement.dy) / t.scaleY))
                let quad = h.projectedCorners(of: window.rect(around: corrected)).map(hit.region.pixel)
                guard let patch = CellPatch(bitmap: hit.region.bitmap, quad: quad,
                                            width: window.width, height: window.height,
                                            printedBounds: window.printedBounds),
                      let cleaned = window.cleaned(patch) else { continue }
                reading = recognizer.read(cleaned.patch, expected: exp, declaredType: type,
                                          options: choiceOptions[i], furnitureCleared: true)
                keepCrop(i, bitmap: cleaned.evidence, quad: rawQuads[i] ?? quad,
                         framePixels: framePixels, readable: reading != nil,
                         registered: true, text: reading?.text)
            } else if registration(for: i) != nil,
                      registrationMisses[i, default: 0] < Registration.fallbackAfter {
                // Its print is on the master but could not be found here: this
                // frame is not on the cell, or not provably. Not a look.
                registrationMisses[i, default: 0] += 1
                continue
            } else if let source, let quad = readQuads[i],
                      let cut = source.cell(quad: quad, maxSide: Self.cellRenderSide) {
                // Nothing printed to register against, or registration has
                // kept failing on a steady camera: read where the homography
                // says, as before, rather than leave the cell stuck.
                //
                // The widened box, because that is the region being sampled —
                // passing the printed box's ratio here would squash the crop
                // by whatever the two differ, which is exactly the distortion
                // `aspect` exists to prevent.
                let box = readBoxes[i]
                let pageAspect = masterAspect.indices.contains(currentPage)
                    ? masterAspect[currentPage] : 1
                let aspect = box.height > 0 ? (box.width * pageAspect) / box.height : 1
                reading = recognizer.read(frame: cut.bitmap, quad: cut.quad,
                                          aspect: aspect, expected: exp,
                                          declaredType: type,
                                          printedBounds: Self.printedBounds(of: boxes[i], within: box),
                                          options: choiceOptions[i])
                // Measured on the printed box, not the widened one: that is
                // the number the 靠近一點 hint is about.
                keepCrop(i, bitmap: cut.bitmap, quad: rawQuads[i] ?? quad,
                         framePixels: framePixels, readable: reading != nil,
                         registered: false, text: reading?.text)
            } else {
                continue
            }

            if let reading {
                blankStreak[i] = 0
                if reading.discarded > 0 {
                    discardedGroups[i] = max(discardedGroups[i] ?? 0, reading.discarded)
                }
                var votes = accumulators[i] ?? AnswerAccumulator()
                votes.add(reading)
                accumulators[i] = votes
                if votes.isSettled, let best = votes.best {
                    lockIn(i, recognized: best.text, expected: exp)
                } else if votes.hasGivenUp {
                    // Plenty of clear looks, still no agreement. Saying so
                    // is better than picking the loudest guess and marking
                    // a student wrong on it.
                    recognizedText[i] = votes.best?.text
                    verdicts[i] = .unsure
                }
                continue
            }
            blankStreak[i, default: 0] += 1

            // Nothing legible after several consecutive clear looks at the
            // same cell. Consecutive is the point: the count resets the moment
            // the cell leaves frame, so this only fires on a cell the camera
            // actually held on to and still could not read.
            if blankStreak[i, default: 0] >= Sampling.blankLooks {
                if let scripted = scriptedAnswer(i) {
                    // Demo only: the bundled master is a blank answer sheet
                    // with no ink on it at all, so the script is the only
                    // reason the offline demo shows anything.
                    lockIn(i, recognized: scripted, expected: exp)
                } else {
                    // A real paper. Either the student left the cell empty or
                    // the scan never got a clean look at it, and nothing on
                    // this side of the camera can tell those apart — so it
                    // goes to the teacher rather than being marked wrong
                    // against the student.
                    verdicts[i] = .unsure
                }
            }
        }
        visibleQuads = nowQuads
        visibleRects = nowRects
        publish(aligned: true)
        scheduleAdvanceIfPageDone()
    }

    /// One look at a cell that could be kept as its evidence.
    private struct CropCandidate {
        let bitmap: GrayBitmap
        let sharpness: Double
        let registered: Bool
        let readable: Bool
        let leverage: Double?
        let sampledPixels: Int

        /// Three tiers, then sharpness. A crop whose print was found where it
        /// belongs is provably on the cell; one that produced a reading was
        /// probably on it; sharpness only ranks crops within a tier, because
        /// a crop that has slid onto the paper's shadow is the sharpest of
        /// all and contains none of the answer.
        func beats(_ other: CropCandidate?) -> Bool {
            guard let other else { return true }
            if registered != other.registered { return registered }
            if readable != other.readable { return readable }
            return sharpness > other.sharpness
        }
    }

    /// Records this frame's crop if it is the best look at the cell so far —
    /// overall, and among the looks that read `text`.
    ///
    /// The second is what the teacher is shown once the cell settles: the
    /// crop behind a verdict should be one that read that verdict, not the
    /// sharpest frame of the session, which may have read something else.
    private func keepCrop(_ i: Int, bitmap: GrayBitmap, quad: [CGPoint], framePixels: CGSize,
                          readable: Bool, registered: Bool, text: String?) {
        guard verdicts[i] == nil else { return }
        let candidate = CropCandidate(bitmap: bitmap, sharpness: bitmap.sharpness(),
                                      registered: registered, readable: readable,
                                      leverage: cellLeverage[i],
                                      sampledPixels: Self.sampledSide(of: quad, in: framePixels))
        if let text, candidate.beats(cropsByText[i]?[text]) {
            cropsByText[i, default: [:]][text] = candidate
        }
        if candidate.beats(heldCrops[i]) { hold(candidate, for: i) }
    }

    private func hold(_ candidate: CropCandidate, for i: Int) {
        heldCrops[i] = candidate
        cellImages[i] = candidate.bitmap.makeImage()
        cellCropLeverage[i] = candidate.leverage
        cellSampledPixels[i] = candidate.sampledPixels
    }

    /// What registration needs for one cell, built on first use and kept.
    /// nil when the master has nothing printed near the cell to register
    /// against, or when the page's ink is not ready yet.
    private func registration(for i: Int) -> (template: CellTemplate, window: ReadWindow)? {
        if let t = cellTemplates[i], let w = cellWindows[i] { return (t, w) }
        guard !unregistrable.contains(i), let ink = masterInk[currentPage],
              template.pages.indices.contains(currentPage) else { return nil }
        let t = CellTemplate(box: boxes[i], ink: ink, pageSize: template.pages[currentPage].master.size)
        guard t.isUsable else {
            unregistrable.insert(i)
            return nil
        }
        let w = ReadWindow(box: boxes[i], pads: windowPads[i], template: t, ink: ink)
        cellTemplates[i] = t
        cellWindows[i] = w
        return (t, w)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Median leverage across the cells currently on screen. Zero before the
    /// first aligned frame.
    private var medianLeverage: Double {
        let values = currentSlots.compactMap { cellLeverage[$0] }.sorted()
        return values.isEmpty ? 0 : values[values.count / 2]
    }

    /// Median width of the cells read so far, in camera pixels.
    private var typicalCellPixels: Int {
        let sizes = cellSampledPixels.values.sorted()
        return sizes.isEmpty ? 0 : sizes[sizes.count / 2]
    }

    /// Cells on this page seen enough times to have settled, that have not.
    private var stuckCells: Int {
        currentSlots.filter { i in
            verdicts[i] == nil && (accumulators[i]?.samples ?? 0) >= Sampling.stuckSamples
        }.count
    }

    /// Flat question slots printed on the page currently being scanned.
    private var currentSlots: [Int] {
        slotsByPage.indices.contains(currentPage) ? slotsByPage[currentPage] : []
    }

    /// Widens every cell for reading, but never past halfway to its nearest
    /// neighbour on that side.
    ///
    /// Halfway, so two adjacent cells meet along the midline between them and
    /// neither ever reaches into the other's box. Today's papers are nowhere
    /// near that limit — the 是非題 rows sit 48px apart with 48px boxes, so
    /// the cap costs nothing and every cell gets the full pad — but a 寫國字
    /// sheet is a grid of touching squares, and there a fixed pad would read
    /// the neighbour's character as part of this one. The cap is what lets the
    /// same number be safe on both, instead of being tuned per worksheet.
    ///
    /// Each of the four edges is capped on its own: a row that is tight above
    /// and open below should still grow downwards. Only cells on the same page
    /// are neighbours — the other side of a booklet is not adjacent to
    /// anything here, however close its coordinates look.
    ///
    /// Note this cannot stop ink that has *already* left the neighbour's box
    /// from drifting in; nothing decided from one cell's geometry can. That
    /// needs the page's ink assigning to cells as a whole, which is a larger
    /// change and is not what a dense sheet needs first.
    private static func widened(_ boxes: [CGRect], pageOf: [Int],
                                pad: CGFloat = readPad) -> [CGRect] {
        let page = CGRect(x: 0, y: 0, width: 1, height: 1)
        return boxes.indices.map { i in
            let box = boxes[i]
            var top = box.height * pad, bottom = box.height * pad
            var left = box.width * pad, right = box.width * pad

            for j in boxes.indices where j != i && pageOf[j] == pageOf[i] {
                let other = boxes[j]
                // A vertical neighbour is one sharing a column — overlapping
                // horizontally — and the horizontal case is the transpose.
                if other.maxX > box.minX, other.minX < box.maxX {
                    if other.maxY <= box.minY {
                        top = min(top, (box.minY - other.maxY) / 2)
                    } else if other.minY >= box.maxY {
                        bottom = min(bottom, (other.minY - box.maxY) / 2)
                    } else {
                        // The two boxes already overlap. Widening can only
                        // make that worse, so this cell reads its own bounds.
                        top = 0
                        bottom = 0
                    }
                }
                if other.maxY > box.minY, other.minY < box.maxY {
                    if other.maxX <= box.minX {
                        left = min(left, (box.minX - other.maxX) / 2)
                    } else if other.minX >= box.maxX {
                        right = min(right, (other.minX - box.maxX) / 2)
                    } else {
                        left = 0
                        right = 0
                    }
                }
            }

            let widened = CGRect(x: box.minX - left, y: box.minY - top,
                                 width: box.width + left + right,
                                 height: box.height + top + bottom)
            // Clamped to the sheet: sampling past the master's edge reads
            // paper that was never photographed.
            let clamped = widened.intersection(page)
            return clamped.isNull || clamped.isEmpty ? box : clamped
        }
    }

    /// The same caps as `widened`, with separate pads per axis, returned as
    /// distances in normalized page units: how far a registered cell's read
    /// window may reach past its box on each side.
    private static func pads(_ boxes: [CGRect], pageOf: [Int], padX: CGFloat,
                             padY: CGFloat) -> [(left: Double, right: Double, top: Double, bottom: Double)] {
        boxes.indices.map { i in
            let box = boxes[i]
            var top = box.height * padY, bottom = box.height * padY
            var left = box.width * padX, right = box.width * padX
            for j in boxes.indices where j != i && pageOf[j] == pageOf[i] {
                let other = boxes[j]
                if other.maxX > box.minX, other.minX < box.maxX {
                    if other.maxY <= box.minY {
                        top = min(top, (box.minY - other.maxY) / 2)
                    } else if other.minY >= box.maxY {
                        bottom = min(bottom, (other.minY - box.maxY) / 2)
                    } else {
                        top = 0
                        bottom = 0
                    }
                }
                if other.maxY > box.minY, other.minY < box.maxY {
                    if other.maxX <= box.minX {
                        left = min(left, (box.minX - other.maxX) / 2)
                    } else if other.minX >= box.maxX {
                        right = min(right, (other.minX - box.maxX) / 2)
                    } else {
                        left = 0
                        right = 0
                    }
                }
            }
            // Never past the sheet: that is paper nobody photographed.
            left = min(left, box.minX)
            right = min(right, 1 - box.maxX)
            top = min(top, box.minY)
            bottom = min(bottom, 1 - box.maxY)
            return (Double(max(0, left)), Double(max(0, right)),
                    Double(max(0, top)), Double(max(0, bottom)))
        }
    }

    /// Where the printed cell falls inside the widened one, in fractions of
    /// the widened one. What `CellPatch` needs in order to keep every "share
    /// of the cell" threshold meaning a share of the printed cell.
    private static func printedBounds(of printed: CGRect, within read: CGRect) -> CGRect {
        guard read.width > 0, read.height > 0 else { return CellPatch.wholePatch }
        return CGRect(x: (printed.minX - read.minX) / read.width,
                      y: (printed.minY - read.minY) / read.height,
                      width: printed.width / read.width,
                      height: printed.height / read.height)
    }

    /// What `CellPixelSource.cell` would hand back for this quad, without
    /// rendering it — same 8% margin, same cap. Mirrors the renderer so the
    /// number on screen is the number recognition would actually see.
    private static func sampledSide(of quad: [CGPoint], in frame: CGSize) -> Int {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max(),
              frame.width > 1, frame.height > 1 else { return 0 }

        let width = (maxX - minX) * frame.width
        let height = (maxY - minY) * frame.height
        guard width > 0, height > 0 else { return 0 }

        let pad = max(2, min(width, height) * 0.08)
        return Int(min(CGFloat(cellRenderSide), max(width, height) + 2 * pad))
    }

    /// The demo script for a cell, when this template carries one.
    private func scriptedAnswer(_ index: Int) -> String? {
        guard let scripted = template.scriptedAnswers, index < scripted.count else { return nil }
        return scripted[index]
    }

    /// Keeps the frame that shows the most of the sheet, most sharply.
    ///
    /// Score is the fraction of the frame the paper fills times the inlier
    /// count. Area favours getting close; inliers stand in for sharpness,
    /// since a motion-blurred frame matches far fewer features — which is
    /// cheaper than measuring blur directly and is already computed.
    private func considerKeyframe(frame: UIImage, homography h: XFeatMatcher.Homography) {
        guard let quad = anchorSheetQuad, quad.count == 4 else { return }
        let xs = quad.map(\.x), ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return }

        // The whole sheet has to be inside the frame with a margin. A page
        // running off the edge is exactly the picture this is trying to avoid.
        let margin: CGFloat = 0.01
        guard minX >= margin, minY >= margin,
              maxX <= 1 - margin, maxY <= 1 - margin else { return }

        let area = Double((maxX - minX) * (maxY - minY))
        let score = area * Double(h.inlierCount)
        guard score > (pageKeyframes[currentPage]?.score ?? 0) else { return }
        pageKeyframes[currentPage] = PageKeyframe(image: frame, homography: h, score: score)
    }

    private func lockIn(_ index: Int, recognized: String, expected: String) {
        // The evidence behind a verdict should be a look that read it.
        if let matching = cropsByText[index]?[recognized] { hold(matching, for: index) }
        recognizedText[index] = recognized
        verdicts[index] = AnswerKind.canonical(recognized) == AnswerKind.canonical(expected)
            ? .correct : .wrong
    }

    private func miss() {
        lastInlierCount = 0
        lastInlierRatio = 0
        missStreak += 1
        // At tracking cadence a brief motion-blur dropout burns through
        // misses in a fraction of a second; clearing too eagerly strobes the
        // whole overlay (and the guide frame back in). ~6 misses ≈ half a
        // second of sustained loss before wiping.
        if missStreak >= 6 {
            visibleQuads = [:]
            visibleRects = [:]
            seenStreak = [:]
            steadyStreak = [:]
            lastCellCentre = [:]
            grace = [:]
            supportHistory = []
            trackingHint = nil
        }
        publish(aligned: false)
    }

    // Adaptive low-pass on the projected corners: heavier smoothing when
    // nearly still (kills jitter), fading continuously to instant follow on
    // large motion. Continuous — a hard threshold made the overlay alternate
    // between snapping and smoothing frame to frame, which read as jitter.
    private func smoothed(_ corners: [CGPoint], previous: [CGPoint]?) -> [CGPoint] {
        guard let previous, previous.count == corners.count else { return corners }
        let cx = corners.map(\.x).reduce(0, +) / CGFloat(corners.count)
        let cy = corners.map(\.y).reduce(0, +) / CGFloat(corners.count)
        let px = previous.map(\.x).reduce(0, +) / CGFloat(previous.count)
        let py = previous.map(\.y).reduce(0, +) / CGFloat(previous.count)
        let displacement = hypot(cx - px, cy - py)
        let alpha = min(1, 0.35 + displacement / 0.02)
        return zip(previous, corners).map { p, c in
            CGPoint(x: p.x + (c.x - p.x) * alpha, y: p.y + (c.y - p.y) * alpha)
        }
    }

    private func publish(aligned: Bool = false) {
        let visible = visibleQuads.keys.sorted().map { i in
            Box(id: i, quad: visibleQuads[i]!, rect: visibleRects[i] ?? .zero,
                templateRect: boxes[i], verdict: verdicts[i],
                expectedText: i < expected.count ? expected[i] : "",
                readText: recognizedText[i],
                discarded: discardedGroups[i] ?? 0,
                leverage: cellLeverage[i] ?? 0)
        }
        let pages = template.pages.indices.map { page -> PageState in
            let slots = slotsByPage[page]
            return PageState(id: page,
                             label: template.pageLabel(page),
                             graded: slots.filter { verdicts[$0] != nil }.count,
                             total: slots.count)
        }
        onUpdate?(Update(boxes: visible,
                         aligned: aligned && !visible.isEmpty,
                         gradedCount: verdicts.count,
                         totalCount: boxes.count,
                         pages: pages,
                         currentPage: currentPage,
                         frameSize: lastFrameSize,
                         isReady: matchers[currentPage] != nil,
                         alignMillis: lastAlignMillis,
                         inlierCount: lastInlierCount,
                         inlierRatio: lastInlierRatio,
                         medianLeverage: medianLeverage,
                         frameTimestamp: anchorTimestamp,
                         intrinsics: anchorIntrinsics,
                         sheetQuad: anchorSheetQuad,
                         cellPixels: lastCellPixels,
                         framePixels: lastFramePixels,
                         typicalCellPixels: typicalCellPixels,
                         stuckCells: stuckCells,
                         angularSpeed: lastMotion?.angularSpeed,
                         isFocusing: lastMotion?.isFocusing ?? false,
                         isSteady: lastFrameSteady,
                         waitingForSteady: unsteadyFrames >= Steadiness.shakyFramesBeforeHint,
                         registered: lastRegistered,
                         registrationAttempts: lastRegistrationAttempts))
    }
}
