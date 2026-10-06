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
        /// Set when the reading was re-decided among a question's options:
        /// the lead is then over the runner-up OPTION, not over a class the
        /// student could not have meant.
        var optionMargin: Double? = nil

        /// Lead over the runner-up. A digit can carry a respectable softmax and
        /// still be a coin flip between two classes — which is exactly how the
        /// one misread cell in the real fixtures behaves (0.53 top, 0.45
        /// second). Softmax alone would wave that through.
        var margin: Double {
            if let optionMargin { return optionMargin }
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
        /// Ink groups beyond the first in a cell that holds one character —
        /// dropped as strays, or merged into the answer when the caller knows
        /// every remaining stroke is the student's.
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
        /// Stroke width, in pixels of that 20px box, that MNIST digits are
        /// written with. A child's digit that runs two cells tall is a thin
        /// line by the time it is shrunk to 20px, and the model reads a faint
        /// ghost of it: the real-cell fixtures go from 5/6 to 6/6 once the
        /// stroke is thickened back to this before shrinking.
        static let targetStroke = 2.2
        /// When the cell is a multiple-choice answer, the share of the model's
        /// belief that has to fall on the paper's own options before the
        /// best of them is taken seriously. Below it, the model is looking at
        /// something that is not an option at all — a 5 written on a 1–4
        /// question — and mapping that onto the nearest option is how a wrong
        /// answer gets marked right.
        static let minOptionMass = 0.5
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
    ///
    /// `options` is the paper's own alphabet for a multiple-choice cell —
    /// 1…4 — and only ever narrows the reading to it; see `restricted`.
    /// `merging` says every stroke left in the patch is the student's (the
    /// printed furniture has been erased against the master and only strokes
    /// touching the answer box were kept), so a second group is part of the
    /// same character rather than a stray.
    func recognize(_ patch: CellPatch, arity: Arity = .any,
                   options: [Int]? = nil, merging: Bool = false) throws -> Result? {
        guard !patch.isBlank, patch.coverage <= CellPatch.Tuning.maxCoverage else { return nil }

        var groups = Self.segment(patch)
        guard !groups.isEmpty, groups.count <= Tuning.maxDigits else { return nil }

        var discarded = 0
        // A multiple-choice cell holds one character, so a second group is
        // either more of that character or something else that got into the
        // crop — printed rule, a neighbour's stroke, a speck. Reading each
        // group as its own digit produced "111" off a "( 1 )": a string that
        // can never match the answer key, and that settled as a confident
        // wrong answer whenever every frame made the same mistake.
        if arity == .single, groups.count > 1 {
            discarded = groups.count - 1
            if merging {
                var union = [Bool](repeating: false, count: groups[0].count)
                for group in groups {
                    for i in 0..<union.count where group[i] { union[i] = true }
                }
                groups = [union]
            } else {
                let byArea = groups
                    .map { mask in (mask: mask, area: mask.lazy.filter { $0 }.count) }
                    .sorted { $0.area > $1.area }
                let winner = byArea[0], runnerUp = byArea[1]
                // Only when the winner is clearly the winner. Similar sizes
                // mean this cannot tell which one is the answer, and the
                // honest result of that is no reading at all.
                guard runnerUp.area == 0
                        || Double(runnerUp.area) / Double(winner.area) < Tuning.ambiguousAreaRatio
                else { return nil }
                groups = [winner.mask]
            }
        }

        var readings: [DigitReading] = []
        for group in groups {
            guard let grid = Self.mnistGrid(patch, subset: group) else { continue }
            let reading = try classify(grid)
            if arity == .single, let options, !options.isEmpty {
                readings.append(Self.restricted(reading, to: options))
            } else {
                readings.append(reading)
            }
        }
        guard !readings.isEmpty else { return nil }

        return Result(text: readings.map { String($0.digit) }.joined(),
                      confidence: readings.map(\.confidence).min() ?? 0,
                      margin: readings.map(\.margin).min() ?? 0,
                      digits: readings,
                      discarded: discarded)
    }

    /// The reading, re-decided among the paper's own options.
    ///
    /// This uses the answer key's ALPHABET, never its answer: which four
    /// options a question offers is a fact about the question, the same fact
    /// the correction screen already reads to offer its buttons. What it buys
    /// is the belief the model spent on classes the student could not have
    /// meant. A child's 4 read as 4 at 0.49, with 9 and 7 splitting the rest,
    /// is a 4 at 0.80 among 1–4 — confident enough to vote — where before it
    /// was a cell that never settled. When most of the belief is NOT on the
    /// options (`Tuning.minOptionMass`), nothing is re-decided: the reading
    /// comes back with no confidence and the cell goes to the teacher.
    ///
    /// The probabilities kept are the model's own, untouched, so a caller
    /// accumulating evidence still sees what the model saw.
    static func restricted(_ reading: DigitReading, to options: [Int]) -> DigitReading {
        let valid = options.filter { $0 >= 0 && $0 < reading.probabilities.count }
        guard !valid.isEmpty else { return reading }
        let mass = valid.reduce(0.0) { $0 + reading.probabilities[$1] }
        let ranked = valid.sorted { reading.probabilities[$0] > reading.probabilities[$1] }
        guard mass >= Tuning.minOptionMass, mass > 0 else {
            // Not an option. Report the nearest one for diagnostics, with no
            // confidence at all, so it can never vote.
            return DigitReading(digit: ranked[0], confidence: 0, probabilities: reading.probabilities,
                                optionMargin: 0)
        }
        let top = reading.probabilities[ranked[0]] / mass
        let second = ranked.count > 1 ? reading.probabilities[ranked[1]] / mass : 0
        return DigitReading(digit: ranked[0], confidence: top, probabilities: reading.probabilities,
                            optionMargin: top - second)
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

        // Against the printed cell, so "too small to be a digit" keeps meaning
        // what it was measured to mean when the sampler read the cell exactly.
        let minArea = patch.printedArea * Tuning.minComponentAreaRatio
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
    ///
    /// The stroke is thickened first when shrinking would leave it thinner
    /// than MNIST's own (`Tuning.targetStroke`). A digit twice the cell's
    /// height, written with an ordinary pencil, arrives at 20px as a line a
    /// third of a pixel wide; the supersampling below averages it into a grey
    /// smear and the model, which was trained on bold strokes, guesses.
    static func mnistGrid(_ patch: CellPatch, subset: [Bool]) -> [Double]? {
        guard let bounds = patch.inkBounds(of: subset) else { return nil }
        let boxWidth = bounds.maxX - bounds.minX + 1
        let boxHeight = bounds.maxY - bounds.minY + 1
        let scale = Tuning.inkBox / Double(max(boxWidth, boxHeight))
        let needed = Tuning.targetStroke / scale
        let radius = Int(((needed - strokeWidth(subset, width: patch.width,
                                                 height: patch.height)) / 2).rounded())
        guard radius >= 1 else {
            return rasterize(intensity: patch.intensity, subset: subset, patch: patch)
        }
        let (intensity, grown) = thickened(patch, subset: subset, radius: radius)
        return rasterize(intensity: intensity, subset: grown, patch: patch)
    }

    /// Mean stroke width of a mask, in pixels: twice its area over its
    /// perimeter, which for a thin stroke is area over length. Pixels on the
    /// image border count as perimeter, as if the paper ended there.
    static func strokeWidth(_ subset: [Bool], width: Int, height: Int) -> Double {
        var area = 0, interior = 0
        for y in 0..<height {
            for x in 0..<width where subset[y * width + x] {
                area += 1
                guard x > 0, x < width - 1, y > 0, y < height - 1 else { continue }
                let i = y * width + x
                if subset[i - 1], subset[i + 1], subset[i - width], subset[i + width] {
                    interior += 1
                }
            }
        }
        guard area > 0 else { return 0 }
        return 2 * Double(area) / Double(max(area - interior, 1))
    }

    /// The digit grown by `radius` pixels (a diamond, 4-connected steps), the
    /// new pixels taking the darkest ink within `radius` in either axis so the
    /// thickened stroke stays as dark as the one it came from.
    private static func thickened(_ patch: CellPatch, subset: [Bool],
                                  radius: Int) -> (intensity: [Double], subset: [Bool]) {
        let width = patch.width, height = patch.height
        var grown = subset
        for _ in 0..<radius {
            var next = grown
            for y in 0..<height {
                for x in 0..<width where !grown[y * width + x] {
                    let i = y * width + x
                    if (x > 0 && grown[i - 1]) || (x < width - 1 && grown[i + 1])
                        || (y > 0 && grown[i - width]) || (y < height - 1 && grown[i + width]) {
                        next[i] = true
                    }
                }
            }
            grown = next
        }
        // Square max filter over the digit's own ink, zero outside it.
        var intensity = patch.intensity
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                guard grown[i], !subset[i] else { continue }
                var strongest = 0.0
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    for xx in max(0, x - radius)...min(width - 1, x + radius) {
                        let j = yy * width + xx
                        if subset[j], patch.intensity[j] > strongest { strongest = patch.intensity[j] }
                    }
                }
                intensity[i] = strongest
            }
        }
        return (intensity, grown)
    }

    private static func rasterize(intensity: [Double], subset: [Bool],
                                  patch: CellPatch) -> [Double]? {
        guard let bounds = patch.inkBounds(of: subset) else { return nil }
        let boxWidth = bounds.maxX - bounds.minX + 1
        let boxHeight = bounds.maxY - bounds.minY + 1

        // Stretch the ink's own dynamic range to fill 0…1. Camera ink is grey,
        // not black, and MNIST's is saturated; without this the model sees a
        // faint ghost of the digit it was trained on.
        var inkValues: [Double] = []
        for i in 0..<subset.count where subset[i] { inkValues.append(intensity[i]) }
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
            return min(max((intensity[index] - patch.threshold) / span, 0), 1)
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
