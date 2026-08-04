import Foundation

// Circle-or-cross recognition by topology rather than by appearance.
//
// A circle encloses a region; a cross does not. That property survives every
// way a student can distort the shape — squashed, tilted, oversized, drawn
// counter-clockwise — because it asks "is anything enclosed?" instead of
// "does this look like an O?". No model, no training data, no inference cost.
//
// The one thing it is fragile about is connectivity: topologically, a circle
// whose ends miss each other by a single pixel is identical to one that misses
// by a mile — neither encloses anything. Students routinely leave that gap, so
// the morphological closing below is not an optimisation, it is the load-bearing
// step. Everything else here is guarding the two failure modes that remain:
// a gap too wide to seal, and a scribbled cross that accidentally encloses
// a speck.

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
        /// Ink share of the middle of the mark. A cross runs through its own
        /// centre; a circle is empty there.
        static let crossCentreDensity = 0.15
        /// Below this the centre is empty, which for something with no hole
        /// means an unclosed circle far more often than it means a cross.
        static let openCircleCentreDensity = 0.05
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

        // No hole. Usually a cross — but an unclosed circle looks identical to
        // the hole count, so ask whether anything is actually drawn through the
        // middle before committing.
        let density = centreDensity(closed, width: w, height: h)
        let confidence: Double
        if density >= Tuning.crossCentreDensity {
            confidence = 1
        } else if density <= Tuning.openCircleCentreDensity {
            confidence = 0.2
        } else {
            confidence = 0.2 + 0.8 * (density - Tuning.openCircleCentreDensity)
                / (Tuning.crossCentreDensity - Tuning.openCircleCentreDensity)
        }
        return Result(mark: .cross, confidence: confidence, holeCount: 0, holeArea: 0)
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

    /// Ink share of the middle third of the mark's own bounding box — not of
    /// the cell, so an off-centre mark is still measured through its middle.
    private static func centreDensity(_ mask: [Bool], width: Int, height: Int) -> Double {
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

        let w = maxX - minX + 1, h = maxY - minY + 1
        let x0 = minX + w / 3, x1 = minX + (2 * w) / 3
        let y0 = minY + h / 3, y1 = minY + (2 * h) / 3
        guard x1 >= x0, y1 >= y0 else { return 0 }

        var ink = 0, total = 0
        for y in y0...y1 {
            for x in x0...x1 {
                total += 1
                if mask[y * width + x] { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }
}
