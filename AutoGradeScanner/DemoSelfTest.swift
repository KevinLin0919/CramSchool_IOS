import UIKit

// DEBUG-only headless check of the live grading pipeline, so the whole
// frames → XFeat alignment → projected boxes → recognition → verdicts path
// can be verified from the command line without driving the UI. Launch the
// simulator app with
//
//   SIMCTL_CHILD_DEMO_SELFTEST_LIVE=<scan png>,<scan png>,…  \
//   SIMCTL_CHILD_DEMO_SELFTEST_OUT=<annotated output png>  \
//   xcrun simctl launch --console-pty <udid> com.cramschool.autogradescanner
//
// (simctl strips the SIMCTL_CHILD_ prefix and forwards the variables to the
// app). It feeds the frames to demo template 9001 as if the camera had panned
// across the paper, prints one line per question and exits.
//
// There used to be a second, single-image mode here. It ran the one-shot
// grading path — which is gone — and it never exercised recognition at all:
// the verdicts came from the template's canned answers. Everything it checked,
// the live path checks for real.
enum DemoSelfTest {
    static func runIfRequested() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let livePaths = env["DEMO_SELFTEST_LIVE"] {
            Task { @MainActor in
                await runLive(paths: livePaths.split(separator: ",").map(String.init))
                fflush(stdout)
                exit(0)
            }
        }
        #endif
    }

    #if DEBUG
    // Live-session simulation: feed a sequence of frames (as if the camera
    // panned across the paper) into LiveScanEngine and report how verdicts
    // accumulate, then freeze and render the final result.
    @MainActor
    private static func runLive(paths: [String]) async {
        guard let resolved = DemoData.resolved(id: 9001) else {
            print("SELFTEST LIVE: bundled template 9001 unavailable")
            return
        }
        let engine = LiveScanEngine(template: resolved)
        var latest: LiveScanEngine.Update?
        engine.onUpdate = { latest = $0 }

        for _ in 0..<100 where !engine.isReady {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard engine.isReady else {
            print("SELFTEST LIVE: template features never became ready")
            return
        }

        for (index, path) in paths.enumerated() {
            guard let frame = UIImage(contentsOfFile: path) else {
                print("SELFTEST LIVE: cannot load \(path)")
                continue
            }
            await engine.process(frame: frame)
            let u = latest
            print("SELFTEST LIVE frame\(index) (\((path as NSString).lastPathComponent)): "
                  + "aligned=\(u?.aligned ?? false) visible=\(u?.boxes.count ?? 0) "
                  + "graded=\(u?.gradedCount ?? 0)/\(u?.totalCount ?? 0)")
        }

        guard let result = engine.finish() else {
            print("SELFTEST LIVE: nothing graded, no result")
            return
        }
        print("SELFTEST LIVE final: \(result.answers.count) graded")
        for a in result.answers {
            let rect = a.rect.map {
                String(format: "(%.3f, %.3f, %.3f, %.3f)", $0.minX, $0.minY, $0.width, $0.height)
            } ?? "nil"
            print("SELFTEST LIVE Q\(a.questionNumber) expected=\(a.expected) "
                  + "recognized=\(a.recognized) correct=\(a.isCorrect) rect=\(rect)")
        }
        if let outPath = ProcessInfo.processInfo.environment["DEMO_SELFTEST_OUT"] {
            let annotated = render(result)
            try? annotated.pngData()?.write(to: URL(fileURLWithPath: outPath))
            print("SELFTEST LIVE: wrote \(outPath)")
        }
    }

    // Scan photo with the verdict boxes burned in, for eyeballing.
    private static func render(_ result: GradingResult) -> UIImage {
        let size = result.image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            result.image.draw(in: CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.setLineWidth(max(size.width, size.height) / 300)
            for a in result.answers {
                guard let r = a.rect else { continue }
                cg.setStrokeColor((a.isCorrect ? UIColor.systemGreen : UIColor.systemRed).cgColor)
                cg.stroke(CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                 width: r.width * size.width, height: r.height * size.height))
            }
        }
    }
    #endif
}
