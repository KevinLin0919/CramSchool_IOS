import UIKit

// DEBUG-only headless check of the demo grading pipeline, so the whole
// photo → XFeat alignment → projected boxes → verdicts path can be verified
// from the command line without driving the UI. Launch the simulator app with
//
//   SIMCTL_CHILD_DEMO_SELFTEST_SCAN=<scan png>  \
//   SIMCTL_CHILD_DEMO_SELFTEST_OUT=<annotated output png>  \
//   xcrun simctl launch --console-pty <udid> com.cramschool.autogradescanner
//
// (simctl strips the SIMCTL_CHILD_ prefix and forwards the variables to the
// app). It grades the image against demo template 9001, prints one line per
// visible question and exits.
enum DemoSelfTest {
    static func runIfRequested() {
        #if DEBUG
        guard let scanPath = ProcessInfo.processInfo.environment["DEMO_SELFTEST_SCAN"] else { return }
        Task { @MainActor in
            await run(scanPath: scanPath)
            fflush(stdout)
            exit(0)
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func run(scanPath: String) async {
        guard let scan = UIImage(contentsOfFile: scanPath) else {
            print("SELFTEST: cannot load \(scanPath)")
            return
        }
        do {
            let result = try await GradingEngine.grade(image: scan,
                                                       templateID: 9001,
                                                       templateTitle: "自測")
            print("SELFTEST: \(result.answers.count) visible boxes")
            for a in result.answers {
                let rect = a.rect.map {
                    String(format: "(%.3f, %.3f, %.3f, %.3f)",
                           $0.minX, $0.minY, $0.width, $0.height)
                } ?? "nil"
                print("SELFTEST: Q\(a.questionNumber) expected=\(a.expected) "
                      + "recognized=\(a.recognized) correct=\(a.isCorrect) rect=\(rect)")
            }
            if let outPath = ProcessInfo.processInfo.environment["DEMO_SELFTEST_OUT"] {
                let annotated = render(result)
                try? annotated.pngData()?.write(to: URL(fileURLWithPath: outPath))
                print("SELFTEST: wrote \(outPath)")
            }
        } catch {
            print("SELFTEST: FAILED — \(error.localizedDescription)")
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
