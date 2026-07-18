import SwiftUI
import ARKit
import SceneKit
import simd

// Phase 3 of the layered scan architecture: ARKit world tracking as the
// motion backbone (PoC, opt-in from 設定). The division of labor stands:
// XFeat still answers "where is the paper" — ARKit never sees the paper's
// content, so its texture requirements are irrelevant — while ARKit's VIO
// answers "where is the camera" at 60 fps with full 6-DOF.
//
// On every XFeat anchor, the answer-box corners are cast from the anchor
// frame's camera onto the detected desk plane, pinning them in world
// coordinates. Every rendered frame then re-projects those world points
// through the current camera: rotation AND translation are compensated,
// and between-anchor drift is ARKit-grade (near zero) instead of
// gyro-integration-grade. With no desk plane detected yet, the overlay
// falls back to the anchor-rate quads (Phase 1 behavior).
struct ARScanContainer: UIViewRepresentable {
    let engine: LiveScanEngine
    var live: LiveScanEngine.Update?

    func makeUIView(context: Context) -> ARScanView {
        let view = ARScanView()
        view.engine = engine
        view.startSession()
        return view
    }

    func updateUIView(_ uiView: ARScanView, context: Context) {
        uiView.engine = engine
        uiView.update = live
    }

    static func dismantleUIView(_ uiView: ARScanView, coordinator: ()) {
        uiView.stopSession()
    }
}

final class ARScanView: ARSCNView, ARSessionDelegate {

    weak var engine: LiveScanEngine?

    var update: LiveScanEngine.Update? {
        didSet {
            // A new anchor (different frame timestamp) re-pins the world quads.
            if update?.frameTimestamp != oldValue?.frameTimestamp {
                pinWorldQuads()
            }
            renderBoxes()
        }
    }

    private let ciContext = CIContext()
    private var busy = false
    private var frameCounter = 0

    // Recent camera states, so an XFeat anchor (computed on a ~100 ms old
    // frame) can be unprojected with the camera that actually captured it.
    private var cameraHistory: [(time: TimeInterval, transform: simd_float4x4,
                                 intrinsics: simd_float3x3, resolution: CGSize)] = []

    // Largest detected plane the paper is assumed to lie on (desk, or the
    // monitor showing the demo sheet).
    private var deskPlane: ARPlaneAnchor?

    // World-pinned quad corners per question, from the latest anchor.
    private var worldQuads: [Int: [simd_float3]] = [:]

    private var boxLayers: [Int: CAShapeLayer] = [:]

