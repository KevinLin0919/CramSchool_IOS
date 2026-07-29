import AVFoundation
import CoreGraphics
import UIKit

// Frames leave the sensor in the camera's native landscape frame. Everything
// downstream — XFeat alignment, the projected box geometry, the overlay —
// works in an "upright" frame: that buffer rotated to match what the user is
// actually looking at. That rotation used to be hardcoded to portrait in three
// separate places (the analysis image, the intrinsics, the overlay's inverse
// mapping), which is why the app could only ever run portrait. This is now the
// only place that knows it, so those three cannot drift apart — and if the
// table below were ever wrong, preview and overlay would be wrong *together*,
// leaving the boxes still glued to the paper.
//
// The angles are AVFoundation's videoRotationAngle convention, which maps 1:1
// onto UIInterfaceOrientation (unlike UIDeviceOrientation, whose two landscape
// cases are swapped relative to the interface). Portrait = 90° is the anchor:
// it is also the angle a preview connection starts at, which is why the old
// portrait-only build worked without ever setting one.
enum CaptureOrientation {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    init(_ interface: UIInterfaceOrientation) {
        switch interface {
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft:      self = .landscapeLeft
        case .landscapeRight:     self = .landscapeRight
        default:                  self = .portrait   // .portrait and .unknown
        }
    }

    // Clockwise degrees taking the sensor buffer to the upright frame.
    var videoRotationAngle: CGFloat {
        switch self {
        case .landscapeRight:     return 0
        case .portrait:           return 90
        case .landscapeLeft:      return 180
        case .portraitUpsideDown: return 270
        }
    }

    // The same rotation, for CIImage.oriented and Vision request handlers.
    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .landscapeRight:     return .up
        case .portrait:           return .right
        case .landscapeLeft:      return .down
        case .portraitUpsideDown: return .left
        }
    }

    // A quarter turn, so the upright frame's width comes from the buffer's
    // height rather than its width.
    var swapsAxes: Bool {
        self == .portrait || self == .portraitUpsideDown
    }

    // Upright-normalized point -> capture-device normalized point, the space
    // AVCaptureVideoPreviewLayer.layerPointConverted(fromCaptureDevicePoint:)
    // expects. This is the inverse of rotating the device frame clockwise by
    // the angle above; a clockwise quarter turn sends (x, y) to (1 - y, x).
    func devicePoint(fromUpright p: CGPoint) -> CGPoint {
        switch self {
        case .landscapeRight:     return p
        case .portrait:           return CGPoint(x: p.y, y: 1 - p.x)
        case .landscapeLeft:      return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .portraitUpsideDown: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    // A point in sensor-buffer pixels mapped into upright-frame pixels, for
    // carrying the intrinsics' principal point across the same rotation.
    func upright(point p: CGPoint, bufferSize: CGSize) -> CGPoint {
        switch self {
        case .landscapeRight:
            return p
        case .portrait:
            return CGPoint(x: bufferSize.height - p.y, y: p.x)
        case .landscapeLeft:
            return CGPoint(x: bufferSize.width - p.x, y: bufferSize.height - p.y)
        case .portraitUpsideDown:
            return CGPoint(x: p.y, y: bufferSize.width - p.x)
        }
    }

    // The interface orientation this view is currently living in. Deliberately
    // the *interface* and not the device: iPhone stays portrait-locked, and a
    // locked UI must not rotate its camera when the handset is turned.
    static func current(for view: UIView) -> CaptureOrientation {
        guard let scene = view.window?.windowScene else { return .portrait }
        return CaptureOrientation(scene.interfaceOrientation)
    }
}
