import UIKit

// Putting each cell back where it is printed, before reading it.
//
// XFeat aligns the whole page with one homography, and a homography fitted to
// keypoints in one part of the sheet is only an estimate everywhere else. On
// sixteen real scans of one 自然 paper the crops it produced sat a third to
// half a cell off the answer, sometimes a whole row: the student's 3 cut in
// half, the left parenthesis taken for a ○, the heading 選擇題 read as digits.
// No amount of holding the phone still fixes that — the error is in the fit,
// not the frame.
//
// The fix is local. Around every cell the master sheet has print the
// student's copy also has — the parentheses, the question number, the first
// characters of the question — so each cell is looked for, on its own, by
// sliding that print over the frame within a cell of where the homography
// put it. The offset that lines it up is the homography's error at that
// cell, and it is corrected before anything is read. Where the print cannot
// be found the frame is not read at all: a crop that cannot be shown to be on
// the cell is the crop that produced the 111s.
//
// Knowing exactly where the print is buys a second thing: it can be erased
// pixel for pixel instead of guessed at from shape. A child's 2 that runs
// through the right parenthesis keeps its stroke; the parenthesis goes.
//
// Every number here was calibrated in the Python mirror (~/recog-replica,
// `swiftreg2.py`, `e2e3.py`) against the student's own copy of that paper,
// misaligned on purpose by up to a cell, blurred and rotated: within ±0.9 of
// a cell 90% of frames lock on and none lock wrong; past the search range 94%
// are refused rather than snapped somewhere plausible.

/// The master sheet's printed ink — dark and unsaturated, the black print a
/// student's copy shares — as opposed to a coloured answer key or a teacher's
/// pink notes, which only the master has and which would otherwise be looked
/// for on every child's paper and not found.
final class MasterInk {
    let width: Int
    let height: Int
    private let ink: [Float]

    /// Long side the master is analysed at. Masters arrive at up to 2400px.
    static let maxSide = 2400
    /// Darker than this grey (0–255)…
    static let maxGray = 150
    /// …and less saturated than this (HSV, 0–255) is print. Pink answer text
    /// is dark enough to pass the first test and fails this one.
    static let maxSaturation = 70

