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
    private let expected: [String]

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
    private var blankStreak: [Int: Int] = [:]

    /// The crop each question was last read from, kept so a teacher reviewing
    /// a verdict sees what the model saw. Only the most recent one per
    /// question is held — a cell is sampled dozens of times and keeping them
    /// all would be memory spent on frames nobody will ever look at.
    private var cellImages: [Int: UIImage] = [:]
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
        self.boxes = questions.map(\.box)
        self.expected = questions.map(\.answer)
        self.pageOf = questions.map(\.pageIndex)

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
            await MainActor.run {
                guard let self else { return }
                // A page that failed to build is simply left unbuilt: it has
                // no matcher, so `isReady` reports false for it and switching
                // to it tries again.
                if let built { self.matchers[page] = built }
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
                pixels: CellPixelSource? = nil) {
        guard !busy, let matcher = matchers[currentPage] else { return }
        busy = true
        let hint = trackingHint
        let generation = pageGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = CACurrentMediaTime()
            let tracked = try? matcher.alignTracked(scan: frame, hint: hint)
            let millis = (CACurrentMediaTime() - started) * 1000
            await MainActor.run {
                guard let self else { return }
                // Released first, so a frame dropped for being stale cannot
                // wedge the pipeline.
                self.busy = false
                guard self.pageGeneration == generation else { return }
                self.integrate(frame: frame, tracked: tracked ?? nil, millis: millis,
                               timestamp: timestamp, intrinsics: intrinsics, pixels: pixels)
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
        blankStreak = [:]
        cellImages = [:]
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
        anchorTimestamp = 0
        anchorIntrinsics = nil
        anchorSheetQuad = nil
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
            return GradedAnswer(id: number - 1, expected: exp, recognized: recognized,
                                verdict: verdicts[i] ?? .unsure,
                                rect: rect,
                                templateRect: i < boxes.count ? boxes[i] : nil,
                                pageIndex: slot)
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

    // MARK: - Frame integration

    private func integrate(frame: UIImage,
                           tracked: XFeatTemplateMatcher.TrackedAlignment?,
                           millis: Double,
                           timestamp: TimeInterval,
                           intrinsics: simd_double3x3?,
                           pixels: CellPixelSource? = nil) {
        lastAlignMillis = millis
        guard let tracked else { return miss() }
        let h = tracked.homography
        guard h.inlierCount >= minInliers, h.inlierRatio >= minRatio else { return miss() }
        missStreak = 0
        trackingHint = (tracked.windowIndex, h.matrix)
        lastInlierCount = h.inlierCount
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
        let framePixels = pixels?.frameSize ?? lastFrameSize
        lastFramePixels = Int(max(framePixels.width, framePixels.height))
        if let firstVisible = confirmedNow.sorted().first, let quad = rawQuads[firstVisible] {
            lastCellPixels = Self.sampledSide(of: quad, in: framePixels)
        }

        for i in currentSlots {
            guard confirmedNow.contains(i) else { seenStreak[i] = 0; continue }
            seenStreak[i, default: 0] += 1
            guard seenStreak[i, default: 0] >= 2, verdicts[i] == nil else { continue }

            let exp = i < expected.count ? expected[i] : ""
            guard !exp.isEmpty else { continue }

            if let source, let quad = rawQuads[i],
               let cut = source.cell(quad: quad, maxSide: Self.cellRenderSide) {
                if verdicts[i] == nil { cellImages[i] = cut.bitmap.makeImage() }
                let box = boxes[i]
                let pageAspect = masterAspect.indices.contains(currentPage)
                    ? masterAspect[currentPage] : 1
                let aspect = box.height > 0 ? (box.width * pageAspect) / box.height : 1
                if let reading = recognizer.read(frame: cut.bitmap, quad: cut.quad,
                                                 aspect: aspect, expected: exp) {
                    blankStreak[i] = 0
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
            }

            // Nothing legible after two clear looks. Two matches the "seen
            // twice, then decide" rule the rest of this loop already uses; a
            // longer streak would outlast a quick pan across the page.
            if blankStreak[i, default: 0] >= 2 {
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

    /// Flat question slots printed on the page currently being scanned.
    private var currentSlots: [Int] {
        slotsByPage.indices.contains(currentPage) ? slotsByPage[currentPage] : []
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
        recognizedText[index] = recognized
        verdicts[index] = AnswerKind.canonical(recognized) == AnswerKind.canonical(expected)
            ? .correct : .wrong
    }

    private func miss() {
        lastInlierCount = 0
        missStreak += 1
        // At tracking cadence a brief motion-blur dropout burns through
        // misses in a fraction of a second; clearing too eagerly strobes the
        // whole overlay (and the guide frame back in). ~6 misses ≈ half a
        // second of sustained loss before wiping.
        if missStreak >= 6 {
            visibleQuads = [:]
            visibleRects = [:]
            seenStreak = [:]
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
                readText: recognizedText[i])
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
                         frameTimestamp: anchorTimestamp,
                         intrinsics: anchorIntrinsics,
                         sheetQuad: anchorSheetQuad,
                         cellPixels: lastCellPixels,
                         framePixels: lastFramePixels))
    }
}
