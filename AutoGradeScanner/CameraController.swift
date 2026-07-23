import AVFoundation
import SwiftUI
import Vision
import simd

// Camera session with automatic paper detection: Vision rectangle
// detection runs on the video feed and, once a document-like rectangle
// is stable for a few frames, a still photo is captured automatically.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    // Motion backbone for overlay propagation between XFeat anchors; runs
    // alongside the session so timestamps share the host clock.
    let pose: PoseProvider = GyroPoseProvider()

    @Published var isAuthorized = true
    @Published var isTorchOn = false
    @Published var paperDetected = false

    var onCapture: ((UIImage) -> Void)?

    // Live-grading tap: sampled video frames as upright UIImages, with the
    // frame's capture timestamp (host clock) and, when the device delivers
    // them, its intrinsics mapped into the upright frame's normalized
    // coordinates. While set with autoCaptureEnabled = false, the scanner
    // grades the stream in place instead of waiting for a still capture.
    var onLiveFrame: ((UIImage, TimeInterval, simd_double3x3?) -> Void)?
    var autoCaptureEnabled = true

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "autograde.camera.session")
    private let videoQueue = DispatchQueue(label: "autograde.camera.video")
    private let ciContext = CIContext()

    private var configured = false
    private var currentPosition: AVCaptureDevice.Position = .back
    private var frameIndex = 0
    private var stableCount = 0
    private var hasCaptured = false

    // MARK: - Lifecycle

    func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isAuthorized = true }
            start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { self.isAuthorized = granted }
                if granted { self.start() }
            }
        default:
            DispatchQueue.main.async { self.isAuthorized = false }
        }
    }

    func start() {
        pose.start()
        sessionQueue.async {
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        pose.stop()
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    func resetDetection() {
        videoQueue.async {
            self.stableCount = 0
            self.hasCaptured = false
        }
        DispatchQueue.main.async { self.paperDetected = false }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .photo

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if let connection = videoOutput.connection(with: .video),
           connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        session.commitConfiguration()
    }

    // MARK: - Controls

    func capturePhoto() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func toggleTorch() {
        sessionQueue.async {
            guard let device = (self.session.inputs.first as? AVCaptureDeviceInput)?.device,
                  device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                let turnOn = device.torchMode != .on
                device.torchMode = turnOn ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isTorchOn = turnOn }
            } catch {}
        }
    }

    func flipCamera() {
        sessionQueue.async {
            self.session.beginConfiguration()
            if let input = self.session.inputs.first as? AVCaptureDeviceInput {
                self.session.removeInput(input)
            }
            self.currentPosition = self.currentPosition == .back ? .front : .back
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.currentPosition),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
        }
        resetDetection()
    }
}

// MARK: - Rectangle detection on video frames

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        frameIndex += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Live-grading tap. The consumer drops frames while busy, so this
        // cadence is just an upper bound on conversion work. On a stand
        // (stationary device) the paper only moves when slid by hand, so
        // half the alignment cadence saves battery with no visible cost.
        let liveCadence = pose.isStationary ? 6 : 3
        if let onLiveFrame, frameIndex % liveCadence == 0,
           let image = uprightImage(from: pixelBuffer) {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let intrinsics = uprightIntrinsics(sampleBuffer: sampleBuffer,
                                               pixelBuffer: pixelBuffer,
                                               uprightSize: image.size)
            onLiveFrame(image, timestamp, intrinsics)
        }

        guard autoCaptureEnabled, !hasCaptured, frameIndex % 6 == 0 else { return }

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.3
        request.minimumConfidence = 0.7
        request.maximumObservations = 1

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])
        try? handler.perform([request])

        let found = !(request.results ?? []).isEmpty
        stableCount = found ? stableCount + 1 : max(0, stableCount - 1)

        let locked = stableCount >= 3
        if locked != paperDetected {
            DispatchQueue.main.async { self.paperDetected = locked }
        }
        if locked && !hasCaptured {
            hasCaptured = true
            capturePhoto()
        }
    }

    // Camera intrinsics mapped into the upright analysis frame, expressed for
    // normalized coordinates: K maps a camera ray onto (x, y) in 0...1 of the
    // upright image. Used to turn a physical camera rotation into the 2D
    // homography that shifts the overlay (K · R · K⁻¹). Falls back to a
    // typical wide-camera focal length when delivery is unavailable.
    private func uprightIntrinsics(sampleBuffer: CMSampleBuffer,
                                   pixelBuffer: CVPixelBuffer,
                                   uprightSize: CGSize) -> simd_double3x3? {
        let bufferWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let bufferHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        guard bufferWidth > 0, bufferHeight > 0,
              uprightSize.width > 0, uprightSize.height > 0 else { return nil }

        // Sensor-space intrinsics (pixel units of the delivered buffer).
        var focal: Double
        var centerX: Double
        var centerY: Double
        if let data = CMGetAttachment(sampleBuffer,
                                      key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            let k = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            focal = Double(k.columns.0.x)
            centerX = Double(k.columns.2.x)
            centerY = Double(k.columns.2.y)
        } else {
            // ~69° horizontal FOV of the standard wide camera.
            focal = 0.73 * bufferWidth
            centerX = bufferWidth / 2
            centerY = bufferHeight / 2
        }

        // Sensor -> upright is a 90° CW rotation then a uniform downscale.
        let scale = Double(uprightSize.width) / bufferHeight
        let uprightFocal = focal * scale
        let uprightCenterX = (bufferHeight - centerY) * scale
        let uprightCenterY = centerX * scale

        let width = Double(uprightSize.width)
        let height = Double(uprightSize.height)
        return simd_double3x3(rows: [
            simd_double3(uprightFocal / width, 0, uprightCenterX / width),
            simd_double3(0, uprightFocal / height, uprightCenterY / height),
            simd_double3(0, 0, 1)])
    }

    // Camera frames arrive in sensor (landscape) orientation; rotate upright
    // and downscale — XFeat shrinks to its model input anyway, and smaller
    // frames keep the per-frame conversion cheap.
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
}