    init?(_ image: UIImage) {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let scale = min(1, Double(Self.maxSide) / Double(max(cg.width, cg.height)))
        let w = max(1, Int((Double(cg.width) * scale).rounded()))
        let h = max(1, Int((Double(cg.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // A transparent master reads as paper, not as black.
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var ink = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(rgba[4 * i]), g = Int(rgba[4 * i + 1]), b = Int(rgba[4 * i + 2])
            let gray = (299 * r + 587 * g + 114 * b) / 1000
            let high = max(r, g, b), low = min(r, g, b)
            let saturation = high > 0 ? (high - low) * 255 / high : 0
            if gray < Self.maxGray && saturation < Self.maxSaturation { ink[i] = 1 }
        }
        width = w
        height = h
        self.ink = ink
    }

    /// Ink at a point in normalized page coordinates, bilinear, 0…1.
    func coverage(x: Double, y: Double) -> Float {
        let fx = min(max(x * Double(width) - 0.5, 0), Double(width - 1))
        let fy = min(max(y * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let top = ink[y0 * width + x0] + (ink[y0 * width + x1] - ink[y0 * width + x0]) * tx
        let bottom = ink[y1 * width + x0] + (ink[y1 * width + x1] - ink[y1 * width + x0]) * tx
        return top + (bottom - top) * ty
    }

    /// Printed ink over `rect` (normalized page coordinates), sampled on a
    /// `width`×`height` grid of pixel centres.
    func mask(of rect: CGRect, width: Int, height: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for j in 0..<height {
            let y = Double(rect.minY) + (Double(j) + 0.5) / Double(height) * Double(rect.height)
            for i in 0..<width {
                let x = Double(rect.minX) + (Double(i) + 0.5) / Double(width) * Double(rect.width)
                out[j * width + i] = coverage(x: x, y: y) > 0.5
            }
        }
        return out
    }
}

/// One cell's printed surroundings, ready to be searched for in a frame.
///
/// Everything is held at a canonical scale — the printed box 85px wide, pixels
/// square on the page — so the same template serves every frame however near
/// or far the camera is, and the numbers below mean the same thing on every
/// paper.
struct CellTemplate {

    enum Tuning {
        /// The printed box's width at the canonical scale.
        static let cellWidth = 85.0
        /// The template reaches this many cells past the box on every side:
        /// far enough to take in the question number and the start of the
        /// question, which is what makes one row's template different from
        /// the next. Parentheses alone repeat every row, and with only them
        /// to go on a cell a row out lines up perfectly with the wrong one.
        static let context = 1.0
        /// How far, in cell widths, the search looks either way.
        static let searchMargin = 1.0
        /// Inside the box (plus this sliver) nothing counts: the master has
        /// its answer key there and the student has their answer.
        static let coreBand = 0.03
        /// Within this many cells of the box, printed ink still counts as
        /// evidence but stray ink does not count against — children write
        /// over the lines and the parentheses.
        static let nearBand = 0.5
        /// Further out, ink where the master has paper counts against a
        /// placement at this weight. This, more than anything, is what tells
        /// the right row from its neighbour: shift the template by a row and
        /// the question text lands on paper.
        static let paperPenalty = 0.5
        /// Fewer printed pixels than this around the box and there is nothing
        /// reliable to register against — a cell on a blank margin.
        static let minInk = 40
        /// Accept a placement only if the coarse search's best is at least
        /// this, beats everything outside its own neighbourhood by this much,
        /// and the fine search confirms it at this.
        static let minCoarseScore = 0.2
        static let minCoarseLead = 0.1
        static let minFineScore = 0.3
        /// The fine search refines the coarse winner by this many pixels.
        static let fineRadius = 5
        /// Coarse grid: 4×4 canonical pixels per cell of the grid.
        static let coarse = 4
    }

    /// Canonical pixels per normalized page unit, per axis.
    let scaleX: Double
    let scaleY: Double
    /// The template's own rect (normalized page coordinates) and the larger
    /// one searched in the frame.
    let templateRect: CGRect
    let searchRect: CGRect
    /// Template and search field sizes in canonical pixels.
    let width: Int
    let height: Int
    let margin: Int
    var fieldWidth: Int { width + 2 * margin }
    var fieldHeight: Int { height + 2 * margin }
    /// The printed box at the canonical scale.
    let cellPixels: CGSize

    // Full resolution: pixels rewarded for landing on ink, and pixels exempt
    // from the paper penalty (print and its immediate surroundings outside
    // the near band).
    fileprivate let rewardX: [Int32], rewardY: [Int32]
    fileprivate let exemptX: [Int32], exemptY: [Int32]
    fileprivate let near: (x0: Double, y0: Double, x1: Double, y1: Double)

    // The same at the coarse grid, as weights (the share of each 4×4 block).
    fileprivate let coarseWidth: Int, coarseHeight: Int
    fileprivate let coarseRewardX: [Int32], coarseRewardY: [Int32], coarseRewardW: [Float]
    fileprivate let coarseExemptX: [Int32], coarseExemptY: [Int32], coarseExemptW: [Float]
    fileprivate let coarseNear: (x0: Double, y0: Double, x1: Double, y1: Double)

    var isUsable: Bool { rewardX.count >= Tuning.minInk }

    /// `box` in normalized page coordinates; `pageSize` the master's size in
    /// pixels, which is what makes the canonical pixels square.
    init(box: CGRect, ink: MasterInk, pageSize: CGSize) {
        let ctx = Tuning.context
        let sx = Tuning.cellWidth / Double(box.width)
        let sy = sx * Double(pageSize.height) / Double(max(pageSize.width, 1))
        let cellW = Double(box.width) * sx, cellH = Double(box.height) * sy
        let rect = CGRect(x: Double(box.minX) - ctx * Double(box.width),
                          y: Double(box.minY) - ctx * Double(box.height),
                          width: (1 + 2 * ctx) * Double(box.width),
                          height: (1 + 2 * ctx) * Double(box.height))
        let w = max(1, Int(((1 + 2 * ctx) * cellW).rounded()))
        let h = max(1, Int(((1 + 2 * ctx) * cellH).rounded()))
        let m = max(1, Int((Tuning.searchMargin * cellW).rounded()))

        let printed = ink.mask(of: rect, width: w, height: h)
        let ring = Self.dilated(printed, width: w, height: h, radius: 2)

        func band(_ pad: Double) -> (Int, Int, Int, Int) {
            (max(0, Int(((ctx - pad) * cellW).rounded())),
             max(0, Int(((ctx - pad) * cellH).rounded())),
             min(w, Int(((ctx + 1 + pad) * cellW).rounded())),
             min(h, Int(((ctx + 1 + pad) * cellH).rounded())))
        }
        let core = band(Tuning.coreBand), nearRect = band(Tuning.nearBand)

        var reward = [Bool](repeating: false, count: w * h)
        var exempt = [Bool](repeating: false, count: w * h)
        var rx: [Int32] = [], ry: [Int32] = [], ex: [Int32] = [], ey: [Int32] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let inCore = x >= core.0 && x < core.2 && y >= core.1 && y < core.3
                let inNear = x >= nearRect.0 && x < nearRect.2 && y >= nearRect.1 && y < nearRect.3
                if printed[i] && !inCore {
                    reward[i] = true
                    rx.append(Int32(x)); ry.append(Int32(y))
                }
                if ring[i] && !inNear {
                    exempt[i] = true
                    ex.append(Int32(x)); ey.append(Int32(y))
                }
            }
        }

        let k = Tuning.coarse
        let cw = (w + k - 1) / k, ch = (h + k - 1) / k
        func pooled(_ mask: [Bool]) -> (xs: [Int32], ys: [Int32], ws: [Float]) {
            var counts = [Int](repeating: 0, count: cw * ch)
            for y in 0..<h {
                for x in 0..<w where mask[y * w + x] { counts[(y / k) * cw + x / k] += 1 }
            }
            var xs: [Int32] = [], ys: [Int32] = [], ws: [Float] = []
            for j in 0..<ch {
                for i in 0..<cw where counts[j * cw + i] > 0 {
                    xs.append(Int32(i)); ys.append(Int32(j))
                    ws.append(Float(counts[j * cw + i]) / Float(k * k))
                }
            }
            return (xs, ys, ws)
        }
        let coarseReward = pooled(reward), coarseExempt = pooled(exempt)
        let nearPx = (x0: Double(nearRect.0), y0: Double(nearRect.1),
                      x1: Double(nearRect.2), y1: Double(nearRect.3))

        scaleX = sx
        scaleY = sy
        cellPixels = CGSize(width: cellW, height: cellH)
        templateRect = rect
        searchRect = rect.insetBy(dx: -Double(m) / sx, dy: -Double(m) / sy)
        width = w
        height = h
        margin = m
        rewardX = rx; rewardY = ry; exemptX = ex; exemptY = ey
        near = nearPx
        coarseWidth = cw
        coarseHeight = ch
        coarseRewardX = coarseReward.xs; coarseRewardY = coarseReward.ys; coarseRewardW = coarseReward.ws
        coarseExemptX = coarseExempt.xs; coarseExemptY = coarseExempt.ys; coarseExemptW = coarseExempt.ws
        coarseNear = (nearPx.x0 / Double(k), nearPx.y0 / Double(k), nearPx.x1 / Double(k), nearPx.y1 / Double(k))
    }

    /// `mask` grown by `radius` pixels in every direction (a square).
    static func dilated(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        var rows = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for xx in max(0, x - radius)...min(width - 1, x + radius) { rows[y * width + xx] = true }
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width where rows[y * width + x] {
                for yy in max(0, y - radius)...min(height - 1, y + radius) { out[yy * width + x] = true }
            }
        }
        return out
    }
}

enum CellRegistration {

    /// Where the template was found: how far its print sits from where the
    /// homography put it, in canonical pixels. Positive is right/down.
    struct Placement {
        let dx: Int
        let dy: Int
        let score: Double
    }

    /// Looks for `template` in `field`, a patch of the frame sampled over
    /// `template.searchRect` at the canonical scale (`fieldWidth`×`fieldHeight`).
    /// nil when the print is not there to be found — or not unambiguously.
    static func locate(_ template: CellTemplate, in field: CellPatch) -> Placement? {
        guard template.isUsable,
              field.width == template.fieldWidth, field.height == template.fieldHeight else { return nil }
        let fw = field.width, fh = field.height
        // A pixel of print counts as found when frame ink is within one pixel.
        let grown = CellTemplate.dilated(field.mask, width: fw, height: fh, radius: 1)
        let full = grown.map { $0 ? Float(1) : 0 }
        let fullSums = integral(full, width: fw, height: fh)

        let k = CellTemplate.Tuning.coarse
        let cw = (fw + k - 1) / k, ch = (fh + k - 1) / k
        var coarse = [Float](repeating: 0, count: cw * ch)
        for y in 0..<fh {
            for x in 0..<fw where grown[y * fw + x] { coarse[(y / k) * cw + x / k] += 1 }
        }
        for i in 0..<coarse.count { coarse[i] /= Float(k * k) }
        let coarseSums = integral(coarse, width: cw, height: ch)

        // Coarse: every placement within the margin.
        let m4 = template.margin / k
        let side = 2 * m4 + 1
        let coarseNorm = Double(template.coarseRewardW.reduce(0, +))
        guard coarseNorm > 0 else { return nil }
        var scores = [Double](repeating: -.infinity, count: side * side)
        for j in 0..<side {
            for i in 0..<side {
                guard j + template.coarseHeight <= ch, i + template.coarseWidth <= cw else { continue }
                scores[j * side + i] = score(
                    field: coarse, fieldWidth: cw, sums: coarseSums,
                    rewardX: template.coarseRewardX, rewardY: template.coarseRewardY,
                    rewardW: template.coarseRewardW,
                    exemptX: template.coarseExemptX, exemptY: template.coarseExemptY,
                    exemptW: template.coarseExemptW, norm: coarseNorm,
                    width: template.coarseWidth, height: template.coarseHeight,
                    near: template.coarseNear, ox: i, oy: j)
            }
        }
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let best = scores[bestIndex]
        let bj = bestIndex / side, bi = bestIndex % side
        // On the edge of the search: the real optimum may lie beyond it.
        guard best.isFinite, bi > 0, bj > 0, bi < side - 1, bj < side - 1,
              best >= CellTemplate.Tuning.minCoarseScore else { return nil }
        // Unambiguous: clearly ahead of anything outside its own neighbourhood.
        let r = max(1, m4 / 5)
        var second = -Double.infinity
        for j in 0..<side {
            for i in 0..<side where abs(j - bj) > r || abs(i - bi) > r {
                second = max(second, scores[j * side + i])
            }
        }
        guard best - second >= CellTemplate.Tuning.minCoarseLead else { return nil }

        // Fine: full resolution around the coarse winner.
        let cx = k * (bi - m4), cy = k * (bj - m4)
        let norm = Double(template.rewardX.count)
        var candidates: [(score: Double, dx: Int, dy: Int)] = []
        let radius = CellTemplate.Tuning.fineRadius
        for dy in (cy - radius)...(cy + radius) {
            for dx in (cx - radius)...(cx + radius) {
                let ox = template.margin + dx, oy = template.margin + dy
                guard ox >= 0, oy >= 0, ox + template.width <= fw, oy + template.height <= fh else { continue }
                let s = score(field: full, fieldWidth: fw, sums: fullSums,
                              rewardX: template.rewardX, rewardY: template.rewardY, rewardW: nil,
                              exemptX: template.exemptX, exemptY: template.exemptY, exemptW: nil,
                              exemptStride: 2,
                              norm: norm, width: template.width, height: template.height,
                              near: template.near, ox: ox, oy: oy)
                candidates.append((s, dx, dy))
            }
        }
        guard let fineBest = candidates.map(\.score).max(),
              fineBest >= CellTemplate.Tuning.minFineScore else { return nil }
        // Ties go to the smaller correction: a direction the print cannot pin
        // down (a lone ruled line says nothing about x) is left where the
        // homography put it.
        let chosen = candidates
            .filter { $0.score >= fineBest - 0.02 }
            .min { ($0.dx * $0.dx + $0.dy * $0.dy) < ($1.dx * $1.dx + $1.dy * $1.dy) }!
        return Placement(dx: chosen.dx, dy: chosen.dy, score: chosen.score)
    }

    /// Re-finds a template near where it was a frame ago — the cheap path.
    ///
    /// `field` covers the template's rect moved by the previous placement and
    /// grown by `radius` pixels each way, sampled at the canonical scale. Only
    /// the fine search runs, over ±`radius`; the result is the change since
    /// the previous placement. A best placement on the edge of that range, or
    /// one below the fine threshold, means the cell has moved more than
    /// tracking can follow, and the caller searches properly instead.
    ///
    /// Measured in the mirror: with the prediction within 0.08 of a cell, 197
    /// of 216 frames track and none track wrong; with it 0.1–0.3 off, nearly
    /// all hand back to the full search, and still none are wrong.
    static func track(_ template: CellTemplate, in field: CellPatch, radius: Int) -> Placement? {
        guard template.isUsable, radius > 0,
              field.width == template.width + 2 * radius,
              field.height == template.height + 2 * radius else { return nil }
        let fw = field.width, fh = field.height
        let grown = CellTemplate.dilated(field.mask, width: fw, height: fh, radius: 1)
        let full = grown.map { $0 ? Float(1) : 0 }
        let sums = integral(full, width: fw, height: fh)
        let norm = Double(template.rewardX.count)
        var scored: [Int: (score: Double, dx: Int, dy: Int)] = [:]
        func evaluate(_ dx: Int, _ dy: Int) {
            guard abs(dx) <= radius, abs(dy) <= radius else { return }
            let key = (dy + radius) * (2 * radius + 1) + dx + radius
            guard scored[key] == nil else { return }
            let s = score(field: full, fieldWidth: fw, sums: sums,
                          rewardX: template.rewardX, rewardY: template.rewardY, rewardW: nil,
                          exemptX: template.exemptX, exemptY: template.exemptY, exemptW: nil,
                          exemptStride: 2,
                          norm: norm, width: template.width, height: template.height,
                          near: template.near, ox: radius + dx, oy: radius + dy)
            scored[key] = (s, dx, dy)
        }
        // Every other placement first — a found print scores high over a
        // plateau three pixels wide, because frame ink is grown by one pixel,
        // so a two-pixel grid cannot step over it — then the neighbours of
        // the best.
        for dy in stride(from: -radius, through: radius, by: 2) {
            for dx in stride(from: -radius, through: radius, by: 2) { evaluate(dx, dy) }
        }
        guard let coarseBest = scored.values.max(by: { $0.score < $1.score }) else { return nil }
        for ddy in -1...1 {
            for ddx in -1...1 { evaluate(coarseBest.dx + ddx, coarseBest.dy + ddy) }
        }
        let candidates = Array(scored.values)
        // The edge test is on the true best, before any tie-breaking: a best
        // on the edge says the optimum may lie beyond it.
        guard let top = candidates.max(by: { $0.score < $1.score }),
              top.score >= CellTemplate.Tuning.minFineScore,
              abs(top.dx) < radius, abs(top.dy) < radius else { return nil }
        let chosen = candidates
            .filter { $0.score >= top.score - 0.02 }
            .min { ($0.dx * $0.dx + $0.dy * $0.dy) < ($1.dx * $1.dx + $1.dy * $1.dy) }!
        return Placement(dx: chosen.dx, dy: chosen.dy, score: chosen.score)
    }

    /// Reward for print found, less a penalty for ink where the master has
    /// paper, per printed pixel — evaluated with the template's origin at
    /// (ox, oy) in the field.
    ///
    /// The hot loop of registration, run a few hundred times per cell per
    /// frame, so written for speed: no closures, no bounds checks. The exempt
    /// sum (print and its surroundings outside the near band, a few thousand
    /// pixels) only refines an area penalty taken from integral images, so
    /// at full resolution it is sampled every `exemptStride`th pixel and
    /// scaled up; the reward, which is what locates the print, is exact.
    private static func score(field: [Float], fieldWidth fw: Int, sums: [Double],
                              rewardX: [Int32], rewardY: [Int32], rewardW: [Float]?,
                              exemptX: [Int32], exemptY: [Int32], exemptW: [Float]?,
                              exemptStride: Int = 1,
                              norm: Double, width: Int, height: Int,
                              near: (x0: Double, y0: Double, x1: Double, y1: Double),
                              ox: Int, oy: Int) -> Double {
        let shift = oy * fw + ox
        var reward: Float = 0
        var exempt: Float = 0
        field.withUnsafeBufferPointer { f in
            rewardX.withUnsafeBufferPointer { rx in
                rewardY.withUnsafeBufferPointer { ry in
                    if let rewardW {
                        rewardW.withUnsafeBufferPointer { rw in
                            for k in 0..<rx.count {
                                reward += f[Int(ry[k]) * fw + Int(rx[k]) + shift] * rw[k]
                            }
                        }
                    } else {
                        for k in 0..<rx.count { reward += f[Int(ry[k]) * fw + Int(rx[k]) + shift] }
                    }
                }
            }
            exemptX.withUnsafeBufferPointer { ex in
                exemptY.withUnsafeBufferPointer { ey in
                    if let exemptW {
                        exemptW.withUnsafeBufferPointer { ew in
                            for k in stride(from: 0, to: ex.count, by: exemptStride) {
                                exempt += f[Int(ey[k]) * fw + Int(ex[k]) + shift] * ew[k]
                            }
                        }
                    } else {
                        for k in stride(from: 0, to: ex.count, by: exemptStride) {
                            exempt += f[Int(ey[k]) * fw + Int(ex[k]) + shift]
                        }
                    }
                }
            }
        }
        let whole = rectSum(sums, width: fw, x0: ox, y0: oy, x1: ox + width, y1: oy + height)
        let nearSum = rectSum(sums, width: fw,
                              x0: ox + Int(near.x0.rounded()), y0: oy + Int(near.y0.rounded()),
                              x1: ox + Int(near.x1.rounded()), y1: oy + Int(near.y1.rounded()))
        let paper = whole - nearSum - Double(exempt) * Double(exemptStride)
        return (Double(reward) - CellTemplate.Tuning.paperPenalty * paper) / norm
    }

    private static func integral(_ values: [Float], width: Int, height: Int) -> [Double] {
        var sums = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                sums[(y + 1) * (width + 1) + x + 1] = sums[y * (width + 1) + x + 1] + row
            }
        }
        return sums
    }

