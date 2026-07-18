import UIKit
import Accelerate
import simd

// Descriptor matching and robust homography estimation on top of XFeatEngine,
// mirroring XFeat.match (mutual nearest neighbor over cosine similarity) from
// the reference implementation.
enum XFeatMatcher {

    // Pairs (indexInA, indexInB) of mutual nearest neighbors whose cosine
    // similarity exceeds minSimilarity. Descriptors are unit length, so the
    // dot product is the cosine; the whole similarity matrix comes from one
    // A (n x 64) * B^T (64 x m) multiply.
    //
    // ratioMargin is a Lowe-style ambiguity filter: the best match must beat
    // the runner-up by at least this much. Printed forms are full of repeated
    // structure (identical answer-box frames in a regular grid) whose corners
    // are indistinguishable to the descriptor; those all-alike matches would
    // otherwise let RANSAC lock onto a row-shifted false alignment.
    static func match(_ a: XFeatFeatures, _ b: XFeatFeatures,
                      minSimilarity: Float = 0.82,
                      ratioMargin: Float = 0.015) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }

        var bTransposed = [Float](repeating: 0, count: 64 * m)
        for j in 0..<m {
            for d in 0..<64 {
                bTransposed[d * m + j] = b.descriptors[j * 64 + d]
            }
        }
        var similarity = [Float](repeating: 0, count: n * m)
        vDSP_mmul(a.descriptors, 1, bTransposed, 1, &similarity, 1,
                  vDSP_Length(n), vDSP_Length(m), 64)

        var bestColumnForRow = [Int](repeating: -1, count: n)
        var bestRowValue = [Float](repeating: -.infinity, count: n)
        var secondRowValue = [Float](repeating: -.infinity, count: n)
        var bestRowForColumn = [Int](repeating: -1, count: m)
        var bestColumnValue = [Float](repeating: -.infinity, count: m)
        for i in 0..<n {
            let row = i * m
            for j in 0..<m {
                let value = similarity[row + j]
                if value > bestRowValue[i] {
                    secondRowValue[i] = bestRowValue[i]
                    bestRowValue[i] = value
                    bestColumnForRow[i] = j
                } else if value > secondRowValue[i] {
                    secondRowValue[i] = value
                }
                if value > bestColumnValue[j] {
                    bestColumnValue[j] = value
                    bestRowForColumn[j] = i
                }
            }
        }

        var pairs: [(Int, Int)] = []
        for i in 0..<n {
            let j = bestColumnForRow[i]
            if j >= 0 && bestRowForColumn[j] == i
                && bestRowValue[i] >= minSimilarity
                && bestRowValue[i] - secondRowValue[i] >= ratioMargin {
                pairs.append((i, j))
            }
        }
        return pairs
    }

    // MARK: - RANSAC homography

    struct Homography {
        let matrix: simd_double3x3   // normalized source coords -> normalized destination coords
        let inlierCount: Int
        let matchCount: Int
        // Bounding box (source/template normalized coords) of the inlier
        // keypoints — the region of the source that was actually observed.
        // Content projected from outside it is extrapolation, not evidence.
        let sourceInlierBounds: CGRect

        var inlierRatio: Double {
            matchCount > 0 ? Double(inlierCount) / Double(matchCount) : 0
        }

        func project(_ point: CGPoint) -> CGPoint {
            let p = matrix * simd_double3(Double(point.x), Double(point.y), 1)
            return CGPoint(x: p.x / p.z, y: p.y / p.z)
        }

        // The rect's four corners projected through the homography, in
        // tl, tr, br, bl order. Drawing this quadrilateral (instead of its
        // bounding box) keeps the overlay tight on a tilted page.
        func projectedCorners(of rect: CGRect) -> [CGPoint] {
            [CGPoint(x: rect.minX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY)].map(project)
        }

        // Axis-aligned bounding box of the projected corners.
        func project(_ rect: CGRect) -> CGRect {
            let corners = projectedCorners(of: rect)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    // Estimates the homography mapping source onto destination with RANSAC.
    // Points are expected in normalized 0...1 coordinates; the default
    // reprojection threshold (~0.008) is about 5 px on the model input.
    //
    // `prior` (the previous frame's solution, in the same coordinate spaces)
    // enables a tracking fast path: when the prior still explains enough of
    // the new matches it is refined by one least-squares pass and RANSAC is
    // skipped entirely — the dominant per-frame cost while locked on.
    static func findHomography(from source: [CGPoint], to destination: [CGPoint],
                               reprojectionThreshold: Double = 0.008,
                               iterations: Int = 800,
                               prior: simd_double3x3? = nil) -> Homography? {
        let count = min(source.count, destination.count)
        guard count >= 4 else { return nil }

        let src = source.map { simd_double2(Double($0.x), Double($0.y)) }
        let dst = destination.map { simd_double2(Double($0.x), Double($0.y)) }
        let thresholdSq = reprojectionThreshold * reprojectionThreshold

        if let prior {
            var priorInliers: [Int] = []
            for i in 0..<count where reprojectionErrorSq(prior, src[i], dst[i]) < thresholdSq {
                priorInliers.append(i)
            }
            if priorInliers.count >= 12,
               let refined = solveHomography(indices: priorInliers, src: src, dst: dst),
               let result = finalize(refined, src: src, dst: dst, thresholdSq: thresholdSq) {
                return result
            }
        }

        var bestInliers: [Int] = []
        for _ in 0..<iterations {
            var picks = Set<Int>()
            while picks.count < 4 {
                picks.insert(Int.random(in: 0..<count))
            }
            guard let candidate = solveHomography(indices: Array(picks), src: src, dst: dst) else {
                continue
            }
            var inliers: [Int] = []
            for i in 0..<count where reprojectionErrorSq(candidate, src[i], dst[i]) < thresholdSq {
                inliers.append(i)
            }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
            }
        }
        guard bestInliers.count >= 4,
              let refined = solveHomography(indices: bestInliers, src: src, dst: dst) else {
            return nil
        }
        return finalize(refined, src: src, dst: dst, thresholdSq: thresholdSq)
    }

    // Recounts inliers of the refined matrix and packages the result.
    private static func finalize(_ refined: simd_double3x3,
                                 src: [simd_double2], dst: [simd_double2],
                                 thresholdSq: Double) -> Homography? {
        var inlierCount = 0
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for i in 0..<src.count where reprojectionErrorSq(refined, src[i], dst[i]) < thresholdSq {
            inlierCount += 1
            minX = min(minX, src[i].x); maxX = max(maxX, src[i].x)
            minY = min(minY, src[i].y); maxY = max(maxY, src[i].y)
        }
        guard inlierCount >= 4 else { return nil }
        return Homography(matrix: refined, inlierCount: inlierCount,
                          matchCount: src.count,
                          sourceInlierBounds: CGRect(x: minX, y: minY,
                                                     width: maxX - minX,
                                                     height: maxY - minY))
    }

    // Direct linear transform with h33 fixed to 1, solved via normal
    // equations: exact for 4 correspondences, least-squares beyond.
    private static func solveHomography(indices: [Int],
                                        src: [simd_double2],
                                        dst: [simd_double2]) -> simd_double3x3? {
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for i in indices {
            let s = src[i], d = dst[i]
            let rows: [([Double], Double)] = [
                ([s.x, s.y, 1, 0, 0, 0, -d.x * s.x, -d.x * s.y], d.x),
                ([0, 0, 0, s.x, s.y, 1, -d.y * s.x, -d.y * s.y], d.y),
            ]
            for (row, rhs) in rows {
                for p in 0..<8 {
                    atb[p] += row[p] * rhs
                    for q in 0..<8 {
                        ata[p * 8 + q] += row[p] * row[q]
                    }
                }
            }
        }
        guard let h = solveLinearSystem(ata, atb, size: 8) else { return nil }
        return simd_double3x3(rows: [simd_double3(h[0], h[1], h[2]),
                                     simd_double3(h[3], h[4], h[5]),
                                     simd_double3(h[6], h[7], 1)])
    }

    // Gaussian elimination with partial pivoting.
    private static func solveLinearSystem(_ matrix: [Double], _ rhs: [Double],
                                          size: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        for col in 0..<size {
            var pivot = col
            for row in (col + 1)..<size where abs(a[row * size + col]) > abs(a[pivot * size + col]) {
                pivot = row
            }
            guard abs(a[pivot * size + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<size {
                    a.swapAt(col * size + k, pivot * size + k)
                }
                b.swapAt(col, pivot)
            }
            for row in (col + 1)..<size {
                let factor = a[row * size + col] / a[col * size + col]
                if factor == 0 { continue }
                for k in col..<size {
                    a[row * size + k] -= factor * a[col * size + k]
                }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: size)
        for row in stride(from: size - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<size {
                sum -= a[row * size + k] * x[k]
            }
            x[row] = sum / a[row * size + row]
        }
        return x
    }

    private static func reprojectionErrorSq(_ h: simd_double3x3,
                                            _ s: simd_double2, _ d: simd_double2) -> Double {
        let p = h * simd_double3(s.x, s.y, 1)
        guard abs(p.z) > 1e-12 else { return .infinity }
        let dx = p.x / p.z - d.x
        let dy = p.y / p.z - d.y
        return dx * dx + dy * dy
    }
}

// MARK: - High-level alignment

// Estimates the homography that maps normalized coordinates in the template
// image onto normalized coordinates in the scanned photo. Template answer
// boxes (800x600 web-canvas space) can then be projected onto the scan by
// normalizing with WebCanvas dimensions first, removing the dependency on
// YOLO detection order.
enum XFeatAligner {
    static func alignmentHomography(template: UIImage, scan: UIImage,
                                    minMatches: Int = 12) throws -> XFeatMatcher.Homography? {
        guard let engine = XFeatEngine.shared else { throw XFeatError.modelMissing }
        let templateFeatures = try engine.extract(from: template)
        let scanFeatures = try engine.extract(from: scan)
        let pairs = XFeatMatcher.match(templateFeatures, scanFeatures)
        guard pairs.count >= minMatches else { return nil }
        return XFeatMatcher.findHomography(from: pairs.map { templateFeatures.keypoints[$0.0] },
                                           to: pairs.map { scanFeatures.keypoints[$0.1] })
    }

    // Partial-view alignment. A photo of only part of the sheet shows its
    // content ~2x larger than the full-page template does, which breaks
    // plain nearest-neighbor matching. Match the scan against several
    // windows of the template (full page, top/bottom band) so one window's
    // content scale roughly agrees with the photo, keep the candidate with
    // the most RANSAC inliers, and map its homography back to full-template
    // coordinates.
    static func partialAlignmentHomography(template: UIImage, scan: UIImage,
                                           minMatches: Int = 12) throws -> XFeatMatcher.Homography? {
        try XFeatTemplateMatcher(template: template).align(scan: scan, minMatches: minMatches)
    }
}

// Template-side feature cache for repeated alignment against one master
// sheet: the window features are extracted once, so aligning a stream of
// camera frames only pays for the scan-side extraction each time.
final class XFeatTemplateMatcher {
    private struct WindowEntry {
        let window: CGRect            // normalized region of the template
        let features: XFeatFeatures
    }

    // A live-tracking result: the homography plus which template window
    // produced it, so the next frame can try that window first.
    struct TrackedAlignment {
        let homography: XFeatMatcher.Homography
        let windowIndex: Int
    }

    // The scan side keeps fewer keypoints than the template: matching cost is
    // n×m, and camera frames show at most part of the page, so 1024 is ample
    // while halving the similarity-matrix multiply.
    static let scanTopK = 1024

    private let entries: [WindowEntry]

    init(template: UIImage) throws {
        guard let engine = XFeatEngine.shared else { throw XFeatError.modelMissing }
        let windows = [CGRect(x: 0, y: 0, width: 1, height: 1),
                       CGRect(x: 0, y: 0, width: 1, height: 0.6),
                       CGRect(x: 0, y: 0.4, width: 1, height: 0.6)]
        entries = try windows.compactMap { window in
            guard let cropped = XFeatTemplateMatcher.crop(template, to: window) else { return nil }
            return WindowEntry(window: window, features: try engine.extract(from: cropped))
        }
    }

    func align(scan: UIImage, minMatches: Int = 12) throws -> XFeatMatcher.Homography? {
        guard let engine = XFeatEngine.shared else { throw XFeatError.modelMissing }
        let features = try engine.extract(from: scan, topK: XFeatTemplateMatcher.scanTopK)
        return align(scanFeatures: features, minMatches: minMatches)
    }

    func align(scanFeatures: XFeatFeatures, minMatches: Int = 12) -> XFeatMatcher.Homography? {
        alignTracked(scanFeatures: scanFeatures, minMatches: minMatches, hint: nil)?.homography
    }

    func alignTracked(scan: UIImage, minMatches: Int = 12,
                      hint: (windowIndex: Int, matrix: simd_double3x3)?) throws -> TrackedAlignment? {
        guard let engine = XFeatEngine.shared else { throw XFeatError.modelMissing }
        let features = try engine.extract(from: scan, topK: XFeatTemplateMatcher.scanTopK)
        return alignTracked(scanFeatures: features, minMatches: minMatches, hint: hint)
    }

    // Tracking-aware alignment. With a hint from the previous frame the
    // hinted window is tried first, seeded with the previous full-template
    // homography as a RANSAC-skipping prior; a solid result short-circuits
    // the other windows, cutting the per-frame matching cost to a third.
    func alignTracked(scanFeatures: XFeatFeatures, minMatches: Int = 12,
                      hint: (windowIndex: Int, matrix: simd_double3x3)?) -> TrackedAlignment? {
        if let hint, entries.indices.contains(hint.windowIndex),
           let quick = candidate(at: hint.windowIndex, scanFeatures: scanFeatures,
                                 minMatches: minMatches, priorFullTemplate: hint.matrix),
           quick.homography.inlierCount >= 24 {
            return quick
        }

        var best: TrackedAlignment?
        for index in entries.indices {
            guard let c = candidate(at: index, scanFeatures: scanFeatures,
                                    minMatches: minMatches, priorFullTemplate: nil) else { continue }
            if c.homography.inlierCount > (best?.homography.inlierCount ?? 0) {
                best = c
            }
        }
        return best
    }

    private func candidate(at index: Int, scanFeatures: XFeatFeatures,
                           minMatches: Int,
                           priorFullTemplate: simd_double3x3?) -> TrackedAlignment? {
        let entry = entries[index]
        let window = entry.window
        let pairs = XFeatMatcher.match(entry.features, scanFeatures)

        // Affine a maps full-template coords into this window's coords; its
        // inverse turns a full-template prior into a window-space prior.
        let a = simd_double3x3(rows: [
            simd_double3(1 / Double(window.width), 0, -Double(window.minX) / Double(window.width)),
            simd_double3(0, 1 / Double(window.height), -Double(window.minY) / Double(window.height)),
            simd_double3(0, 0, 1)])
        let aInverse = simd_double3x3(rows: [
            simd_double3(Double(window.width), 0, Double(window.minX)),
            simd_double3(0, Double(window.height), Double(window.minY)),
            simd_double3(0, 0, 1)])

        let h = pairs.count >= minMatches
            ? XFeatMatcher.findHomography(from: pairs.map { entry.features.keypoints[$0.0] },
                                          to: pairs.map { scanFeatures.keypoints[$0.1] },
                                          prior: priorFullTemplate.map { $0 * aInverse })
            : nil
        #if DEBUG
        if ProcessInfo.processInfo.environment["DEMO_SELFTEST_SCAN"] != nil {
            print("XFEAT window=\(window) features=\(entry.features.count) "
                  + "pairs=\(pairs.count) inliers=\(h?.inlierCount ?? 0)")
        }
        #endif
        guard let h else { return nil }

        let b = h.sourceInlierBounds
        let composed = XFeatMatcher.Homography(
            matrix: h.matrix * a,
            inlierCount: h.inlierCount,
            matchCount: h.matchCount,
            sourceInlierBounds: CGRect(x: b.minX * window.width + window.minX,
                                       y: b.minY * window.height + window.minY,
                                       width: b.width * window.width,
                                       height: b.height * window.height))
        return TrackedAlignment(homography: composed, windowIndex: index)
    }

    private static func crop(_ image: UIImage, to normalized: CGRect) -> UIImage? {
        if normalized == CGRect(x: 0, y: 0, width: 1, height: 1) { return image }
        guard let cg = image.cgImage else { return nil }
        let rect = CGRect(x: normalized.minX * CGFloat(cg.width),
                          y: normalized.minY * CGFloat(cg.height),
                          width: normalized.width * CGFloat(cg.width),
                          height: normalized.height * CGFloat(cg.height))
        guard let croppedCG = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: croppedCG)
    }
}
