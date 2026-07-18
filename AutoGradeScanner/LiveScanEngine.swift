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

    struct Box: Identifiable {
        let id: Int               // question index
        let quad: [CGPoint]       // projected corners (tl,tr,br,bl), normalized in the upright frame
        let rect: CGRect          // axis-aligned bounds of quad
        let verdict: Bool?        // nil while pending (not yet locked in)
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
    }

    var onUpdate: ((Update) -> Void)?

    private let templateID: Int
    private let bundled: BundledDemoTemplate
    private let expected: [String]
    private let templateTitle: String

    private var matcher: XFeatTemplateMatcher?
    private var buildFailed = false
    private var busy = false
    private var missStreak = 0
    private var verdicts: [Int: Bool] = [:]      // question -> correct, locked in
    private var seenStreak: [Int: Int] = [:]     // consecutive aligned sightings
    private var visibleQuads: [Int: [CGPoint]] = [:]
    private var visibleRects: [Int: CGRect] = [:]
    private var trackingHint: (windowIndex: Int, matrix: simd_double3x3)?
    private var lastFrame: UIImage?
    private var lastFrameSize = CGSize(width: 3, height: 4)
    private var lastAlignMillis: Double = 0
    private var lastInlierCount = 0

    private let minInliers: Int
    private let minRatio: Double

    init?(templateID: Int, templateTitle: String) {
        guard DemoData.isEnabled,
              let bundled = DemoData.bundledTemplates[templateID],
              let master = UIImage(named: bundled.imageName) else { return nil }
        self.templateID = templateID
        self.templateTitle = templateTitle
        self.bundled = bundled
        self.expected = DemoData.shared.answers(for: templateID)

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
    // still being aligned.
    func submit(frame: UIImage) {
        guard !busy, let matcher else { return }
        busy = true
        let hint = trackingHint
        Task.detached(priority: .userInitiated) { [weak self] in
            let started = CACurrentMediaTime()
            let tracked = try? matcher.alignTracked(scan: frame, hint: hint)
            let millis = (CACurrentMediaTime() - started) * 1000
            await MainActor.run {
                self?.integrate(frame: frame, tracked: tracked ?? nil, millis: millis)
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
                  millis: (CACurrentMediaTime() - started) * 1000)
        busy = false
    }

    func reset() {
        verdicts = [:]
        seenStreak = [:]
        visibleQuads = [:]
        visibleRects = [:]
        trackingHint = nil
        missStreak = 0
        lastFrame = nil
        lastAlignMillis = 0
        lastInlierCount = 0
        publish()
    }

    // Freeze the session into a GradingResult: every question graded so far,
    // with rects for the ones visible in the last aligned frame.
    func finish() -> GradingResult? {
        guard let image = lastFrame, !verdicts.isEmpty else { return nil }
        let answers = verdicts.keys.sorted().map { i -> GradedAnswer in
            let exp = i < expected.count ? expected[i] : ""
            let recognized = i < bundled.written.count ? bundled.written[i] : exp
            return GradedAnswer(id: i, expected: exp, recognized: recognized,
                                isCorrect: verdicts[i] ?? false,
                                rect: visibleRects[i])
        }
        return GradingResult(image: image, answers: answers,
                             templateTitle: templateTitle, date: Date())
    }

    // MARK: - Frame integration

    private func integrate(frame: UIImage,
                           tracked: XFeatTemplateMatcher.TrackedAlignment?,
                           millis: Double) {
        lastAlignMillis = millis
        guard let tracked else { return miss() }
        let h = tracked.homography
        guard h.inlierCount >= minInliers, h.inlierRatio >= minRatio else { return miss() }
        missStreak = 0
        trackingHint = (tracked.windowIndex, h.matrix)
        lastInlierCount = h.inlierCount
        lastFrame = frame
        lastFrameSize = frame.size

        let support = h.sourceInlierBounds.insetBy(dx: -0.04, dy: -0.04)
        var nowQuads: [Int: [CGPoint]] = [:]
        var nowRects: [Int: CGRect] = [:]
        for (i, box) in bundled.boxes.enumerated() {
            let corners = h.projectedCorners(of: box)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let rect = CGRect(x: xs.min()!, y: ys.min()!,
                              width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard rect.minX >= -0.02, rect.minY >= -0.02,
                  rect.maxX <= 1.02, rect.maxY <= 1.02,
                  support.contains(box) else { continue }
            nowQuads[i] = smoothed(corners, previous: visibleQuads[i])
            let sxs = nowQuads[i]!.map(\.x), sys = nowQuads[i]!.map(\.y)
            nowRects[i] = CGRect(x: sxs.min()!, y: sys.min()!,
                                 width: sxs.max()! - sxs.min()!, height: sys.max()! - sys.min()!)
        }

        for i in 0..<bundled.boxes.count {
            if nowQuads[i] != nil {
                seenStreak[i, default: 0] += 1
                if seenStreak[i, default: 0] >= 2, verdicts[i] == nil {
                    let exp = i < expected.count ? expected[i] : ""
                    let recognized = i < bundled.written.count ? bundled.written[i] : exp
                    verdicts[i] = !exp.isEmpty && recognized == exp
                }
            } else {
                seenStreak[i] = 0
            }
        }
        visibleQuads = nowQuads
        visibleRects = nowRects
        publish(aligned: true)
    }

    private func miss() {
        lastInlierCount = 0
        missStreak += 1
        if missStreak >= 3 {
            visibleQuads = [:]
            visibleRects = [:]
            seenStreak = [:]
            trackingHint = nil
        }
        publish(aligned: false)
    }

    // Adaptive low-pass on the projected corners: follow immediately when the
    // box moved a lot (panning — smoothing there reads as lag), smooth when
    // nearly still (kills jitter without visible delay).
    private func smoothed(_ corners: [CGPoint], previous: [CGPoint]?) -> [CGPoint] {
        guard let previous, previous.count == corners.count else { return corners }
        let cx = corners.map(\.x).reduce(0, +) / CGFloat(corners.count)
        let cy = corners.map(\.y).reduce(0, +) / CGFloat(corners.count)
        let px = previous.map(\.x).reduce(0, +) / CGFloat(previous.count)
        let py = previous.map(\.y).reduce(0, +) / CGFloat(previous.count)
        let displacement = hypot(cx - px, cy - py)
        let alpha: CGFloat = displacement > 0.012 ? 1 : 0.45
        return zip(previous, corners).map { p, c in
            CGPoint(x: p.x + (c.x - p.x) * alpha, y: p.y + (c.y - p.y) * alpha)
        }
    }

    private func publish(aligned: Bool = false) {
        let boxes = visibleQuads.keys.sorted().map { i in
            Box(id: i, quad: visibleQuads[i]!, rect: visibleRects[i] ?? .zero,
                verdict: verdicts[i])
        }
        onUpdate?(Update(boxes: boxes,
                         aligned: aligned && !boxes.isEmpty,
                         gradedCount: verdicts.count,
                         totalCount: bundled.boxes.count,
                         frameSize: lastFrameSize,
                         isReady: matcher != nil,
                         alignMillis: lastAlignMillis,
                         inlierCount: lastInlierCount))
    }
}