    private static func rectSum(_ sums: [Double], width: Int,
                                x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        let stride = width + 1
        let height = sums.count / stride - 1
        let ax = min(max(x0, 0), width), bx = min(max(x1, 0), width)
        let ay = min(max(y0, 0), height), by = min(max(y1, 0), height)
        guard bx > ax, by > ay else { return 0 }
        return sums[by * stride + bx] - sums[ay * stride + bx] - sums[by * stride + ax] + sums[ay * stride + ax]
    }
}

/// The window a registered cell is read through, and the master's print to
/// erase from it — both fixed per cell, so built once.
struct ReadWindow {

    enum Tuning {
        /// How far past the box the student's strokes are followed, in cells.
        /// Taller than wide because children's digits overflow upwards and
        /// downwards far more than sideways: on the 自然 paper a 2 rose a
        /// full cell above its box, and a window that cut it off read 4.
        static let padX = 0.6
        static let padY = 1.0
        /// What recognition is shown: strokes are FOLLOWED to padY, so a 2
        /// that leaves the box stays one stroke, but the digit is CLASSIFIED
        /// within this much of the box. A 3 written two cells tall, whole,
        /// is too narrow for the model and read as 1; cut at 0.6 it is a 3.
        static let classifyPadY = 0.6
        /// A master component whose centre falls this far inside the box is
        /// the answer key, not furniture — never erased.
        static let answerInset = 0.2
        /// Print is erased with this much margin, for the alignment that is
        /// left after registration.
        static let eraseRadius = 2
        /// A stroke belongs to the answer when it reaches into the box inset
        /// by this share.
        static let touchInset = 0.05
    }

