import Foundation

// What the circle-or-cross forest actually looks at.
//
// Two steps, and the first matters more than the second.
//
// **Isolation.** Everything downstream is measured against *one* blob of ink —
// the one nearest the middle of the cell. Without that step the measurements
// are taken over whatever else survived `withoutPrintedMarks`: a parenthesis
// the filter missed, a stroke that leaked in from the row above, the printed
// heading at the top of the page. Measured on 58 real crops the phone uploaded,
// skipping isolation dropped the forest from 86% to 43% — not because the model
// got worse, but because the ink it was describing was no longer the answer.
//
// **Ratios, not pixels.** Fourteen numbers, each a share of the mark's own ink:
// six concentric bands out from its centre, eight angular sectors round it.
// They answer the same question the old probe asked — does anything run through
// the middle? — but by integrating over the whole blob instead of sampling 540
// points on three thin rings. Shift a real cell two pixels and the probe's
// crossing count changed 37% of the time; the forest's verdict changed 0.8%.
//
// Nothing here resamples. No resize, no interpolation, no filter kernel — every
// value is a count of pixels divided by a count of pixels, so the Swift and
// Python implementations agree exactly rather than to some tolerance, and the
// contract test in `RecognitionSelfTest` can demand equality.
enum MarkFeatures {

    /// Concentric bands from the mark's centre outwards.
    static let bands = 6
    /// Angular sectors round it.
    static let sectors = 8
    /// Outer edge of the last band, in units of the mark's own half-diagonal.
    /// Past 1.0 because the bounding box's corners sit at radius √2.
    static let radiusLimit = 1.2
    /// A blob smaller than this share of the cell is a speck, not an answer.
    static let minBlobAreaRatio = 0.004

    static var count: Int { bands + sectors }

    /// The ink of the mark itself: the largest-qualifying blob whose centre of
    /// mass sits nearest the middle of the cell.
    ///
    /// Nearest-to-centre rather than largest, because the thing most likely to
    /// outweigh a child's pencil mark is printed furniture, and printed
    /// furniture is what sits at the edges. Ties go to the lower label, which
    /// is raster order — the same rule the Python reference uses.
    static func isolate(mask: [Bool], width: Int, height: Int) -> [Bool]? {
        guard width > 0, height > 0, mask.count == width * height else { return nil }
        let (labels, count) = ConnectedComponents.label(mask, width: width,
                                                        height: height, connectivity: .eight)
        guard count > 0 else { return nil }

        var area = [Int](repeating: 0, count: count + 1)
        var sumX = [Double](repeating: 0, count: count + 1)
        var sumY = [Double](repeating: 0, count: count + 1)
        for y in 0..<height {
            for x in 0..<width {
                let label = labels[y * width + x]
                guard label > 0 else { continue }
                area[label] += 1
                sumX[label] += Double(x)
                sumY[label] += Double(y)
            }
        }

        let floor = minBlobAreaRatio * Double(width * height)
        let cx = Double(width) / 2, cy = Double(height) / 2
        var best = -1
        var bestDistance = Double.infinity
        for label in 1...count where Double(area[label]) >= floor {
            let dx = sumX[label] / Double(area[label]) - cx
            let dy = sumY[label] / Double(area[label]) - cy
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = label
            }
        }
        guard best > 0 else { return nil }
        return labels.map { $0 == best }
    }

    /// Fourteen shares of the mark's ink, radial then angular.
    ///
    /// Radius and angle are measured against the mark's own bounding box, so a
    /// mark drawn small in a large cell and the same mark filling it produce
    /// the same numbers. That is the property the old probe lacked: its radii
    /// were fractions of the blob's *shorter* side, which a tall narrow oval —
    /// the commonest way these children draw a circle — pushed straight onto
    /// its own strokes.
    static func extract(mark: [Bool], width: Int, height: Int) -> [Double] {
        var result = [Double](repeating: 0, count: count)
        guard width > 0, height > 0, mark.count == width * height else { return result }

        var minX = width, maxX = -1, minY = height, maxY = -1
        var total = 0
        for y in 0..<height {
            for x in 0..<width where mark[y * width + x] {
                total += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard total > 0, maxX >= minX, maxY >= minY else { return result }

        // Half-extents, floored at one pixel so a single-row mark cannot divide
        // by zero. The centre is the bounding box's, not the centroid's: a
        // cross with one long tail pulls its centre of mass off the crossing
        // point, which is the one place these measurements have to be taken.
        let halfW = max(1.0, Double(maxX - minX + 1) / 2)
        let halfH = max(1.0, Double(maxY - minY + 1) / 2)
        let cx = Double(minX + maxX) / 2
        let cy = Double(minY + maxY) / 2

        let scale = Double(total)
        for y in 0..<height {
            for x in 0..<width where mark[y * width + x] {
                let dx = (Double(x) - cx) / halfW
                let dy = (Double(y) - cy) / halfH

                let radius = (dx * dx + dy * dy).squareRoot()
                let band = Int(radius / radiusLimit * Double(bands))
                if band >= 0 && band < bands { result[band] += 1 }

                let angle = (atan2(dy, dx) + Double.pi) / (2 * Double.pi)
                let sector = Int(angle * Double(sectors))
                if sector >= 0 && sector < sectors { result[bands + sector] += 1 }
            }
        }
        for i in 0..<count { result[i] /= scale }
        return result
    }
}
