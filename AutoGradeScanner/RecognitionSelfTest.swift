import UIKit

// DEBUG-only headless check of the on-device recognition path. Launch with
//
//   SIMCTL_CHILD_RECOGNITION_SELFTEST=<digit_cnn_reference.json>  \
//   xcrun simctl launch --console-pty <udid> com.cramschool.autogradescanner
//
// Two things here can only be checked on an Apple platform. The Core ML model
// was converted on Linux, where coremltools cannot execute it, so the
// arithmetic is verified against a numpy re-implementation of the backend's
// SimpleDigitCNN — if those agree, the conversion preserved the weights and
// device grading will match server grading. The topology recogniser is pure
// Swift but its tuning (how wide a gap the closing can seal) is worth
// measuring rather than assuming.
enum RecognitionSelfTest {

    static func runIfRequested() {
        #if DEBUG
        if let reference = ProcessInfo.processInfo.environment["RECOGNITION_SELFTEST"] {
            Task { @MainActor in
                run(referencePath: reference)
                fflush(stdout)
                exit(0)
            }
        }
        #endif
    }

    #if DEBUG

    private struct Reference: Decodable {
        struct Case: Decodable {
            let input: [Double]
            let probabilities: [Double]
        }
        let cases: [Case]
    }

    @MainActor
    private static func run(referencePath: String) {
        var passed = 0, total = 0

        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            total += 1
            if condition { passed += 1 }
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            print("RECOG \(condition ? "PASS" : "FAIL") \(name)\(suffix)")
        }

        // MARK: model conversion

        let recognizer: DigitRecognizer?
        do {
            recognizer = try DigitRecognizer()
            check("model.load", true, "DigitCNN.mlmodelc bundled")
        } catch {
            recognizer = nil
            check("model.load", false, "\(error)")
        }

        if let recognizer {
            if let data = FileManager.default.contents(atPath: referencePath),
               let reference = try? JSONDecoder().decode(Reference.self, from: data) {
                var worst = 0.0
                var ran = 0
                for testCase in reference.cases {
                    guard let reading = try? recognizer.classify(testCase.input) else { continue }
                    ran += 1
                    for i in 0..<min(reading.probabilities.count, testCase.probabilities.count) {
                        worst = max(worst, abs(reading.probabilities[i] - testCase.probabilities[i]))
                    }
                }
                check("model.matchesReference",
                      ran == reference.cases.count && worst < 1e-3,
                      String(format: "%d/%d cases, max prob delta %.2e",
                             ran, reference.cases.count, worst))
            } else {
                check("model.matchesReference", false, "cannot read \(referencePath)")
            }
        }

        // MARK: topology

        check("mark.closedCircle",
              MarkRecognizer.recognize(Shapes.ring(gapDegrees: 0))?.mark == .circle)
        check("mark.cross",
              MarkRecognizer.recognize(Shapes.cross())?.mark == .cross)
        check("mark.blank",
              MarkRecognizer.recognize(Shapes.blank()) == nil,
              "blank cell yields no answer")

        // Students rarely close a circle. Sweep the gap to find where the
        // morphological closing gives up, and report it in pixels — that number
        // is the real tolerance of this approach.
        var widestSealed = -1.0
        for gap in stride(from: 0.0, through: 60.0, by: 2.5) {
            if MarkRecognizer.recognize(Shapes.ring(gapDegrees: gap))?.mark == .circle {
                widestSealed = gap
            } else {
                break
            }
        }
        let gapPixels = widestSealed < 0 ? 0 : Shapes.ringRadius * widestSealed * .pi / 180
        check("mark.openCircle",
              widestSealed >= 10,
              String(format: "seals gaps up to %.0f° (%.1f px of a %d px cell)",
                     widestSealed, gapPixels, Shapes.size))

        // The failure that must never be silent: a gap too wide to seal should
        // come back as low confidence, not as a confident cross.
        if let wide = MarkRecognizer.recognize(Shapes.ring(gapDegrees: 90)) {
            check("mark.tooOpenIsUnsure", wide.confidence <= 0.3,
                  String(format: "confidence %.2f", wide.confidence))
        } else {
            check("mark.tooOpenIsUnsure", false, "no reading at all")
        }

