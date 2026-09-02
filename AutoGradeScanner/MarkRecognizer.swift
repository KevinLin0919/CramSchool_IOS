import Foundation

// Circle-or-cross recognition by geometry rather than by appearance.
//
// The question is "does anything run through the middle?", not "is anything
// enclosed?". A cross's strokes radiate from where they meet, so a circle
// drawn around that point is crossed four times whatever its radius. A circle
// — or an arc, or a C, or a U — is empty inside, so the same probe finds
// nothing. That holds however wide the student left the gap, which is the
// whole point.
//
// It replaces an enclosure test, and the replacement was not a refinement.
// Measured against ten real cells off a 康軒 社會4上 worksheet, counting
// enclosed regions scored 5/10 and got one of them confidently wrong — a
// student's ○ reported as ✗ at full confidence, which flips a right answer
// to wrong. The reason is visible the moment you look at the ink: these
// children do not draw closed circles with a small gap, they draw open arcs.
// The opening is 30–50% of the diameter, and no morphological closing can
// bridge that without also filling in the hole it was meant to preserve.
//
// The enclosure test survives as a fast path, because when a circle IS closed
// that is the cheapest and most certain evidence there is. It just no longer
// decides the cases it was getting wrong.

enum Mark: String {
    case circle = "O"
    case cross = "X"
}

enum MarkRecognizer {

    struct Result {
        let mark: Mark
        /// 0…1. Low values mean the topology was ambiguous, not that the mark
        /// was faint — callers should prefer another frame over trusting this.
        let confidence: Double
        let holeCount: Int
        /// Largest enclosed region as a fraction of the cell.
        let holeArea: Double
        /// Most times a probe circle round the mark's middle met ink. Four for
        /// a well-drawn cross, zero for anything hollow. Reported so the
        /// diagnostic overlay can show the number the decision came from.
        var crossings: Int = 0
    }

    enum Tuning {
        /// Closing radius as a fraction of the cell's short side. Has to exceed
        /// half the typical pen-stroke gap, and stay well under the radius of a
        /// circle's interior — too large and the closing fills the hole it was
        /// supposed to preserve, turning every O into an X.
        static let closingRadiusRatio = 0.04
        /// Enclosed regions smaller than this share of the cell are ink noise:
        /// the little triangle a scrawled cross leaves where its strokes
        /// overshoot, or a speck of paper texture.
        static let minHoleAreaRatio = 0.015
        /// A hole at least this big is unambiguous.
        static let confidentHoleAreaRatio = 0.08

        /// Radii of the probe circles, as fractions of the mark's shorter
        /// side. Three of them, and the largest count wins.
        ///
        /// One circle is not enough: a cross whose strokes meet off-centre is
        /// missed by a probe drawn round the middle of its bounding box, and
        /// measured on real ink that happened — a single 0.20 probe found one
        /// crossing where three found four. They stop at 0.30 because beyond
        /// that a small tight ○ starts being met by its own ring.
        static let probeRadiusRatios = [0.18, 0.24, 0.30]
        /// Points sampled round each circle. 180 puts a sample every 2°, which
        /// is finer than any pen stroke is thin at these cell sizes.
        static let probeSamples = 180
        /// At or above this, strokes are running through the middle.
        static let crossCrossings = 3
        /// At or below this, the middle is hollow.
        static let circleCrossings = 1
    }

