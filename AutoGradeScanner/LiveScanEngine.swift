import UIKit

// Live grading session for one bundled demo template: camera frames come in,
// XFeat aligns each against the cached template features, the template's
// answer boxes are projected onto the frame, and per-question verdicts
// accumulate across frames ("掃到哪改到哪"). Alignment runs off the main
// thread at whatever rate it can sustain; frames arriving while busy are
// dropped. Verdicts are canned (demo mode) and lock in once a question has
// been seen in two consecutive aligned frames, so panning across the paper
// fills in colors progressively without flicker.
@MainActor
final class LiveScanEngine {

    struct Box: Identifiable {
        let id: Int               // question index
        let rect: CGRect          // normalized in the upright frame
        let verdict: Bool?        // nil while pending (not yet locked in)
    }

    struct Update {
        let boxes: [Box]
        let aligned: Bool         // last processed frame aligned OK
        let gradedCount: Int
        let totalCount: Int
        let frameSize: CGSize     // upright frame dimensions, for overlay mapping
        let isReady: Bool         // template features loaded
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
    private var visibleRects: [Int: CGRect] = [:]
    private var lastFrame: UIImage?
    private var lastFrameSize = CGSize(width: 3, height: 4)

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
        Task.detached(priority: .userInitiated) { [weak self] in
            let homography = try? matcher.align(scan: frame)
            await MainActor.run {
                self?.integrate(frame: frame, homography: homography ?? nil)
                self?.busy = false
            }
        }
    }

    // Same as submit, but awaits the frame's integration — for headless tests.
    func process(frame: UIImage) async {
        guard let matcher else { return }
        busy = true
        let homography = try? await Task.detached(priority: .userInitiated) {
            try matcher.align(scan: frame)
        }.value
        integrate(frame: frame, homography: homography)
        busy = false
    }

    func reset() {
        verdicts = [:]
        seenStreak = [:]
        visibleRects = [:]
        missStreak = 0
        lastFrame = nil
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

    private func integrate(frame: UIImage, homography h: XFeatMatcher.Homography?) {
        guard let h, h.inlierCount >= minInliers, h.inlierRatio >= minRatio else {
            missStreak += 1
            if missStreak >= 3 {
                visibleRects = [:]
                seenStreak = [:]
            }
            publish(aligned: false)
            return
        }
        missStreak = 0
        lastFrame = frame
        lastFrameSize = frame.size

        let support = h.sourceInlierBounds.insetBy(dx: -0.04, dy: -0.04)
        var nowVisible: [Int: CGRect] = [:]
        for (i, box) in bundled.boxes.enumerated() {
            let rect = h.project(box)
            guard rect.minX >= -0.02, rect.minY >= -0.02,
                  rect.maxX <= 1.02, rect.maxY <= 1.02,
                  support.contains(box) else { continue }
            // Low-pass the rect so the overlay tracks without jitter.
            if let previous = visibleRects[i] {
                nowVisible[i] = CGRect(x: (previous.minX + rect.minX) / 2,
                                       y: (previous.minY + rect.minY) / 2,
                                       width: (previous.width + rect.width) / 2,
                                       height: (previous.height + rect.height) / 2)
            } else {
                nowVisible[i] = rect
            }
        }

        for i in 0..<bundled.boxes.count {
            if nowVisible[i] != nil {
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
        visibleRects = nowVisible
        publish(aligned: true)
    }

    private func publish(aligned: Bool = false) {
        let boxes = visibleRects.keys.sorted().map { i in
            Box(id: i, rect: visibleRects[i]!, verdict: verdicts[i])
        }
        onUpdate?(Update(boxes: boxes,
                         aligned: aligned && !boxes.isEmpty,
                         gradedCount: verdicts.count,
                         totalCount: bundled.boxes.count,
                         frameSize: lastFrameSize,
                         isReady: matcher != nil))
    }
}
