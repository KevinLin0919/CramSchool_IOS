import UIKit

// Shared front end for on-device answer recognition.
//
// Recognition never looks at a camera frame directly — it looks at a CellPatch,
// which is one answer cell lifted out of the frame and flattened. This matters
// because the live scanner already knows where every cell is: the XFeat
// homography maps the master sheet onto the frame, so a cell can be
// perspective-corrected on the way out instead of being cropped as an
// axis-aligned rectangle. A sheet photographed at an angle still yields an
// upright, undistorted patch with no neighbouring ink or box rule bleeding in,
// which is a better input than the server ever receives.

// MARK: - Frame

/// One camera frame as an 8-bit grayscale buffer.
///
/// A cell is sampled thousands of times, and a frame holds several cells, so the
/// frame is converted once and shared rather than going back through
/// CoreGraphics per box.
struct GrayBitmap {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    /// `image` is expected to be upright already (see `normalizedForUpload`),
    /// since `cgImage` ignores `imageOrientation`.
    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let w = cgImage.width, h = cgImage.height
        var buffer = [UInt8](repeating: 0, count: w * h)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        width = w
        height = h
        pixels = buffer
    }

    /// These pixels as an image, for keeping alongside a verdict.
    ///
    /// It matters that this is the bitmap recognition actually read rather
    /// than a fresh crop of the frame: a teacher reviewing a verdict later is
    /// then looking at exactly what the model looked at, so "the model was
    /// wrong" and "the model was pointed at the wrong place" stay
    /// distinguishable.
    func makeImage() -> UIImage? {
        var buffer = pixels
        return buffer.withUnsafeMutableBytes { raw -> UIImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cgImage = context.makeImage() else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }

    /// How much detail this buffer holds — the variance of its Laplacian.
    ///
    /// A sharp edge produces a large second derivative; a blurred one spreads
    /// the same ink over more pixels and flattens it. Taking the variance
    /// rather than the mean is what makes the number comparable between cells:
    /// the mean is dominated by how much ink there is, the variance by how
    /// abruptly it starts and stops.
    ///
    /// Not an absolute measure of anything. It is only ever used to rank two
    /// crops of the same cell, where the ink is the same and only the focus
    /// and the sampling differ.
    func sharpness() -> Double {
        guard width >= 3, height >= 3 else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let lap = 4.0 * Double(pixels[i])
                    - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - width]) - Double(pixels[i + width])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Bilinear sample in pixel coordinates, clamped at the edges. 0 = black, 1 = white.
    func sample(_ x: CGFloat, _ y: CGFloat) -> Double {
        let fx = min(max(Double(x) - 0.5, 0), Double(width - 1))
        let fy = min(max(Double(y) - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let p00 = Double(pixels[y0 * width + x0]), p10 = Double(pixels[y0 * width + x1])
        let p01 = Double(pixels[y1 * width + x0]), p11 = Double(pixels[y1 * width + x1])
        let top = p00 + (p10 - p00) * tx
        let bottom = p01 + (p11 - p01) * tx
        return (top + (bottom - top) * ty) / 255
    }
}

// MARK: - Cell

/// One answer cell, perspective-corrected into an upright rectangle.
struct CellPatch {
    /// Longest side of the sampled patch.
    ///
    /// Measured, not guessed: on the real cells in TestFixtures, sampling the
    /// long side at 64 scores 3/6 while 96 and 128 both score 6/6. At 64 a pen
    /// stroke is barely two pixels wide, so a digit touching the printed border
    /// fuses into one component and the border can no longer be told apart from
    /// the answer. 128 also stays at or below the native size of a cell in a
    /// 1200px frame, so it costs sampling work but never invents detail.
    static let defaultMaxSide = 128

    /// `printedBounds` for a patch sampled exactly on the printed cell.
    static let wholePatch = CGRect(x: 0, y: 0, width: 1, height: 1)

    let width: Int
    let height: Int

    /// Ink intensity per pixel, 0 = paper … 1 = darkest ink. Inverted relative
    /// to the source pixels so it already matches MNIST's white-on-black
    /// convention — the same inversion the backend does with `ImageOps.invert`.
    let intensity: [Double]

    /// Otsu split of `intensity`, plus the two numbers that say whether the
    /// split means anything.
    let threshold: Double
    /// Gap between the paper and ink class means. A blank cell has no gap.
    let separation: Double
    /// Fraction of pixels above `threshold`.
    let coverage: Double

    /// `intensity > threshold`.
    let mask: [Bool]

    /// Where the *printed* answer cell sits inside this patch, as fractions of
    /// it. The whole patch, unless a caller sampled wider than the cell.
    ///
    /// Every threshold in this file and in the two recognisers is a fraction
    /// of "the cell" — how much ink makes it non-blank, how big a hole has to
    /// be to count, how close to an edge a stroke has to run before it is
    /// printed furniture. Those numbers were measured against the printed box,
    /// so when the sampler reads past it — which it does, because children
    /// write over the lines — the ratios have to keep being taken against the
    /// box, or every one of them silently tightens by the square of however
    /// much wider the window got.
    let printedBounds: CGRect

    /// Area of the printed cell in patch pixels. The denominator for anything
    /// expressed as a share of the cell.
    var printedArea: Double {
        Double(width) * printedBounds.width * Double(height) * printedBounds.height
    }

    /// The printed cell's shorter side, in patch pixels.
    var printedSide: Double {
        min(Double(width) * printedBounds.width, Double(height) * printedBounds.height)
    }

    /// A cell with too little ink, or with no real dark/light split, holds no
    /// answer. Recognising it anyway would confidently return a wrong digit,
    /// so both recognisers bail out on this first.
    var isBlank: Bool {
        let inked = coverage * Double(width * height)
        return separation < Tuning.minSeparation
            || inked < Tuning.minCoverage * printedArea
    }

    enum Tuning {
        /// Below this the patch is one flat tone — paper, or a blown-out
        /// highlight — and Otsu is splitting noise.
        static let minSeparation = 0.12
        /// A digit or mark covers at least this share of its cell.
        static let minCoverage = 0.012
        /// Above this the "cell" is mostly dark: a shadow, a finger, or a
        /// misprojected box that landed on the sheet's edge.
        static let maxCoverage = 0.75

        // MARK: printed-mark removal

        /// A printed rule is far longer than it is thick.
        static let printedElongation = 2.5
        /// A VERTICAL rule must also run most of the way down the cell, because
        /// a handwritten "1" is long and thin too and elongation alone would eat
        /// it. The horizontal rule needs no such guard — a "1" is taller than it
        /// is wide, so it can never satisfy `width > 2.5 × height` — and adding
        /// one there costs real accuracy: it drops the fixtures from 6/6 to 5/6
        /// by sparing parenthesis arcs that fall just short of the span.
        static let printedVerticalSpan = 0.7
        /// …and sits against an edge, because that is where the answer box's
        /// own border lives.
        ///
        /// This has to be narrow. A "2" written in the local style ends in a
        /// long flat base, which is every bit as wide-and-flat as a ruled line;
        /// the only thing telling them apart is that the printed rule is at the
        /// cell boundary and the digit's base is merely near it. At 0.18 a "2"
        /// filling its box lost its base and read as a confident "7". Swept
        /// against both the real fixtures and the generated 9007 sheet, 0.05
        /// to 0.10 scores 6/6 on both; below that the parenthesis arcs start
        /// surviving, above it digits start losing strokes.
        static let printedEdgeBand = 0.08
        /// Specks below this share of the cell are paper texture or JPEG noise.
        static let minSpeckArea = 0.0015

        /// A closed box border is a single component as tall as it is wide, so
        /// the elongation test above never sees it. It is instead recognised by
        /// reaching this far across the cell in BOTH directions…
        static let frameSpan = 0.7
        /// …touching at least this many of the four edge bands (a rectangle
        /// touches all four; a digit rarely more than two)…
        static let frameEdgesTouched = 3
        /// …and being hollow. Without this a filled bubble — which also spans
        /// the cell and touches every edge — would be erased, and a filled
        /// bubble is an answer.
        static let frameMaxFill = 0.5
    }

    /// Sample `quad` (pixel coordinates in `bitmap`, corners tl→tr→br→bl) into
    /// an upright patch.
    ///
    /// `aspect` is the cell's true width/height on the master sheet. It has to
    /// be passed in rather than derived from `quad`, because the quad is
    /// foreshortened by the camera angle — and squashing a cell into a square
    /// would stretch the digit inside it, which is exactly what MNIST's
    /// aspect-preserving normalisation is trying to avoid.
    init?(bitmap: GrayBitmap, quad: [CGPoint], aspect: CGFloat,
          printedBounds: CGRect = CellPatch.wholePatch,
          maxSide: Int = CellPatch.defaultMaxSide) {
        guard quad.count == 4, aspect.isFinite, aspect > 0,
              let map = UnitQuad(quad: quad) else { return nil }

        let side = CGFloat(maxSide)
        let w = aspect >= 1 ? maxSide : max(8, Int((side * aspect).rounded()))
        let h = aspect >= 1 ? max(8, Int((side / aspect).rounded())) : maxSide

        var values = [Double](repeating: 0, count: w * h)
        for j in 0..<h {
            let v = (CGFloat(j) + 0.5) / CGFloat(h)
            for i in 0..<w {
                let u = (CGFloat(i) + 0.5) / CGFloat(w)
                let p = map.point(u, v)
                values[j * w + i] = 1 - bitmap.sample(p.x, p.y)
            }
        }

        self.init(width: w, height: h, intensity: values, printedBounds: printedBounds)
    }

    /// Direct construction, for tests and for callers that already hold a patch.
    init(width: Int, height: Int, intensity: [Double],
         printedBounds: CGRect = CellPatch.wholePatch) {
        let otsu = CellPatch.otsu(intensity)
        self.init(width: width, height: height, intensity: intensity,
                  threshold: otsu.threshold, separation: otsu.separation,
                  printedBounds: printedBounds)
    }

    /// Rebuilds with a threshold decided elsewhere. `withoutPrintedMarks` needs
    /// this: once the rules are blanked the histogram is mostly paper, and a
    /// fresh Otsu would move the ink/paper split even though nothing about the
    /// handwriting changed.
    private init(width: Int, height: Int, intensity: [Double],
                 threshold: Double, separation: Double,
                 printedBounds: CGRect = CellPatch.wholePatch) {
        precondition(intensity.count == width * height, "intensity must be width * height")
        self.width = width
        self.height = height
        self.intensity = intensity
        self.threshold = threshold
        self.separation = separation
        let clamped = printedBounds.intersection(CellPatch.wholePatch)
        self.printedBounds = (clamped.isNull || clamped.isEmpty)
            ? CellPatch.wholePatch : clamped

        let flags = intensity.map { $0 > threshold }
        mask = flags
        coverage = intensity.isEmpty ? 0
            : Double(flags.lazy.filter { $0 }.count) / Double(intensity.count)
    }

    /// A copy with the cell's printed furniture erased — the answer box's own
    /// border, the ruled line under a blank, the parentheses around a
    /// multiple-choice code.
    ///
    /// This matters more than any other single step. Measured on the six real
    /// handwritten answers in `TestFixtures/real_cells.json`, feeding the raw
    /// cell to the digit model scores 1/6; erasing the printed marks first
    /// scores 6/6. The model was never the problem — the printed strokes were
    /// being read as part of the digit.
    ///
    /// Note this deliberately does NOT need a master sheet or a pixel-accurate
    /// homography: it is decided from the cell's own geometry, so it costs
    /// nothing at scan time and cannot be broken by alignment drift.
    func withoutPrintedMarks() -> CellPatch {
        let (labels, count) = ConnectedComponents.label(mask, width: width, height: height,
                                                        connectivity: .eight)
        guard count > 0 else { return self }

        var area = [Int](repeating: 0, count: count + 1)
        var minX = [Int](repeating: width, count: count + 1)
        var maxX = [Int](repeating: -1, count: count + 1)
        var minY = [Int](repeating: height, count: count + 1)
        var maxY = [Int](repeating: -1, count: count + 1)
        for y in 0..<height {
            for x in 0..<width {
                let label = labels[y * width + x]
                guard label > 0 else { continue }
                area[label] += 1
                if x < minX[label] { minX[label] = x }
                if x > maxX[label] { maxX[label] = x }
                if y < minY[label] { minY[label] = y }
                if y > maxY[label] { maxY[label] = y }
            }
        }

        // Everything below is measured against the PRINTED cell, not the patch.
        // The furniture this removes — the box border, the ruled line, the
        // parentheses — sits on the printed cell's own edges, so when the
        // sampler reads wider than the cell those edges are no longer the
        // patch's edges. Looking for them at the patch border finds nothing and
        // hands the recogniser the box outline as part of the answer, which is
        // the single largest error source this function exists to remove.
        let cellW = Double(width) * printedBounds.width
        let cellH = Double(height) * printedBounds.height
        let cellArea = cellW * cellH
        let leftEdge = Double(width) * printedBounds.minX
        let rightEdge = Double(width) * printedBounds.maxX
        let topEdge = Double(height) * printedBounds.minY
        let bottomEdge = Double(height) * printedBounds.maxY
        let bandX = Tuning.printedEdgeBand * cellW
        let bandY = Tuning.printedEdgeBand * cellH
        var drop = [Bool](repeating: false, count: count + 1)
        for label in 1...count {
            if Double(area[label]) / cellArea < Tuning.minSpeckArea { drop[label] = true; continue }

            let w = maxX[label] - minX[label] + 1
            let h = maxY[label] - minY[label] + 1

            let horizontal = Double(w) > Tuning.printedElongation * Double(h)
                && (Double(minY[label]) < topEdge + bandY
                    || Double(maxY[label]) > bottomEdge - bandY)

            let vertical = Double(h) > Tuning.printedElongation * Double(w)
                && Double(h) >= Tuning.printedVerticalSpan * cellH
                && (Double(minX[label]) < leftEdge + bandX
                    || Double(maxX[label]) > rightEdge - bandX)

            // A closed rectangle around the answer is one component roughly as
            // wide as it is tall, so neither elongation test fires on it — and
            // it is the commonest way an answer box is printed.
            var edges = 0
            if Double(minY[label]) < topEdge + bandY { edges += 1 }
            if Double(maxY[label]) > bottomEdge - bandY { edges += 1 }
            if Double(minX[label]) < leftEdge + bandX { edges += 1 }
            if Double(maxX[label]) > rightEdge - bandX { edges += 1 }
            let fill = Double(area[label]) / Double(max(1, w * h))
            let frame = Double(w) >= Tuning.frameSpan * cellW
                && Double(h) >= Tuning.frameSpan * cellH
                && edges >= Tuning.frameEdgesTouched
                && fill < Tuning.frameMaxFill

            drop[label] = horizontal || vertical || frame
        }

        guard drop.dropFirst().contains(true) else { return self }

        var cleaned = intensity
        for i in 0..<cleaned.count where drop[labels[i]] { cleaned[i] = 0 }
        return CellPatch(width: width, height: height, intensity: cleaned,
                         threshold: threshold, separation: separation,
                         printedBounds: printedBounds)
    }

    /// Otsu's method over a 256-bin histogram: pick the split that maximises
    /// between-class variance. Parameter-free, so it rides out the lighting
    /// changes that a fixed threshold cannot.
    private static func otsu(_ values: [Double]) -> (threshold: Double, separation: Double) {
        guard !values.isEmpty else { return (0.5, 0) }
        let bins = 256
        var histogram = [Double](repeating: 0, count: bins)
        for v in values {
            let bin = min(bins - 1, max(0, Int(v * Double(bins - 1))))
            histogram[bin] += 1
        }
        let total = Double(values.count)
        var sumAll = 0.0
        for b in 0..<bins { sumAll += Double(b) * histogram[b] }

        var bestVariance = -1.0, bestBin = 0
        var weightLow = 0.0, sumLow = 0.0
        var bestMeanLow = 0.0, bestMeanHigh = 0.0
        for b in 0..<bins {
            weightLow += histogram[b]
            if weightLow == 0 { continue }
            let weightHigh = total - weightLow
            if weightHigh == 0 { break }
            sumLow += Double(b) * histogram[b]
            let meanLow = sumLow / weightLow
            let meanHigh = (sumAll - sumLow) / weightHigh
            let variance = weightLow * weightHigh * (meanLow - meanHigh) * (meanLow - meanHigh)
            if variance > bestVariance {
                bestVariance = variance
                bestBin = b
                bestMeanLow = meanLow
                bestMeanHigh = meanHigh
            }
        }
        // Upper edge of the winning bin, not its lower edge. A value lands in
        // bin b when floor(v * 255) == b, so every value in the low class is
        // strictly below (b+1)/255 — using b/255 would put the whole bin above
        // the threshold and mark an entire blank cell as ink.
        let scale = Double(bins - 1)
        return (Double(bestBin + 1) / scale, (bestMeanHigh - bestMeanLow) / scale)
    }

    /// Bounding box of `mask` in patch pixels, or nil when nothing is set.
    func inkBounds(of subset: [Bool]? = nil) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let flags = subset ?? mask
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where flags[y * width + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }
}

// MARK: - Connected components

/// Iterative (never recursive — a patch can be one long snake of ink) labelling
/// of a boolean mask.
enum ConnectedComponents {
    enum Connectivity {
        case four, eight

        var offsets: [(Int, Int)] {
            switch self {
            case .four:  return [(1, 0), (-1, 0), (0, 1), (0, -1)]
            case .eight: return [(1, 0), (-1, 0), (0, 1), (0, -1),
                                 (1, 1), (1, -1), (-1, 1), (-1, -1)]
            }
        }
    }

    /// `labels[i]` is 0 where `mask` is false, else 1...count.
    ///
    /// Foreground and background must not use the same connectivity or the
    /// classic paradox bites: a diagonal chain of ink would both enclose a
    /// region and let the background leak out through the same diagonal. Ink is
    /// labelled 8-connected, background 4-connected.
    static func label(_ mask: [Bool], width: Int, height: Int,
                      connectivity: Connectivity) -> (labels: [Int], count: Int) {
        var labels = [Int](repeating: 0, count: mask.count)
        var count = 0
        let offsets = connectivity.offsets
        var stack: [Int] = []

        for start in 0..<mask.count where mask[start] && labels[start] == 0 {
            count += 1
            labels[start] = count
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                for (dx, dy) in offsets {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbour = ny * width + nx
                    if mask[neighbour] && labels[neighbour] == 0 {
                        labels[neighbour] = count
                        stack.append(neighbour)
                    }
                }
            }
        }
        return (labels, count)
    }
}
