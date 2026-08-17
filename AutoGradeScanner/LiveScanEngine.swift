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

    struct Update {
        let boxes: [Box]
        let aligned: Bool         // last processed frame aligned OK
        let gradedCount: Int
        let totalCount: Int
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

    private let template: ResolvedTemplate
    private let boxes: [CGRect]
    private let expected: [String]

    private var matcher: XFeatTemplateMatcher?
    private var buildFailed = false
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
    private var pageKeyframe: PageKeyframe?

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
    private let masterAspect: CGFloat
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
        self.boxes = template.boxes
        self.expected = template.expected
        let master = template.master
        self.masterAspect = master.size.height > 0 ? master.size.width / master.size.height : 1

        var inliers = 16
        var ratio = 0.3
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        inliers = env["DEMO_GATE_INLIERS"].flatMap(Int.init) ?? inliers
        ratio = env["DEMO_GATE_RATIO"].flatMap(Double.init) ?? ratio
        #endif
        minInliers = inliers
        minRatio = ratio

        Task.detached(priority: .userInitiated) { [weak self] in
            let built = try? XFeatTemplateMatcher(template: master)
            await MainActor.run {
                guard let self else { return }
                self.matcher = built
                self.buildFailed = built == nil
                self.publish()
            }
        }
    }

    var isReady: Bool { matcher != nil }

    // Entry point for camera frames; drops the frame when a previous one is
    // still being aligned. Timestamp and intrinsics ride along so the overlay
    // can propagate this anchor with camera motion measured after it.
    func submit(frame: UIImage,
                timestamp: TimeInterval = CACurrentMediaTime(),
                intrinsics: simd_double3x3? = nil,
                pixels: CellPixelSource? = nil) {
        guard !busy, let matcher else { return }
        busy = true
        let hint = trackingHint
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = CACurrentMediaTime()
            let tracked = try? matcher.alignTracked(scan: frame, hint: hint)
            let millis = (CACurrentMediaTime() - started) * 1000
            await MainActor.run {
                self?.integrate(frame: frame, tracked: tracked ?? nil, millis: millis,
                                timestamp: timestamp, intrinsics: intrinsics, pixels: pixels)
                self?.busy = false
            }
        }
    }

    // Same as submit, but awaits the frame's integration — for headless tests.
    func process(frame: UIImage) async {
        guard let matcher else { return }
        busy = true
        let hint = trackingHint
        let started = CACurrentMediaTime()
        let tracked = try? await Task.detached(priority: .userInitiated) {
            try matcher.alignTracked(scan: frame, hint: hint)
        }.value
        integrate(frame: frame, tracked: tracked ?? nil,
                  millis: (CACurrentMediaTime() - started) * 1000,
                  timestamp: CACurrentMediaTime(), intrinsics: nil)
        busy = false
    }

    func reset() {
        verdicts = [:]
        seenStreak = [:]
        accumulators = [:]
        recognizedText = [:]
        blankStreak = [:]
        lastCellPixels = 0
        lastFramePixels = 0
        visibleQuads = [:]
        visibleRects = [:]
        grace = [:]
        supportHistory = []
        trackingHint = nil
        missStreak = 0
        lastFrame = nil
        lastAlignMillis = 0
        lastInlierCount = 0
        anchorTimestamp = 0
        anchorIntrinsics = nil
        anchorSheetQuad = nil
        pageKeyframe = nil
        publish()
    }

    // Freeze the session into a GradingResult: every question graded so far,
    // with rects for the ones visible in the last aligned frame.
    func finish() -> GradingResult? {
        guard !verdicts.isEmpty else { return nil }

        // Prefer the full-page keyframe. Its homography places *every* box on
        // the sheet, not only the ones the camera happened to be looking at
        // when 完成 was pressed.
        let backdrop = pageKeyframe?.image ?? lastFrame
        guard let backdrop else { return nil }

        let answers = verdicts.keys.sorted().map { i -> GradedAnswer in
            let exp = i < expected.count ? expected[i] : ""
            let recognized = recognizedText[i] ?? scriptedAnswer(i) ?? ""
            // `id` carries the template's own question number, not this
            // array's index, so a paper whose questions are not numbered 1..n
            // still reports the number the teacher sees on the page.
            let number = i < template.questions.count ? template.questions[i].number : i + 1
            let rect = pageKeyframe.map { $0.homography.project(boxes[i]) } ?? visibleRects[i]
            return GradedAnswer(id: number - 1, expected: exp, recognized: recognized,
                                verdict: verdicts[i] ?? .unsure,
                                rect: rect)
        }
        return GradingResult(image: backdrop, answers: answers,
                             templateTitle: template.title, date: Date(),
                             isFullPage: pageKeyframe != nil)
    }

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
        for (i, box) in boxes.enumerated() {
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
        if let source {
            lastFramePixels = Int(max(source.frameSize.width, source.frameSize.height))
        }

        for i in 0..<boxes.count {
            guard confirmedNow.contains(i) else { seenStreak[i] = 0; continue }
            seenStreak[i, default: 0] += 1
            guard seenStreak[i, default: 0] >= 2, verdicts[i] == nil else { continue }

            let exp = i < expected.count ? expected[i] : ""
            guard !exp.isEmpty else { continue }

            if let source, let quad = rawQuads[i],
               let cut = source.cell(quad: quad, maxSide: Self.cellRenderSide) {
                lastCellPixels = Int(max(cut.bitmap.width, cut.bitmap.height))
                let box = boxes[i]
                let aspect = box.height > 0 ? (box.width * masterAspect) / box.height : 1
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
        guard score > (pageKeyframe?.score ?? 0) else { return }
        pageKeyframe = PageKeyframe(image: frame, homography: h, score: score)
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
        onUpdate?(Update(boxes: visible,
                         aligned: aligned && !visible.isEmpty,
                         gradedCount: verdicts.count,
                         totalCount: boxes.count,
                         frameSize: lastFrameSize,
                         isReady: matcher != nil,
                         alignMillis: lastAlignMillis,
                         inlierCount: lastInlierCount,
                         frameTimestamp: anchorTimestamp,
                         intrinsics: anchorIntrinsics,
                         sheetQuad: anchorSheetQuad,
                         cellPixels: lastCellPixels,
                         framePixels: lastFramePixels))
    }
}