        // MARK: MNIST normalisation

        let corner = Shapes.corner()
        if let grid = DigitRecognizer.mnistGrid(corner, subset: corner.mask) {
            var mass = 0.0, mx = 0.0, my = 0.0
            for y in 0..<28 {
                for x in 0..<28 {
                    let v = grid[y * 28 + x]
                    mass += v
                    mx += v * (Double(x) + 0.5)
                    my += v * (Double(y) + 0.5)
                }
            }
            let cx = mass > 0 ? mx / mass : 0, cy = mass > 0 ? my / mass : 0
            check("digit.centresByMass",
                  abs(cx - 14) < 1.5 && abs(cy - 14) < 1.5,
                  String(format: "ink in the corner lands at (%.1f, %.1f)", cx, cy))
        } else {
            check("digit.centresByMass", false, "no grid produced")
        }

        // MARK: segmentation

        check("digit.splitsTwoDigits",
              DigitRecognizer.segment(Shapes.twoBlobs(separated: true)).count == 2,
              "side-by-side blobs")
        check("digit.keepsMultiStrokeDigit",
              DigitRecognizer.segment(Shapes.twoBlobs(separated: false)).count == 1,
              "stacked strokes stay one digit")

        print("RECOGNITION SELFTEST: \(passed)/\(total) passed")
    }

    // MARK: - Synthetic cells

    /// Shapes are drawn with camera-like grey levels rather than pure 0/1, so
    /// Otsu and the contrast stretch are exercised the way a real frame would.
    private enum Shapes {
        static let size = 64
        static let ringRadius = 20.0
        static let paper = 0.12
        static let ink = 0.88

        static func blank() -> CellPatch {
            CellPatch(width: size, height: size,
                      intensity: (0..<(size * size)).map { _ in paper })
        }

        static func ring(gapDegrees: Double) -> CellPatch {
            let centre = Double(size) / 2
            var values = [Double](repeating: paper, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                    let distance = (dx * dx + dy * dy).squareRoot()
                    guard abs(distance - ringRadius) <= 1.5 else { continue }
                    // Open the ring symmetrically about 90°: `delta` is the
                    // angular distance from the centre of the gap, so a pixel
                    // is skipped when it falls within half the gap of it.
                    let degrees = atan2(dy, dx) * 180 / .pi
                    let delta = abs(((degrees - 90).truncatingRemainder(dividingBy: 360) + 540)
                                        .truncatingRemainder(dividingBy: 360) - 180)
                    if gapDegrees > 0, delta <= gapDegrees / 2 { continue }
                    values[y * size + x] = ink
                }
            }
            return CellPatch(width: size, height: size, intensity: values)
        }

        static func cross() -> CellPatch {
            let centre = Double(size) / 2
            var values = [Double](repeating: paper, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                    guard max(abs(dx), abs(dy)) <= ringRadius else { continue }
                    if abs(dx - dy) <= 2 || abs(dx + dy) <= 2 {
                        values[y * size + x] = ink
                    }
                }
            }
            return CellPatch(width: size, height: size, intensity: values)
        }

        /// A blob jammed into the top-left corner — the centring test only
        /// means something if the ink starts badly off-centre.
        static func corner() -> CellPatch {
            var values = [Double](repeating: paper, count: size * size)
            for y in 4..<16 {
                for x in 4..<12 { values[y * size + x] = ink }
            }
            return CellPatch(width: size, height: size, intensity: values)
        }

        /// Two blobs, either side by side (two digits) or stacked at the same
        /// x (one digit written in two strokes, like a 4 or a 5).
        static func twoBlobs(separated: Bool) -> CellPatch {
            var values = [Double](repeating: paper, count: size * size)
            func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int) {
                for y in y0..<(y0 + h) {
                    for x in x0..<(x0 + w) { values[y * size + x] = ink }
                }
            }
            if separated {
                fill(8, 20, 12, 24)
                fill(40, 20, 12, 24)
            } else {
                fill(20, 12, 20, 8)
                fill(24, 28, 14, 20)
            }
            return CellPatch(width: size, height: size, intensity: values)
        }
    }

    #endif
}