    // MARK: - Session lifecycle

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }
        session.delegate = self
        scene = SCNScene()
        automaticallyUpdatesLighting = true
        let configuration = ARWorldTrackingConfiguration()
        // Horizontal for paper on a desk, vertical so a sheet shown on a
        // monitor (the usual demo setup) can be pinned too.
        configuration.planeDetection = [.horizontal, .vertical]
        session.run(configuration)
    }

    func stopSession() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Only trust poses while tracking is nominal: a degraded pose in the
        // history would poison world pinning, and skipping it makes anchor
        // lookups fail → the overlay silently falls back to anchor-rate
        // quads until tracking recovers.
        if case .normal = frame.camera.trackingState {
            cameraHistory.append((frame.timestamp, frame.camera.transform,
                                  frame.camera.intrinsics, frame.camera.imageResolution))
            if cameraHistory.count > 90 {
                cameraHistory.removeFirst(cameraHistory.count - 90)
            }
        }

        // Feed XFeat at a throttled cadence, dropping frames while busy —
        // same policy as the AVCapture path.
        frameCounter += 1
        if frameCounter % 3 == 0, !busy, let engine {
            busy = true
            let buffer = frame.capturedImage
            let timestamp = frame.timestamp
            let intrinsics = uprightIntrinsics(camera: frame.camera)
            Task.detached(priority: .userInitiated) { [weak self] in
                let image = self?.uprightImage(from: buffer)
                await MainActor.run {
                    guard let self else { return }
                    if let image {
                        self.engine?.submit(frame: image, timestamp: timestamp,
                                            intrinsics: intrinsics)
                    }
                    self.busy = false
                }
            }
        }

        renderBoxes()
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        adoptPlanes(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        adoptPlanes(anchors)
    }

    private func adoptPlanes(_ anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            if let current = deskPlane {
                let currentArea = current.planeExtent.width * current.planeExtent.height
                let area = plane.planeExtent.width * plane.planeExtent.height
                if plane.identifier == current.identifier || area > currentArea {
                    deskPlane = plane
                }
            } else {
                deskPlane = plane
            }
        }
    }

    // MARK: - World pinning

    // Cast each visible box corner from the anchor frame's camera onto the
    // desk plane and remember the world-space quads.
    private func pinWorldQuads() {
        worldQuads = [:]
        guard let update, update.frameTimestamp > 0,
              let plane = deskPlane,
              let camera = cameraState(at: update.frameTimestamp) else { return }

        let planeOrigin = simd_float3(plane.transform.columns.3.x,
                                      plane.transform.columns.3.y,
                                      plane.transform.columns.3.z)
        let planeNormal = simd_normalize(simd_float3(plane.transform.columns.1.x,
                                                     plane.transform.columns.1.y,
                                                     plane.transform.columns.1.z))

        for box in update.boxes {
            var corners: [simd_float3] = []
            for corner in box.quad {
                guard let world = intersectPlane(origin: planeOrigin, normal: planeNormal,
                                                 uprightPoint: corner, camera: camera) else {
                    corners = []
                    break
                }
                corners.append(world)
            }
            if corners.count == 4 {
                worldQuads[box.id] = corners
            }
        }
    }

    private func cameraState(at time: TimeInterval)
        -> (transform: simd_float4x4, intrinsics: simd_float3x3, resolution: CGSize)? {
        var best: (dt: TimeInterval, transform: simd_float4x4,
                   intrinsics: simd_float3x3, resolution: CGSize)?
        for entry in cameraHistory {
            let dt = abs(entry.time - time)
            if best == nil || dt < best!.dt {
                best = (dt, entry.transform, entry.intrinsics, entry.resolution)
            }
        }
        guard let best, best.dt < 0.05 else { return nil }
        return (best.transform, best.intrinsics, best.resolution)
    }

    // Ray from the (historical) camera through an upright-normalized image
    // point, intersected with the desk plane.
    private func intersectPlane(origin planeOrigin: simd_float3, normal: simd_float3,
                                uprightPoint: CGPoint,
                                camera: (transform: simd_float4x4,
                                         intrinsics: simd_float3x3,
                                         resolution: CGSize)) -> simd_float3? {
        // Upright-normalized -> capturedImage pixels (sensor landscape).
        let width = Float(camera.resolution.width)
        let height = Float(camera.resolution.height)
        let px = Float(uprightPoint.y) * width
        let py = Float(1 - uprightPoint.x) * height

        // ARKit camera space: +x along landscape image x, +y up (image y
        // negated), looking down -z.
        let fx = camera.intrinsics.columns.0.x
        let fy = camera.intrinsics.columns.1.y
        let cx = camera.intrinsics.columns.2.x
        let cy = camera.intrinsics.columns.2.y
        let directionCamera = simd_normalize(simd_float3((px - cx) / fx,
                                                         -(py - cy) / fy,
                                                         -1))
        let rotation = simd_float3x3(simd_float3(camera.transform.columns.0.x,
                                                 camera.transform.columns.0.y,
                                                 camera.transform.columns.0.z),
                                     simd_float3(camera.transform.columns.1.x,
                                                 camera.transform.columns.1.y,
                                                 camera.transform.columns.1.z),
                                     simd_float3(camera.transform.columns.2.x,
                                                 camera.transform.columns.2.y,
                                                 camera.transform.columns.2.z))
        let rayOrigin = simd_float3(camera.transform.columns.3.x,
                                    camera.transform.columns.3.y,
                                    camera.transform.columns.3.z)
        let rayDirection = rotation * directionCamera

        let denominator = simd_dot(rayDirection, normal)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = simd_dot(planeOrigin - rayOrigin, normal) / denominator
        guard t > 0.02, t < 10 else { return nil }
        return rayOrigin + rayDirection * t
    }

    // MARK: - Overlay

    private func renderBoxes() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let camera = session.currentFrame?.camera
        let trackingNormal: Bool
        if let camera, case .normal = camera.trackingState {
            trackingNormal = true
        } else {
            trackingNormal = false
        }
        let viewport = bounds.size
        var seen = Set<Int>()
        for box in update?.boxes ?? [] {
            let path = UIBezierPath()
            var complete = true

            if let camera, trackingNormal, viewport.width > 0, let world = worldQuads[box.id] {
                // World-pinned: full 6-DOF compensation.
                for (index, corner) in world.enumerated() {
                    let projected = camera.projectPoint(corner,
                                                        orientation: .portrait,
                                                        viewportSize: viewport)
                    guard projected.x.isFinite, projected.y.isFinite else {
                        complete = false
                        break
                    }
                    index == 0 ? path.move(to: projected) : path.addLine(to: projected)
                }
            } else if viewport.width > 0 {
                // No desk plane yet: draw the anchor-rate quads directly
                // (aspect-fill mapping of the upright frame onto the view).
                let frameSize = update?.frameSize ?? CGSize(width: 3, height: 4)
                let scale = max(viewport.width / max(frameSize.width, 1),
                                viewport.height / max(frameSize.height, 1))
                let drawWidth = frameSize.width * scale
                let drawHeight = frameSize.height * scale
                let offsetX = (viewport.width - drawWidth) / 2
                let offsetY = (viewport.height - drawHeight) / 2
                for (index, corner) in box.quad.enumerated() {
                    let point = CGPoint(x: offsetX + corner.x * drawWidth,
                                        y: offsetY + corner.y * drawHeight)
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            } else {
                complete = false
            }

            guard complete, !path.isEmpty else { continue }
            path.close()
            seen.insert(box.id)
            let shape = boxLayers[box.id] ?? makeBoxLayer(id: box.id)
            let color: UIColor = box.verdict.map {
                $0 ? UIColor(AG.ok) : UIColor(AG.bad)
            } ?? .white
            shape.path = path.cgPath
            shape.strokeColor = color.cgColor
            shape.fillColor = color.withAlphaComponent(box.verdict == nil ? 0.05 : 0.15).cgColor
        }
        for (id, stale) in boxLayers where !seen.contains(id) {
            stale.removeFromSuperlayer()
            boxLayers[id] = nil
        }
        CATransaction.commit()
    }

    private func makeBoxLayer(id: Int) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.lineWidth = 3
        shape.lineJoin = .round
        layer.addSublayer(shape)
        boxLayers[id] = shape
        return shape
    }

    // MARK: - Frame conversion (same policy as CameraController)

    private func uprightImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let width = image.extent.width
        if width > 1200 {
            let scale = 1200 / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // ARCamera intrinsics mapped into the upright analysis frame's
    // normalized coordinates (mirrors CameraController.uprightIntrinsics).
    private func uprightIntrinsics(camera: ARCamera) -> simd_double3x3 {
        let bufferWidth = Double(camera.imageResolution.width)
        let bufferHeight = Double(camera.imageResolution.height)
        let focal = Double(camera.intrinsics.columns.0.x)
        let centerX = Double(camera.intrinsics.columns.2.x)
        let centerY = Double(camera.intrinsics.columns.2.y)

        let uprightWidth = min(1200, bufferHeight)
        let uprightHeight = bufferWidth * (uprightWidth / bufferHeight)
        let scale = uprightWidth / bufferHeight
        let uprightFocal = focal * scale
        let uprightCenterX = (bufferHeight - centerY) * scale
        let uprightCenterY = centerX * scale
        return simd_double3x3(rows: [
            simd_double3(uprightFocal / uprightWidth, 0, uprightCenterX / uprightWidth),
            simd_double3(0, uprightFocal / uprightHeight, uprightCenterY / uprightHeight),
            simd_double3(0, 0, 1)])
    }
}