    /// Returns nil when the cell holds no mark at all — blank, or so dark the
    /// projection has clearly drifted off the sheet.
    static func recognize(_ patch: CellPatch) -> Result? {
        guard !patch.isBlank, patch.coverage <= CellPatch.Tuning.maxCoverage else { return nil }

        let radius = max(1, Int((Double(min(patch.width, patch.height))
                                 * Tuning.closingRadiusRatio).rounded()))
        // Pad before closing so a mark touching the cell edge is not eroded
        // away, and so the flood fill below is guaranteed a background border
        // to start from.
        let pad = radius + 1
        let (padded, w, h) = Morphology.padded(patch.mask, width: patch.width,
                                               height: patch.height, pad: pad)
        let closed = Morphology.close(padded, width: w, height: h, radius: radius)

        let holes = enclosedRegions(in: closed, width: w, height: h)
        let cellArea = Double(patch.width * patch.height)
        let significant = holes.filter { Double($0) / cellArea >= Tuning.minHoleAreaRatio }
        let largest = Double(significant.max() ?? 0) / cellArea

        if !significant.isEmpty {
            return Result(mark: .circle,
                          confidence: min(1, largest / Tuning.confidentHoleAreaRatio),
                          holeCount: significant.count,
                          holeArea: largest)
        }

        // Nothing enclosed, which says almost nothing on its own — an arc and
        // a cross both enclose nothing. Ask the probe instead.
        let crossings = maxProbeCrossings(closed, width: w, height: h)

        if crossings >= Tuning.crossCrossings {
            return Result(mark: .cross, confidence: 1, holeCount: 0, holeArea: 0,
                          crossings: crossings)
        }
        if crossings <= Tuning.circleCrossings {
            // Hollow, and not closed: an arc, a C, a U. Every open ○ in the
            // sample landed here, and the old code called all of them crosses.
            return Result(mark: .circle, confidence: 0.85, holeCount: 0, holeArea: 0,
                          crossings: crossings)
        }
        // Two crossings. A cross drawn so faintly that a stroke was missed, or
        // a ○ small enough that the outer probe met its own ring. Answer, but
        // at a confidence the accumulator will not vote on alone.
        return Result(mark: .cross, confidence: 0.3, holeCount: 0, holeArea: 0,
                      crossings: crossings)
    }

    /// Most times a circle drawn round the mark's middle meets ink.
    ///
    /// Centred on the bounding box rather than the ink's centre of mass: a
    /// cross with one long tail pulls its centroid off the crossing point,
    /// which is the one place the probe has to be. Sized from the mark, not
    /// the cell, so a small mark in a large cell is still probed through its
    /// own middle.
    static func maxProbeCrossings(_ mask: [Bool], width: Int, height: Int) -> Int {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return 0 }

        let cx = Double(minX + maxX) / 2, cy = Double(minY + maxY) / 2
        let side = Double(min(maxX - minX, maxY - minY))

        var best = 0
        for ratio in Tuning.probeRadiusRatios {
            let r = side * ratio
            guard r >= 2 else { continue }
            best = max(best, crossings(mask, width: width, height: height,
                                       cx: cx, cy: cy, radius: r))
        }
        return best
    }

    /// Runs of ink met while walking once round a circle. Counts the starts of
    /// runs, not the samples, so a thick stroke is one crossing rather than
    /// several — and the walk wraps, so a run straddling 0° is not counted
    /// twice.
    private static func crossings(_ mask: [Bool], width: Int, height: Int,
                                  cx: Double, cy: Double, radius: Double) -> Int {
        let n = Tuning.probeSamples
        var samples = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n)
            let x = Int((cx + radius * cos(t)).rounded())
            let y = Int((cy + radius * sin(t)).rounded())
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            samples[i] = mask[y * width + x]
        }
        var runs = 0
        for i in 0..<n where samples[i] && !samples[(i + n - 1) % n] { runs += 1 }
        return runs
    }

    /// Areas of the background regions that cannot reach the border — the holes.
    ///
    /// Note this counts holes rather than computing the Euler number
    /// (components − holes). Euler is the textbook invariant, but a cross drawn
    /// as two strokes that do not quite touch is two components, which would
    /// score the same as a shape with a hole. The hole count alone is what
    /// actually separates O from X.
    static func enclosedRegions(in mask: [Bool], width: Int, height: Int) -> [Int] {
        let background = mask.map { !$0 }
        let (labels, count) = ConnectedComponents.label(background, width: width,
                                                        height: height, connectivity: .four)
        guard count > 0 else { return [] }

        var touchesBorder = [Bool](repeating: false, count: count + 1)
        for x in 0..<width {
            touchesBorder[labels[x]] = true
            touchesBorder[labels[(height - 1) * width + x]] = true
        }
        for y in 0..<height {
            touchesBorder[labels[y * width]] = true
            touchesBorder[labels[y * width + width - 1]] = true
        }

        var areas = [Int](repeating: 0, count: count + 1)
        for label in labels where label > 0 { areas[label] += 1 }

        return (1...count).compactMap { touchesBorder[$0] ? nil : areas[$0] }
    }
}