    /// Pads around the box, normalized page units, already capped so the
    /// window never reaches into a neighbouring cell.
    let left: Double, right: Double, top: Double, bottom: Double
    let width: Int
    let height: Int
    /// The printed box inside the window, as fractions of it.
    let printedBounds: CGRect
    /// Master print to erase, at the window's resolution.
    let furniture: [Bool]
    /// Rows classified: [cropTop, cropBottom).
    let cropTop: Int
    let cropBottom: Int

    init(box: CGRect, pads: (left: Double, right: Double, top: Double, bottom: Double),
         template: CellTemplate, ink: MasterInk) {
        let (l, r, t, b) = (pads.left, pads.right, pads.top, pads.bottom)
        let sx = template.scaleX, sy = template.scaleY
        let totalW = Double(box.width) + l + r, totalH = Double(box.height) + t + b
        let w = max(1, Int((totalW * sx).rounded()))
        let h = max(1, Int((totalH * sy).rounded()))
        let bounds = CGRect(x: l / totalW, y: t / totalH,
                            width: Double(box.width) / totalW, height: Double(box.height) / totalH)

        let rect = ReadWindow.rect(around: box, left: l, right: r, top: t, bottom: b)
        let printed = ink.mask(of: rect, width: w, height: h)
        // Everything printed except what sits in the middle of the box.
        let (labels, count) = ConnectedComponents.label(printed, width: w, height: h, connectivity: .eight)
        var sumX = [Double](repeating: 0, count: count + 1)
        var sumY = [Double](repeating: 0, count: count + 1)
        var area = [Int](repeating: 0, count: count + 1)
        for y in 0..<h {
            for x in 0..<w {
                let label = labels[y * w + x]
                guard label > 0 else { continue }
                sumX[label] += Double(x); sumY[label] += Double(y); area[label] += 1
            }
        }
        let bx0 = Double(bounds.minX) * Double(w), bx1 = Double(bounds.maxX) * Double(w)
        let by0 = Double(bounds.minY) * Double(h), by1 = Double(bounds.maxY) * Double(h)
        let inset = Tuning.answerInset
        var furnitureLabel = [Bool](repeating: false, count: count + 1)
        if count > 0 {
            for label in 1...count where area[label] > 0 {
                let cx = sumX[label] / Double(area[label]), cy = sumY[label] / Double(area[label])
                let isAnswer = cx > bx0 + inset * (bx1 - bx0) && cx < bx1 - inset * (bx1 - bx0)
                    && cy > by0 + inset * (by1 - by0) && cy < by1 - inset * (by1 - by0)
                furnitureLabel[label] = !isAnswer
            }
        }

        let trimTop = max(0, Int(((t - Tuning.classifyPadY * Double(box.height)) * sy).rounded()))
        let trimBottom = max(0, Int(((b - Tuning.classifyPadY * Double(box.height)) * sy).rounded()))

        left = l; right = r; top = t; bottom = b
        width = w
        height = h
        printedBounds = bounds
        furniture = CellTemplate.dilated(labels.map { furnitureLabel[$0] }, width: w, height: h,
                                         radius: Tuning.eraseRadius)
        cropTop = min(trimTop, h)
        cropBottom = max(min(trimTop, h), h - trimBottom)
    }

