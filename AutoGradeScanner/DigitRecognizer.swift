import CoreML
import Foundation

// Handwritten digit recognition on device.
//
// The bundled DigitCNN.mlpackage carries the *same weights* the backend serves
// at /ocr (ocr_api/models/mnist_cnn.pth, a four-layer MNIST CNN), so moving
// recognition onto the phone does not change anyone's grade. What does change
// is the input quality: the server receives an axis-aligned crop of a
// photographed sheet, while here the cell arrives already perspective-corrected
// through the XFeat homography.
//
// The preprocessing below rebuilds the MNIST convention that the backend's
// `preprocess_digit_image` skips. It resizes the whole crop straight to 28x28,
// but MNIST digits were normalised: scaled to fit a 20x20 box with the aspect
// ratio kept, then placed in 28x28 so the centre of mass sits in the middle.
// A model trained on centred, size-normalised digits and fed uncentred,
// stretched ones is being asked a different question than it was trained on,
// and the accuracy loss is silent.

enum DigitRecognizerError: Error {
    case modelMissing
    case badOutput
}

final class DigitRecognizer {

    struct DigitReading {
        let digit: Int
        let confidence: Double
        /// All ten, kept so callers can accumulate evidence across frames
        /// instead of re-deciding from scratch each time.
        let probabilities: [Double]

        /// Lead over the runner-up. A digit can carry a respectable softmax and
        /// still be a coin flip between two classes — which is exactly how the
        /// one misread cell in the real fixtures behaves (0.53 top, 0.45
        /// second). Softmax alone would wave that through.
        var margin: Double {
            let sorted = probabilities.sorted(by: >)
            return sorted.count >= 2 ? sorted[0] - sorted[1] : sorted.first ?? 0
        }
    }

    struct Result {
        /// The digits left to right, e.g. "144".
        let text: String
        /// The weakest digit in the string — one bad character is a wrong answer.
        let confidence: Double
        /// Likewise the narrowest margin: the string is only as sure as its
        /// shakiest character.
        let margin: Double
        let digits: [DigitReading]
        /// Ink groups dropped because the cell holds one character.
        var discarded: Int = 0
    }

    /// How many characters the cell can hold.
    enum Arity {
        /// However many are written — a fill-in blank, 12 or 144.
        case any
        /// Exactly one, because the cell is a multiple-choice answer.
        case single
    }

    enum Tuning {
        /// Ink blobs below this share of the cell are specks, box-rule
        /// fragments, or the tail of a neighbouring cell.
        static let minComponentAreaRatio = 0.006
        /// Two blobs whose horizontal spans overlap by more than this share of
        /// the narrower one belong to the same digit. This is what keeps a
        /// two-stroke 4 or 5 from being read as two digits, and it beats a
        /// vertical projection profile on slanted handwriting.
        static let mergeOverlapRatio = 0.5
        /// More blobs than any plausible answer means the segmentation has
        /// fallen apart; recognising 9 fragments would just produce noise.
        static let maxDigits = 6
        /// In a single-character cell, the runner-up blob has to be clearly
        /// smaller than the winner before the winner can be called the answer.
        /// Two blobs of similar size mean the cell genuinely holds something
        /// this cannot resolve, and picking the larger would be a coin flip
        /// dressed up as a reading — better to keep the old behaviour and let
        /// the cell settle as unsure.
        static let ambiguousAreaRatio = 0.6
        /// MNIST's own normalisation: fit the ink into 20px, centre in 28px.
        static let inkBox = 20.0
        static let canvas = 28
    }

    private let model: MLModel

