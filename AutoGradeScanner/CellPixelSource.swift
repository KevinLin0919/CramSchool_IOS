import CoreImage
import CoreVideo
import UIKit

// Where recognition reads its pixels from.
//
// Alignment and recognition want opposite things from the same frame.
// XFeat resizes whatever it is given to 832x608 internally, so the camera frame
// is downscaled to 1200px before alignment and nothing is lost. Recognition
// reads a cell a few tens of pixels across, and every pixel the sensor captured
// is one it can use — measured on real handwriting, a cell sampled at 128px
// scores 6/6 while the same cell at 64px scores 3/6. Sharing one downscaled
// frame between them was throwing that away.
//
// Cropping per cell is also *cheaper* than what it replaces: a handful of small
// crops totals well under the full-frame grayscale conversion the recogniser
// used to run on every frame.

protocol CellPixelSource {
    /// Size of the upright frame these cells are cropped from.
    ///
    /// Surfaced because it is the ceiling on everything downstream: a device
    /// that cannot deliver 4K hands over a ~1080px-wide buffer whatever the
    /// framing, and no amount of moving the camera fixes that. Knowing which
    /// it is turns "the answers read badly on this iPad" from a mystery into
    /// a number.
    var frameSize: CGSize { get }

    /// Grayscale pixels covering one cell.
    ///
    /// - Parameters:
    ///   - quad: cell corners in normalized (0...1) upright-frame coordinates,
    ///     origin top-left.
    ///   - maxSide: cap on the returned bitmap's long side. Sampling beyond
    ///     what `CellPatch` uses is wasted work, so getting closer to the paper
    ///     costs nothing extra past this point.
    /// - Returns: the bitmap, and `quad` re-expressed in its pixel coordinates.
    func cell(quad: [CGPoint], maxSide: Int) -> (bitmap: GrayBitmap, quad: [CGPoint])?
}

// MARK: - From an already-decoded image

/// Reads from a UIImage. This is the pre-existing behaviour — it is what the
/// headless tests drive, and what the camera path falls back to if the
/// full-resolution buffer is unavailable.
final class ImageCellSource: CellPixelSource {
    private let bitmap: GrayBitmap?

    var frameSize: CGSize {
        guard let bitmap else { return .zero }
        return CGSize(width: bitmap.width, height: bitmap.height)
    }

    init(_ image: UIImage) {
        bitmap = GrayBitmap(image)
    }

    func cell(quad: [CGPoint], maxSide: Int) -> (bitmap: GrayBitmap, quad: [CGPoint])? {
        guard let bitmap, quad.count == 4 else { return nil }
        let pixels = quad.map { CGPoint(x: $0.x * CGFloat(bitmap.width),
                                        y: $0.y * CGFloat(bitmap.height)) }
        return (bitmap, pixels)
    }
}

// MARK: - From the camera's own buffer

/// Reads from the capture buffer at full sensor resolution, rendering only the
/// requested cell.
///
/// The buffer is retained for as long as this object lives. The engine holds at
/// most one frame at a time (it drops frames while an alignment is in flight),
/// so the capture pool keeps its other buffers.
final class PixelBufferCellSource: CellPixelSource {
    private let buffer: CVPixelBuffer
    private let orientation: CaptureOrientation
    private let context: CIContext

    let frameSize: CGSize

    init(buffer: CVPixelBuffer, orientation: CaptureOrientation, context: CIContext) {
        self.buffer = buffer
        self.orientation = orientation
        self.context = context
        let extent = CIImage(cvPixelBuffer: buffer).oriented(orientation.cgOrientation).extent
        frameSize = extent.size
    }

    func cell(quad: [CGPoint], maxSide: Int) -> (bitmap: GrayBitmap, quad: [CGPoint])? {
        guard quad.count == 4 else { return nil }
        let image = CIImage(cvPixelBuffer: buffer).oriented(orientation.cgOrientation)
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        // Normalized coordinates put the origin top-left; CIImage puts it
        // bottom-left. Flip y once here rather than in every caller.
        let points = quad.map {
            CGPoint(x: extent.minX + $0.x * extent.width,
                    y: extent.maxY - $0.y * extent.height)
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        // A little margin: the projected quad is only as accurate as the
        // homography, and clipping the answer is worse than including a sliver
        // of its box border, which the printed-mark filter removes anyway.
        let pad = max(2, min(xs.max()! - xs.min()!, ys.max()! - ys.min()!) * 0.08)
        var crop = CGRect(x: xs.min()! - pad, y: ys.min()! - pad,
                          width: xs.max()! - xs.min()! + 2 * pad,
                          height: ys.max()! - ys.min()! + 2 * pad)
        crop = crop.intersection(extent)
        guard crop.width >= 4, crop.height >= 4 else { return nil }

        let scale = min(1, CGFloat(maxSide) / max(crop.width, crop.height))
        let scaled = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent),
              let bitmap = GrayBitmap(UIImage(cgImage: cgImage)) else { return nil }

        // Same flip again, now into the rendered crop's own pixel grid.
        let mapped = points.map {
            CGPoint(x: ($0.x - crop.minX) * scale,
                    y: (crop.maxY - $0.y) * scale)
        }
        return (bitmap, mapped)
    }
}