    static func rect(around box: CGRect, left: Double, right: Double,
                     top: Double, bottom: Double) -> CGRect {
        CGRect(x: Double(box.minX) - left, y: Double(box.minY) - top,
               width: Double(box.width) + left + right, height: Double(box.height) + top + bottom)
    }

    func rect(around box: CGRect) -> CGRect {
        Self.rect(around: box, left: left, right: right, top: top, bottom: bottom)
    }

    /// The frame's view of the cell with the print erased and only the strokes
    /// that reach into the box kept, cropped to the classification rows — and,
    /// for the teacher, the same rows as photographed.
    func cleaned(_ patch: CellPatch) -> (patch: CellPatch, evidence: GrayBitmap)? {
        guard patch.width == width, patch.height == height else { return nil }
        let (labels, _) = ConnectedComponents.label(patch.mask, width: width, height: height,
                                                    connectivity: .eight)
        let x0 = Int((Double(printedBounds.minX) + Tuning.touchInset * Double(printedBounds.width)) * Double(width))
        let x1 = Int((Double(printedBounds.minX) + (1 - Tuning.touchInset) * Double(printedBounds.width)) * Double(width))
        let y0 = Int((Double(printedBounds.minY) + Tuning.touchInset * Double(printedBounds.height)) * Double(height))
        let y1 = Int((Double(printedBounds.minY) + (1 - Tuning.touchInset) * Double(printedBounds.height)) * Double(height))
        guard cropBottom > cropTop else { return nil }
        let rows = max(0, y0)..<max(max(0, y0), min(height, y1))
        let columns = max(0, x0)..<max(max(0, x0), min(width, x1))
        var touching = Set<Int>()
        for y in rows {
            for x in columns {
                let label = labels[y * width + x]
                if label > 0 { touching.insert(label) }
            }
        }
        // Strokes are chosen BEFORE the print is erased, so a stroke that runs
        // through a parenthesis is not cut in two with half of it then
        // dropped for no longer touching the box.
        var keep = [Bool](repeating: false, count: width * height)
        for y in cropTop..<cropBottom {
            for x in 0..<width {
                let i = y * width + x
                keep[i] = labels[i] > 0 && touching.contains(labels[i]) && !furniture[i]
            }
        }
        var pixels = [UInt8](repeating: 255, count: width * max(cropBottom - cropTop, 0))
        for y in cropTop..<cropBottom {
            for x in 0..<width {
                let v = 1 - patch.intensity[y * width + x]
                pixels[(y - cropTop) * width + x] = UInt8(max(0, min(255, (v * 255).rounded())))
            }
        }
        return (patch.keeping(keep),
                GrayBitmap(width: width, height: cropBottom - cropTop, pixels: pixels))
    }
}