    init() throws {
        guard let url = Bundle.main.url(forResource: "DigitCNN", withExtension: "mlmodelc") else {
            throw DigitRecognizerError.modelMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Returns nil when the cell is blank or nothing survives segmentation.
    func recognize(_ patch: CellPatch, arity: Arity = .any) throws -> Result? {
        guard !patch.isBlank, patch.coverage <= CellPatch.Tuning.maxCoverage else { return nil }

        var groups = Self.segment(patch)
        guard !groups.isEmpty, groups.count <= Tuning.maxDigits else { return nil }

        var discarded = 0
        // A multiple-choice cell holds one character, so a second blob is
        // something else that got into the crop — printed rule, a neighbour's
        // stroke, a speck. Reading it as a second digit produces a string that
        // can never match the answer key, and splits the vote with the frames
        // that only saw one blob until neither reaches a majority.
        if arity == .single, groups.count > 1 {
            let byArea = groups
                .map { mask in (mask: mask, area: mask.lazy.filter { $0 }.count) }
                .sorted { $0.area > $1.area }
            let winner = byArea[0], runnerUp = byArea[1]
            // Only when the winner is clearly the winner. Similar sizes mean
            // this cannot tell which one is the answer, and the honest result
            // of that is the unsure it would have reached anyway.
            if runnerUp.area == 0
                || Double(runnerUp.area) / Double(winner.area) < Tuning.ambiguousAreaRatio {
                discarded = groups.count - 1
                groups = [winner.mask]
            }
        }

        var readings: [DigitReading] = []
        for group in groups {
            guard let grid = Self.mnistGrid(patch, subset: group) else { continue }
            readings.append(try classify(grid))
        }
        guard !readings.isEmpty else { return nil }

        return Result(text: readings.map { String($0.digit) }.joined(),
                      confidence: readings.map(\.confidence).min() ?? 0,
                      margin: readings.map(\.margin).min() ?? 0,
                      digits: readings,
                      discarded: discarded)
    }

    /// Runs one 28x28 grid (0 = paper, 1 = ink) through the model.
    func classify(_ grid: [Double]) throws -> DigitReading {
        let side = Tuning.canvas
        precondition(grid.count == side * side, "grid must be 28x28")

        let array = try MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for i in 0..<grid.count { buffer[i] = Float(grid[i]) }
        }

        let input = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: array)])
        let output = try model.prediction(from: input)
        guard let probabilities = output.featureValue(for: "probabilities")?.multiArrayValue,
              probabilities.count == 10 else {
            throw DigitRecognizerError.badOutput
        }

        var values = [Double](repeating: 0, count: 10)
        for i in 0..<10 { values[i] = probabilities[i].doubleValue }
        let best = values.enumerated().max { $0.element < $1.element }?.offset ?? 0
        return DigitReading(digit: best, confidence: values[best], probabilities: values)
    }

    // MARK: - Segmentation

    /// Splits the cell's ink into one mask per digit, ordered left to right.
    static func segment(_ patch: CellPatch) -> [[Bool]] {
        let (labels, count) = ConnectedComponents.label(patch.mask, width: patch.width,
                                                        height: patch.height, connectivity: .eight)
        guard count > 0 else { return [] }

        var areas = [Int](repeating: 0, count: count + 1)
        var minX = [Int](repeating: patch.width, count: count + 1)
        var maxX = [Int](repeating: -1, count: count + 1)
        for y in 0..<patch.height {
            for x in 0..<patch.width {
                let label = labels[y * patch.width + x]
                guard label > 0 else { continue }
                areas[label] += 1
                if x < minX[label] { minX[label] = x }
                if x > maxX[label] { maxX[label] = x }
            }
        }

        let minArea = Double(patch.width * patch.height) * Tuning.minComponentAreaRatio
        var groups: [(labels: Set<Int>, minX: Int, maxX: Int)] = []
        for label in 1...count where Double(areas[label]) >= minArea {
            groups.append(([label], minX[label], maxX[label]))
        }
        guard !groups.isEmpty else { return [] }

        // Merge horizontally overlapping blobs until nothing more merges.
        var merged = true
        while merged {
            merged = false
            outer: for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let a = groups[i], b = groups[j]
                    let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX) + 1
                    let narrower = min(a.maxX - a.minX, b.maxX - b.minX) + 1
                    guard overlap > 0,
                          Double(overlap) / Double(narrower) > Tuning.mergeOverlapRatio else { continue }
                    groups[i] = (a.labels.union(b.labels),
                                 min(a.minX, b.minX), max(a.maxX, b.maxX))
                    groups.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }

        return groups.sorted { $0.minX < $1.minX }.map { group in
            labels.map { $0 > 0 && group.labels.contains($0) }
        }
    }

    // MARK: - MNIST normalisation

    /// Builds the 28x28 input MNIST expects from one digit's pixels.
    ///
    /// `subset` selects which of the patch's ink belongs to this digit; the
    /// grayscale values come from the patch itself, because MNIST digits are
    /// anti-aliased rather than binary and the model has never seen hard edges.
    static func mnistGrid(_ patch: CellPatch, subset: [Bool]) -> [Double]? {
        guard let bounds = patch.inkBounds(of: subset) else { return nil }
        let boxWidth = bounds.maxX - bounds.minX + 1
        let boxHeight = bounds.maxY - bounds.minY + 1

        // Stretch the ink's own dynamic range to fill 0…1. Camera ink is grey,
        // not black, and MNIST's is saturated; without this the model sees a
        // faint ghost of the digit it was trained on.
        var inkValues: [Double] = []
        for i in 0..<subset.count where subset[i] { inkValues.append(patch.intensity[i]) }
        guard !inkValues.isEmpty else { return nil }
        inkValues.sort()
        let peak = inkValues[Int(Double(inkValues.count - 1) * 0.95)]
        let span = max(peak - patch.threshold, 1e-6)

        func stretched(_ x: Double, _ y: Double) -> Double {
            let px = min(max(x, 0), Double(patch.width) - 1e-6)
            let py = min(max(y, 0), Double(patch.height) - 1e-6)
            let ix = Int(px), iy = Int(py)
            let index = iy * patch.width + ix
            guard subset[index] else { return 0 }
            return min(max((patch.intensity[index] - patch.threshold) / span, 0), 1)
        }

        // Fit the longer side into 20px, keeping the aspect ratio.
        let scale = Tuning.inkBox / Double(max(boxWidth, boxHeight))
        let targetWidth = max(1, Int((Double(boxWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(boxHeight) * scale).rounded()))

        // Supersample each target pixel across its source footprint, so
        // shrinking a 60px stroke to 20px averages rather than picks one row.
        let taps = 3
        var scaled = [Double](repeating: 0, count: targetWidth * targetHeight)
        for ty in 0..<targetHeight {
            for tx in 0..<targetWidth {
                var sum = 0.0
                for sy in 0..<taps {
                    for sx in 0..<taps {
                        let u = (Double(tx) + (Double(sx) + 0.5) / Double(taps)) / Double(targetWidth)
                        let v = (Double(ty) + (Double(sy) + 0.5) / Double(taps)) / Double(targetHeight)
                        sum += stretched(Double(bounds.minX) + u * Double(boxWidth),
                                         Double(bounds.minY) + v * Double(boxHeight))
                    }
                }
                scaled[ty * targetWidth + tx] = sum / Double(taps * taps)
            }
        }

        // Place it so the centre of mass lands in the middle of the canvas —
        // this, not the bounding box, is how MNIST was centred.
        var mass = 0.0, momentX = 0.0, momentY = 0.0
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let v = scaled[y * targetWidth + x]
                mass += v
                momentX += v * (Double(x) + 0.5)
                momentY += v * (Double(y) + 0.5)
            }
        }
        guard mass > 0 else { return nil }

        let side = Tuning.canvas
        let centre = Double(side) / 2
        let offsetX = Int((centre - momentX / mass).rounded())
        let offsetY = Int((centre - momentY / mass).rounded())

        var canvas = [Double](repeating: 0, count: side * side)
        for y in 0..<targetHeight {
            let dy = y + offsetY
            guard dy >= 0, dy < side else { continue }
            for x in 0..<targetWidth {
                let dx = x + offsetX
                guard dx >= 0, dx < side else { continue }
                canvas[dy * side + dx] = scaled[y * targetWidth + x]
            }
        }
        return canvas
    }
}