// MARK: - Photo capture

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            resetDetection()
            return
        }
        DispatchQueue.main.async { self.onCapture?(image) }
    }
}

// MARK: - SwiftUI preview layer + live verdict boxes

// Live boxes are drawn as CAShapeLayers inside the preview view, and every
// corner goes through the preview layer's official coordinate conversion
// (layerPointConverted) — videoGravity cropping, rotation and safe-area
// layout are exact by construction, not hand-rolled aspect-fill math.
//
// Each answer box is reduced to an oriented rounded rectangle (center, size,
// angle) — the projected quad's perspective shear is dropped, since at answer-
// box scale that shear is mostly estimation noise and rendering it verbatim
// read as twitching. A CADisplayLink glides the DISPLAYED oriented rect toward
// the latest anchor's target every screen frame (a ~150 ms time constant), so
// alignment updates arrive smoothly instead of snapping, and small rotations
// are damped to upright. This is the "calm like the old overlay, accurate like
// the new one" path; gyro propagation is off here (it pushed boxes the wrong
// way under translation) and reserved for the ARKit backbone.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var live: LiveScanEngine.Update?
    var pose: PoseProvider?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var pose: PoseProvider?   // retained for the AR path; unused here

        // An oriented rectangle in upright-frame normalized coordinates.
        private struct ORect {
            var cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, angle: CGFloat
        }

        private var displayed: [Int: ORect] = [:]   // smoothed, glides toward target
        private var boxLayers: [Int: CAShapeLayer] = [:]
        private var displayLink: CADisplayLink?

        var update: LiveScanEngine.Update? {
            didSet { syncDisplayLink() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            syncDisplayLink()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            render()
        }

        private func syncDisplayLink() {
            let wanted = window != nil && !(update?.boxes.isEmpty ?? true)
            if wanted && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !wanted, let link = displayLink {
                link.invalidate()
                displayLink = nil
                displayed = [:]
                boxLayers.values.forEach { $0.removeFromSuperlayer() }
                boxLayers = [:]
            }
        }

        @objc private func tick() {
            step()
            render()
        }

        // Ease each displayed oriented rect toward its anchor target. Position
        // and size use one rate; angle a slower one with a dead-zone, so a
        // near-straight sheet settles upright and only a clear tilt rotates.
        private func step() {
            let boxes = update?.boxes ?? []
            var live = Set<Int>()
            let kPose: CGFloat = 0.22
            let kAngle: CGFloat = 0.12
            for box in boxes {
                live.insert(box.id)
                let target = Self.orientedRect(from: box.quad)
                guard var cur = displayed[box.id] else {
                    displayed[box.id] = target   // appear in place, no glide-in
                    continue
                }
                cur.cx += (target.cx - cur.cx) * kPose
                cur.cy += (target.cy - cur.cy) * kPose
                cur.w  += (target.w  - cur.w)  * kPose
                cur.h  += (target.h  - cur.h)  * kPose
                // Rectangles look identical every 180°, so bring the angle
                // delta into (-π/2, π/2] before easing.
                var da = target.angle - cur.angle
                while da >  .pi / 2 { da -= .pi }
                while da <= -.pi / 2 { da += .pi }
                cur.angle += da * kAngle
                if abs(cur.angle) < 0.07 { cur.angle *= 0.6 }   // ~4° dead-zone → upright
                displayed[box.id] = cur
            }
            displayed = displayed.filter { live.contains($0.key) }
        }

        // Best-fit oriented rectangle of a projected quad (tl, tr, br, bl),
        // discarding perspective shear.
        private static func orientedRect(from quad: [CGPoint]) -> ORect {
            guard quad.count == 4 else { return ORect(cx: 0.5, cy: 0.5, w: 0, h: 0, angle: 0) }
            let tl = quad[0], tr = quad[1], br = quad[2], bl = quad[3]
            let cx = (tl.x + tr.x + br.x + bl.x) / 4
            let cy = (tl.y + tr.y + br.y + bl.y) / 4
            let topLen = hypot(tr.x - tl.x, tr.y - tl.y)
            let botLen = hypot(br.x - bl.x, br.y - bl.y)
            let leftLen = hypot(bl.x - tl.x, bl.y - tl.y)
            let rightLen = hypot(br.x - tr.x, br.y - tr.y)
            let topAngle = atan2(tr.y - tl.y, tr.x - tl.x)
            let botAngle = atan2(br.y - bl.y, br.x - bl.x)
            return ORect(cx: cx, cy: cy,
                         w: (topLen + botLen) / 2,
                         h: (leftLen + rightLen) / 2,
                         angle: (topAngle + botAngle) / 2)
        }

        private func render() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let verdicts = Dictionary(uniqueKeysWithValues:
                (update?.boxes ?? []).map { ($0.id, $0.verdict) })
            var seen = Set<Int>()
            for (id, rect) in displayed {
                seen.insert(id)
                let shape = boxLayers[id] ?? makeBoxLayer(id: id)
                shape.path = roundedPath(for: rect)
                let verdict = verdicts[id] ?? nil
                let color: UIColor = verdict.map { $0 ? UIColor(AG.ok) : UIColor(AG.bad) } ?? .white
                shape.strokeColor = color.cgColor
                shape.fillColor = color.withAlphaComponent(verdict == nil ? 0.05 : 0.15).cgColor
            }
            for (id, stale) in boxLayers where !seen.contains(id) {
                stale.removeFromSuperlayer()
                boxLayers[id] = nil
            }
            CATransaction.commit()
        }

        // Map the oriented rect's corners into the preview layer, then draw a
        // rounded rectangle through them. layerPointConverted for a uniform
        // aspect-fill scale keeps the mapped corners a true rectangle.
        private func roundedPath(for rect: ORect) -> CGPath {
            let ux = CGPoint(x: cos(rect.angle), y: sin(rect.angle))
            let uy = CGPoint(x: -sin(rect.angle), y: cos(rect.angle))
            func corner(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
                let nx = rect.cx + sx * rect.w / 2 * ux.x + sy * rect.h / 2 * uy.x
                let ny = rect.cy + sx * rect.w / 2 * ux.y + sy * rect.h / 2 * uy.y
                // Upright-frame normalized -> capture-device space (upright is
                // the sensor image rotated 90° CW, so invert that rotation).
                return previewLayer.layerPointConverted(
                    fromCaptureDevicePoint: CGPoint(x: ny, y: 1 - nx))
            }
            let p0 = corner(-1, -1), p1 = corner(1, -1), p2 = corner(1, 1)
            let wLayer = hypot(p1.x - p0.x, p1.y - p0.y)
            let hLayer = hypot(p2.x - p1.x, p2.y - p1.y)
            let center = CGPoint(x: (p0.x + p2.x) / 2, y: (p0.y + p2.y) / 2)
            let angleLayer = atan2(p1.y - p0.y, p1.x - p0.x)
            let radius = min(wLayer, hLayer) * 0.22
            let local = CGRect(x: -wLayer / 2, y: -hLayer / 2, width: wLayer, height: hLayer)
            let path = UIBezierPath(roundedRect: local, cornerRadius: radius)
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angleLayer)
            return path.cgPath.copy(using: &transform) ?? path.cgPath
        }

        private func makeBoxLayer(id: Int) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.lineWidth = 3
            shape.lineJoin = .round
            layer.addSublayer(shape)
            boxLayers[id] = shape
            return shape
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.pose = pose
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.pose = pose
        uiView.update = live
    }
}
