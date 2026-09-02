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

    private struct RealCells: Decodable {
        struct Cell: Decodable {
            let label: String
            let truth: String
            let width: Int
            let height: Int
            let intensity: [Double]
        }
        let cells: [Cell]
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

        // MARK: pixel sources

        // The camera path reads cells straight out of the capture buffer, where
        // CoreImage puts the origin bottom-left while every quad in this app is
        // top-left. Getting that flip wrong would silently sample the mirror
        // image of the answer, so the two sources are checked against each
        // other on the same synthetic frame: the image path is the one that has
        // always worked, and the buffer path has to agree with it.
        let probe = Shapes.markedFrame(at: CGRect(x: 0.60, y: 0.15, width: 0.10, height: 0.12))
        let quad = [CGPoint(x: 0.60, y: 0.15), CGPoint(x: 0.70, y: 0.15),
                    CGPoint(x: 0.70, y: 0.27), CGPoint(x: 0.60, y: 0.27)]

        func inkShare(_ source: CellPixelSource?) -> Double? {
            guard let cut = source?.cell(quad: quad, maxSide: 128),
                  let patch = CellPatch(bitmap: cut.bitmap, quad: cut.quad, aspect: 0.10 / 0.12)
            else { return nil }
            return patch.coverage
        }

        let viaImage = inkShare(ImageCellSource(probe))
        check("source.imagePathFindsMark", (viaImage ?? 0) > 0.5,
              String(format: "ink share %.2f (the whole cell is the mark)", viaImage ?? -1))

        if let buffer = Shapes.pixelBuffer(from: probe) {
            let viaBuffer = inkShare(PixelBufferCellSource(buffer: buffer,
                                                           orientation: .landscapeRight,
                                                           context: CIContext()))
            check("source.bufferPathAgrees",
                  (viaBuffer ?? 0) > 0.5 && abs((viaBuffer ?? 0) - (viaImage ?? 0)) < 0.25,
                  String(format: "image %.2f vs buffer %.2f", viaImage ?? -1, viaBuffer ?? -1))
        } else {
            check("source.bufferPathAgrees", false, "could not build a test pixel buffer")
        }

        // MARK: printed-mark removal

        // The regression that caught this: an empty answer box is a closed
        // rectangle, which is as wide as it is tall, so the elongation rule
        // that catches rules and parentheses never fired — and the live scan
        // read every blank cell on the demo sheet as a confident "7".
        check("cell.emptyBoxIsBlank",
              Shapes.framedBox(withDigit: false).withoutPrintedMarks().isBlank,
              "a printed box with nothing in it must read as blank")
        check("cell.boxedDigitSurvives",
              !Shapes.framedBox(withDigit: true).withoutPrintedMarks().isBlank,
              "erasing the border must not take the answer with it")
        check("cell.filledBubbleSurvives",
              !Shapes.filledBubble().withoutPrintedMarks().isBlank,
              "a filled bubble spans the cell and touches every edge, but is an answer")

        // MARK: real handwriting

        // The only real data in the suite: six answers cropped from an actual
        // student's paper. Everything else here is synthetic and proves the
        // code does what it was told; this proves the code reads real ink.
        // It is deliberately asserted at 5/6 rather than 6/6 — with a sample
        // this small, demanding perfection would turn any harmless tuning
        // change into a red build.
        let realPath = (referencePath as NSString).deletingLastPathComponent
            + "/real_cells.json"
        if let recognizer,
           let data = FileManager.default.contents(atPath: realPath),
           let real = try? JSONDecoder().decode(RealCells.self, from: data) {
            var rawHits = 0, cleanHits = 0
            var detail: [String] = []
            for cell in real.cells {
                let patch = CellPatch(width: cell.width, height: cell.height,
                                      intensity: cell.intensity)
                let raw = (try? recognizer.recognize(patch))?.text
                let clean = (try? recognizer.recognize(patch.withoutPrintedMarks()))?.text
                if raw == cell.truth { rawHits += 1 }
                if clean == cell.truth { cleanHits += 1 }
                detail.append("\(cell.label):\(cell.truth)→\(clean ?? "-")\(clean == cell.truth ? "" : "✗")")
            }
            print("RECOG INFO real.rawCell = \(rawHits)/\(real.cells.count) "
                  + "(printed marks left in — this is what a bare crop scores)")
            check("real.printedMarksRemoved", cleanHits >= 5,
                  "\(cleanHits)/\(real.cells.count)  " + detail.joined(separator: " "))
            check("real.filterHelps", cleanHits > rawHits,
                  "\(rawHits) → \(cleanHits) once the box border is erased")

            // Every one of these cells is a multiple-choice answer — 二 and 七
            // off the paper this was built from — so all six are exactly the
            // case `choice` exists for. Measured on the real ink rather than a
            // synthetic pair of blobs, because the claim being tested is that
            // dropping a stray group helps on cells that actually occur.
            var singleHits = 0, dropped = 0
            var singleDetail: [String] = []
            for cell in real.cells {
                let patch = CellPatch(width: cell.width, height: cell.height,
                                      intensity: cell.intensity).withoutPrintedMarks()
                let result = try? recognizer.recognize(patch, arity: .single)
                if result?.text == cell.truth { singleHits += 1 }
                dropped += result?.discarded ?? 0
                singleDetail.append("\(cell.label):\(cell.truth)→\(result?.text ?? "-")"
                                    + ((result?.discarded ?? 0) > 0 ? "+\(result!.discarded)" : "")
                                    + (result?.text == cell.truth ? "" : "✗"))
            }
            print("RECOG INFO real.singleArity dropped \(dropped) stray group(s)")
            // Never worse: the constraint may only remove readings that could
            // not have matched a one-character answer anyway.
            check("real.choiceNeverHurts", singleHits >= cleanHits,
                  "\(cleanHits) → \(singleHits)  " + singleDetail.joined(separator: " "))
        } else {
            check("real.printedMarksRemoved", false, "cannot read \(realPath)")
        }

        // Real ink, and the reason this file changed.
        //
        // Ten cells off a 康軒 社會4上 worksheet. Every ○ on it is an open
        // arc — the children draw a gap of a third to a half of the diameter —
        // which is the case the enclosure test could not see and scored 5/10
        // on, one of them confidently wrong. A confident wrong mark flips a
        // right answer to wrong on a child's paper, so that number is the one
        // this check exists to hold down.
        let marksPath = (referencePath as NSString).deletingLastPathComponent
            + "/real_marks.json"
        if let data = FileManager.default.contents(atPath: marksPath),
           let marks = try? JSONDecoder().decode(RealCells.self, from: data) {
            var hits = 0, confidentlyWrong = 0
            var detail: [String] = []
            for cell in marks.cells {
                let patch = CellPatch(width: cell.width, height: cell.height,
                                      intensity: cell.intensity)
                let read = MarkRecognizer.recognize(patch)
                let got = read?.mark.rawValue ?? "-"
                if got == cell.truth { hits += 1 }
                else if (read?.confidence ?? 0) >= 0.7 { confidentlyWrong += 1 }
                detail.append("\(cell.label):\(cell.truth)→\(got)"
                              + (got == cell.truth ? "" : "✗"))
            }
            check("mark.realInk", hits >= 9,
                  "\(hits)/\(marks.cells.count)  " + detail.joined(separator: " "))
            // The one that matters more than the score. Unsure is a fine
            // answer here; wrong-and-sure is not.
            check("mark.noConfidentMisread", confidentlyWrong == 0,
                  "\(confidentlyWrong) confident misreads")
        } else {
            check("mark.realInk", false, "cannot read \(marksPath)")
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

        // A ring open by 90° is still a ring, and the probe says so: nothing
        // runs through its middle however wide the gap.
        //
        // This assertion used to be the opposite — that such a ring came back
        // as LOW confidence — because under the enclosure test an unsealed
        // ring was indistinguishable from a cross, and admitting uncertainty
        // was the best it could do. That was a description of the method's
        // limit, not of the right answer, and the method it described is gone.
        if let wide = MarkRecognizer.recognize(Shapes.ring(gapDegrees: 90)) {
            check("mark.wideOpenRingIsStillACircle",
                  wide.mark == .circle && wide.confidence >= 0.5,
                  String(format: "%@ at %.2f, %d probe crossings",
                         wide.mark.rawValue, wide.confidence, wide.crossings))
        } else {
            check("mark.wideOpenRingIsStillACircle", false, "no reading at all")
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

        /// A pale frame with one dark rectangle at a known normalized position,
        /// deliberately off-centre and off-square so a flipped or transposed
        /// mapping cannot accidentally land on it.
        static func markedFrame(at rect: CGRect) -> UIImage {
            let size = CGSize(width: 400, height: 300)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor(white: 0.95, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                UIColor(white: 0.1, alpha: 1).setFill()
                ctx.fill(CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                width: rect.width * size.width, height: rect.height * size.height))
            }
        }

        /// A BGRA pixel buffer holding `image`, standing in for a capture frame.
        static func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
            guard let cgImage = image.cgImage else { return nil }
            let width = cgImage.width, height = cgImage.height
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                  let buffer else { return nil }

            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return buffer
        }

        /// An empty printed answer box, optionally with a digit inside it.
        static func framedBox(withDigit: Bool) -> CellPatch {
            var values = [Double](repeating: paper, count: size * size)
            let inset = 3, thickness = 2
            for y in inset..<(size - inset) {
                for x in inset..<(size - inset) {
                    let onEdge = y < inset + thickness || y >= size - inset - thickness
                        || x < inset + thickness || x >= size - inset - thickness
                    if onEdge { values[y * size + x] = ink }
                }
            }
            if withDigit {
                // A bar and a hook — enough ink to survive, nowhere near the border.
                for y in 20..<44 {
                    for x in 28..<34 { values[y * size + x] = ink }
                }
                for x in 22..<34 {
                    for y in 20..<24 { values[y * size + x] = ink }
                }
            }
            return CellPatch(width: size, height: size, intensity: values)
        }

        /// A solid mark filling the cell — spans every edge like a box border
        /// does, but is an answer, so it must survive.
        static func filledBubble() -> CellPatch {
            let centre = Double(size) / 2
            var values = [Double](repeating: paper, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                    if (dx * dx + dy * dy).squareRoot() <= Double(size) * 0.42 {
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
