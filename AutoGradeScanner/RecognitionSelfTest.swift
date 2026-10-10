import UIKit
import simd

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

    /// The circle-or-cross model's contract with the code that trained it.
    ///
    /// `maskBits` is the binarised cell, row-major, one bit per pixel, packed
    /// most-significant-bit first and base64'd — the same representation
    /// `numpy.packbits` produces, so the two sides are comparing the identical
    /// input rather than two renderings of it.
    private struct ForestFixture: Decodable {
        struct Cell: Decodable {
            let label: String
            let truth: String
            let width: Int
            let height: Int
            let maskBits: String
            let found: Bool
            let features: [Double]
            let probX: Double

            func unpackedMask() -> [Bool]? {
                guard let bytes = Data(base64Encoded: maskBits) else { return nil }
                let wanted = width * height
                guard bytes.count * 8 >= wanted else { return nil }
                var mask = [Bool](repeating: false, count: wanted)
                for index in 0..<wanted {
                    let byte = bytes[bytes.startIndex + index / 8]
                    mask[index] = (byte >> (7 - UInt8(index % 8))) & 1 == 1
                }
                return mask
            }
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

        // MARK: the contract with the trainer
        //
        // `MarkForest` was fitted in Python. If the feature extraction here and
        // the feature extraction there ever drift apart, the model is being fed
        // a distribution it never saw, accuracy falls, and absolutely nothing
        // goes red — the app still returns marks, they are just worse. That is
        // the failure this suite would otherwise miss entirely.
        //
        // So the fixture stores the exact input each side starts from (the
        // binarised mask after `withoutPrintedMarks`, bit-packed) alongside the
        // fourteen ratios and the probability Python computed from them. The
        // pipeline deliberately contains no resampling, so this is asserted as
        // equality within floating-point noise rather than to some tolerance
        // wide enough to hide a real divergence.
        let forestPath = (referencePath as NSString).deletingLastPathComponent
            + "/mark_forest.json"
        if let data = FileManager.default.contents(atPath: forestPath),
           let fixture = try? JSONDecoder().decode(ForestFixture.self, from: data) {
            var worstFeature = 0.0, worstProbability = 0.0
            var missing = 0, checked = 0
            for cell in fixture.cells {
                guard let mask = cell.unpackedMask() else { missing += 1; continue }
                guard let blob = MarkFeatures.isolate(mask: mask, width: cell.width,
                                                      height: cell.height) else {
                    if cell.found { missing += 1 }
                    continue
                }
                guard cell.found else { missing += 1; continue }
                let features = MarkFeatures.extract(mark: blob, width: cell.width,
                                                    height: cell.height)
                guard features.count == cell.features.count else { missing += 1; continue }
                checked += 1
                for (mine, theirs) in zip(features, cell.features) {
                    worstFeature = max(worstFeature, abs(mine - theirs))
                }
                worstProbability = max(worstProbability,
                                       abs(MarkForest.probabilityOfCross(features) - cell.probX))
            }
            check("mark.featuresMatchTrainer",
                  missing == 0 && checked == fixture.cells.count && worstFeature < 1e-9,
                  String(format: "%d/%d cells, worst feature delta %.3g",
                         checked, fixture.cells.count, worstFeature))
            check("mark.forestMatchesTrainer", worstProbability < 1e-9,
                  String(format: "worst P(cross) delta %.3g", worstProbability))
        } else {
            check("mark.featuresMatchTrainer", false, "cannot read \(forestPath)")
        }

        // MARK: shapes

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
                  String(format: "%@ at %.2f", wide.mark.rawValue, wide.confidence))
        } else {
            check("mark.wideOpenRingIsStillACircle", false, "no reading at all")
        }

        // MARK: parentheses, single answers, options, votes

        // A printed "( 1 )" whose box was drawn inside the parentheses: both
        // arcs sit outside the box and are far short of its full height —
        // the exact case the edge-and-span rule let through as two 1s.
        let bracketed = Shapes.bracketed(withStroke: true)
        let bracketedClean = bracketed.withoutPrintedMarks()
        let survivors = DigitRecognizer.segment(bracketedClean)
        check("cell.bracketPairErased",
              survivors.count == 1,
              "\(survivors.count) group(s) left of a ( 1 ) with the box inside the brackets")

        // …while an open circle drawn beside a printed ")" is NOT a pair of
        // brackets: it is nearly as wide as it is tall, and it is the answer.
        let openC = Shapes.openCircleBesideBracket()
        let openClean = openC.withoutPrintedMarks()
        check("cell.openCircleSurvivesBracketRule",
              openClean.coverage >= openC.coverage * 0.6,
              String(format: "ink kept %.0f%%", 100 * openClean.coverage / max(openC.coverage, 1e-9)))

        // The ○ is chosen around the printed box, not the middle of the patch.
        // A parenthesis nearer the patch's middle used to win and read as ✕.
        let offCentre = Shapes.ringInOffsetBox()
        check("mark.isolatesAtPrintedBox",
              MarkRecognizer.recognize(offCentre)?.mark == .circle,
              "ring in an off-centre box, an arc nearer the patch middle")

        // A choice question's options are its alphabet, not the answers that
        // happen to be right on this paper. Keyed only 2, 3 and 4, it still
        // offers 1; a 5 anywhere makes it 1–5; letters run from A.
        let keyedTwoToFour = AnswerKind.choiceOptions(from: ["2", "3", "4", "4", "2"])
        let keyedToFive = AnswerKind.choiceOptions(from: ["1", "5"])
        let circled = AnswerKind.choiceOptions(from: ["②", "③"])
        let lettered = AnswerKind.choiceOptions(from: ["B", "C"])
        check("options.fullAlphabet",
              keyedTwoToFour == ["1", "2", "3", "4"]
                && keyedToFive == ["1", "2", "3", "4", "5"]
                && circled == ["1", "2", "3", "4"]
                && lettered == ["A", "B", "C", "D"],
              "2/3/4 → \(keyedTwoToFour ?? []), 1/5 → \(keyedToFive ?? []), "
                + "②③ → \(circled ?? []), B/C → \(lettered ?? [])")

        if let recognizer,
           let data = FileManager.default.contents(atPath: referencePath),
           let reference = try? JSONDecoder().decode(Reference.self, from: data),
           reference.cases.count > 9,
           let six = try? recognizer.classify(reference.cases[1].input),
           let two = try? recognizer.classify(reference.cases[9].input) {
            // Case 1 is a confident 6: not an option on a 1–4 question, so the
            // restricted reading must be unconfident rather than "the nearest
            // option". Case 9 leans 2 with most of its belief on 1–4.
            let notAnOption = DigitRecognizer.restricted(six, to: [1, 2, 3, 4])
            check("digit.notAnOptionIsUnsure",
                  (1...4).contains(notAnOption.digit) && notAnOption.confidence == 0,
                  String(format: "model said %d at %.2f → %d at %.2f",
                         six.digit, six.confidence, notAnOption.digit, notAnOption.confidence))
            let option = DigitRecognizer.restricted(two, to: [1, 2, 3, 4])
            check("digit.optionKeepsTheModelsLeader",
                  option.digit == two.digit && option.confidence > two.confidence,
                  String(format: "%d at %.2f → %d at %.2f",
                         two.digit, two.confidence, option.digit, option.confidence))
        } else {
            check("digit.notAnOptionIsUnsure", false, "reference cases unavailable")
        }

        // Three frames read "1", three could not read anything: that is not a
        // settled 1. Five of eight is.
        var votes = AnswerAccumulator()
        let one = AnswerRecognizer.Reading(text: "1", confidence: 0.9, margin: 0.8, kind: .digits)
        let unsure = AnswerRecognizer.Reading(text: "1", confidence: 0.3, margin: 0.1, kind: .digits)
        for _ in 0..<3 { votes.add(one); votes.add(unsure) }
        let halfSettled = votes.isSettled
        votes.add(one); votes.add(one)
        check("vote.leaderMustBeMostLooks", !halfSettled && votes.isSettled,
              "3 of 6 looks does not settle; 5 of 8 does")

        // MARK: registration

        // A sheet with three rows of "（ ） n. 題目", a pink answer key in the
        // middle row's box. The "student's copy" is the same print moved 9px
        // right and 6px up — what a homography that is slightly off hands
        // over — with a pencil stroke in the box and no key. Registration has
        // to find exactly that shift, refuse blank paper, and the read window
        // has to come back holding the stroke and not the parentheses.
        let sheet = Shapes.registrationSheet(shift: .zero, answerKey: true, handwriting: false)
        let student = Shapes.registrationSheet(shift: CGPoint(x: 9, y: -6),
                                               answerKey: false, handwriting: true)
        let box = Shapes.registrationBox
        if let ink = MasterInk(sheet) {
            let t = CellTemplate(box: box, ink: ink, pageSize: sheet.size)
            let identity = XFeatMatcher.Homography(
                matrix: matrix_identity_double3x3, inlierCount: 100, matchCount: 100,
                sourceInlierBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                sourceInlierCentroid: CGPoint(x: 0.5, y: 0.5),
                sourceInlierSpread: CGSize(width: 0.3, height: 0.3))
            func place(_ frame: UIImage) -> (CellRegistration.Placement, FrameRegion)? {
                let quad = identity.projectedCorners(of: t.searchRect)
                guard let region = ImageCellSource(frame).region(covering: quad, maxSide: 2000),
                      let field = CellPatch(bitmap: region.bitmap, quad: quad.map(region.pixel),
                                            width: t.fieldWidth, height: t.fieldHeight),
                      let placement = CellRegistration.locate(t, in: field) else { return nil }
                return (placement, region)
            }
            check("register.templateUsable", t.isUsable,
                  "\(t.width)x\(t.height) template around the box")

            // Canonical pixels per sheet pixel, per axis.
            let perPixelX = t.scaleX / Double(sheet.size.width)
            let perPixelY = t.scaleY / Double(sheet.size.height)
            let wantX = 9 * perPixelX, wantY = -6 * perPixelY
            if let (placement, region) = place(student) {
                check("register.findsTheShift",
                      abs(Double(placement.dx) - wantX) <= 2 && abs(Double(placement.dy) - wantY) <= 2,
                      String(format: "found (%d, %d), expected (%.1f, %.1f), score %.2f",
                             placement.dx, placement.dy, wantX, wantY, placement.score))

                let window = ReadWindow(box: box,
                                        pads: (0.6 * Double(box.width), 0.6 * Double(box.width),
                                               1.0 * Double(box.height), 1.0 * Double(box.height)),
                                        template: t, ink: ink)
                let corrected = box.offsetBy(dx: CGFloat(Double(placement.dx) / t.scaleX),
                                             dy: CGFloat(Double(placement.dy) / t.scaleY))
                let quad = identity.projectedCorners(of: window.rect(around: corrected)).map(region.pixel)
                if let raw = CellPatch(bitmap: region.bitmap, quad: quad, width: window.width,
                                       height: window.height, printedBounds: window.printedBounds),
                   let cleaned = window.cleaned(raw) {
                    // The stroke runs from inside the box into the ")" and
                    // joins it. Inside the box nothing may be lost; right of
                    // the box, where the parenthesis is, almost all of it must.
                    let bx0 = Int(Double(window.printedBounds.minX) * Double(raw.width))
                    let bx1 = Int(Double(window.printedBounds.maxX) * Double(raw.width))
                    let by0 = Int(Double(window.printedBounds.minY) * Double(raw.height))
                    let by1 = Int(Double(window.printedBounds.maxY) * Double(raw.height))
                    func ink(_ patch: CellPatch, _ x0: Int, _ x1: Int) -> Int {
                        var n = 0
                        for y in by0..<by1 {
                            for x in max(0, x0)..<min(patch.width, x1) where patch.mask[y * patch.width + x] {
                                n += 1
                            }
                        }
                        return n
                    }
                    let insideBefore = ink(raw, bx0 + 2, bx1 - 2)
                    let insideAfter = ink(cleaned.patch, bx0 + 2, bx1 - 2)
                    let rightBefore = ink(raw, bx1 + 3, raw.width)
                    let rightAfter = ink(cleaned.patch, bx1 + 3, raw.width)
                    check("register.erasesPrintKeepsStroke",
                          insideBefore > 0 && Double(insideAfter) >= 0.8 * Double(insideBefore)
                            && rightBefore > 0 && Double(rightAfter) <= 0.35 * Double(rightBefore),
                          "inside the box \(insideBefore)→\(insideAfter) px, "
                            + "over the parenthesis \(rightBefore)→\(rightAfter) px")
                } else {
                    check("register.erasesPrintKeepsStroke", false, "window could not be sampled")
                }
            } else {
                check("register.findsTheShift", false, "nothing found")
            }
            check("register.refusesBlankPaper", place(Shapes.blankSheet()) == nil,
                  "plain paper has no print to line up with")
        } else {
            check("register.templateUsable", false, "could not read the synthetic master")
        }

        // Rows one box apart, as on the 自然 paper: the middle cell's window
        // has to reach the full padY up and down — the cell above's edge —
        // or a 2 that rises a cell above its box is cut and read as 4. Boxes
        // that touch must still get no reach into each other at all, and
        // sideways keeps the midline.
        let unit = CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05)
        let stacked = [unit.offsetBy(dx: 0, dy: -0.1), unit, unit.offsetBy(dx: 0, dy: 0.1),
                       unit.offsetBy(dx: 0.2, dy: 0)]
        let touching = [unit.offsetBy(dx: 0, dy: -0.05), unit]
        let padY = Double(ReadWindow.Tuning.padY), padX = Double(ReadWindow.Tuning.padX)
        let spaced = LiveScanEngine.pads(stacked, pageOf: [0, 0, 0, 0],
                                         padX: CGFloat(padX), padY: CGFloat(padY))[1]
        let tight = LiveScanEngine.pads(touching, pageOf: [0, 0],
                                        padX: CGFloat(padX), padY: CGFloat(padY))[1]
        check("window.reachesNeighbourEdge",
              abs(spaced.top - padY * 0.05) < 1e-9 && abs(spaced.bottom - padY * 0.05) < 1e-9
                && abs(spaced.right - min(padX * 0.1, 0.05)) < 1e-9 && tight.top < 1e-9,
              String(format: "top %.3f bottom %.3f right %.3f; touching top %.3f",
                     spaced.top, spaced.bottom, spaced.right, tight.top))

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

        /// One arc of a circle centred at (cx, cy), from `from` to `to`
        /// degrees (0 = right, 90 = down), drawn `thickness` px wide.
        static func arc(_ values: inout [Double], width: Int, height: Int,
                        cx: Double, cy: Double, radius: Double,
                        from: Double, to: Double, thickness: Double = 1.6) {
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    guard abs((dx * dx + dy * dy).squareRoot() - radius) <= thickness else { continue }
                    var degrees = atan2(dy, dx) * 180 / .pi
                    if degrees < from { degrees += 360 }
                    if degrees <= to { values[y * width + x] = ink }
                }
            }
        }

        /// "( 1 )" with the printed box drawn inside the parentheses, the way
        /// the 自然 template's boxes are: arcs outside the box, ~60% of its
        /// height, a handwritten 1 in the middle.
        static func bracketed(withStroke: Bool) -> CellPatch {
            let w = 96, h = 64
            var values = [Double](repeating: paper, count: w * h)
            // Brackets: arcs of a large circle, bowing outwards.
            arc(&values, width: w, height: h, cx: 34, cy: 32, radius: 22, from: 150, to: 210)
            arc(&values, width: w, height: h, cx: 62, cy: 32, radius: 22, from: -30, to: 30)
            if withStroke {
                for y in 18..<46 {
                    for x in 46..<49 { values[y * w + x] = ink }
                }
            }
            // The box: inside the brackets, a little taller than them.
            return CellPatch(width: w, height: h, intensity: values,
                             printedBounds: CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.76))
        }

        /// An open circle (a C, a third missing) with a printed ")" beside it.
        static func openCircleBesideBracket() -> CellPatch {
            let w = 96, h = 64
            var values = [Double](repeating: paper, count: w * h)
            arc(&values, width: w, height: h, cx: 44, cy: 32, radius: 16, from: 60, to: 300)
            arc(&values, width: w, height: h, cx: 62, cy: 32, radius: 22, from: -30, to: 30)
            return CellPatch(width: w, height: h, intensity: values,
                             printedBounds: CGRect(x: 0.2, y: 0.12, width: 0.6, height: 0.76))
        }

        /// A closed ring in a printed box that sits right of the patch's
        /// middle, and a lone arc nearer that middle than the ring is.
        static func ringInOffsetBox() -> CellPatch {
            let w = 120, h = 64
            var values = [Double](repeating: paper, count: w * h)
            arc(&values, width: w, height: h, cx: 81, cy: 32, radius: 17, from: 0, to: 360)
            arc(&values, width: w, height: h, cx: 72, cy: 32, radius: 24, from: 160, to: 200)
            return CellPatch(width: w, height: h, intensity: values,
                             printedBounds: CGRect(x: 0.5, y: 0.1, width: 0.35, height: 0.8))
        }

        /// Where the registration sheet's middle answer box is, normalized.
        static let registrationBox = CGRect(x: 240.0 / 600, y: 360.0 / 800,
                                            width: 56.0 / 600, height: 44.0 / 800)

        /// Three rows of "（  ） n. 題目文字" on white, the middle row's box at
        /// `registrationBox`; optionally a pink answer key in that box and a
        /// pencil stroke through it, the whole print moved by `shift` pixels.
        static func registrationSheet(shift: CGPoint, answerKey: Bool,
                                      handwriting: Bool) -> UIImage {
            let size = CGSize(width: 600, height: 800)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                let font = UIFont.systemFont(ofSize: 40)
                let small = UIFont.systemFont(ofSize: 26)
                let black: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
                let text: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: UIColor.black]
                let box = CGRect(x: 240 + shift.x, y: 360 + shift.y, width: 56, height: 44)
                for (row, label) in [(-1, "2. 下列何者正確"), (0, "3. 土壤的顆粒"), (1, "4. 承上題的實驗")] {
                    let y = box.minY + CGFloat(row) * 130
                    ("(" as NSString).draw(at: CGPoint(x: box.minX - 20, y: y - 6), withAttributes: black)
                    (")" as NSString).draw(at: CGPoint(x: box.maxX + 6, y: y - 6), withAttributes: black)
                    (label as NSString).draw(at: CGPoint(x: box.maxX + 34, y: y + 4), withAttributes: text)
                }
                if answerKey {
                    let pink: [NSAttributedString.Key: Any] = [
                        .font: font, .foregroundColor: UIColor(red: 0.85, green: 0.2, blue: 0.5, alpha: 1)]
                    ("4" as NSString).draw(at: CGPoint(x: box.minX + 16, y: box.minY - 4), withAttributes: pink)
                }
                if handwriting {
                    // From the top of the box, down and right into the ")".
                    let stroke = UIBezierPath()
                    stroke.move(to: CGPoint(x: box.minX + 10, y: box.minY + 4))
                    stroke.addLine(to: CGPoint(x: box.maxX + 12, y: box.maxY - 6))
                    stroke.lineWidth = 3
                    UIColor(white: 0.15, alpha: 1).setStroke()
                    stroke.stroke()
                }
            }
        }

        static func blankSheet() -> UIImage {
            let size = CGSize(width: 600, height: 800)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor(white: 0.97, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
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
