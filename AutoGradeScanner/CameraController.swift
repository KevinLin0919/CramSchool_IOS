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

// The live boxes are drawn as CAShapeLayers inside the preview view itself,
// and every corner goes through the preview layer's official coordinate
// conversion (layerPointConverted). That makes the overlay exact by
// construction — videoGravity cropping, rotation and safe-area layout are
// all accounted for by AVFoundation instead of hand-rolled aspect-fill math.
//
// A display link re-renders every screen frame: the quads from the last
// XFeat anchor are shifted by the camera rotation the PoseProvider has
// measured since that frame (H = K·R·K⁻¹), so the overlay tracks handheld
// motion at 60 fps instead of stepping at alignment cadence.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var live: LiveScanEngine.Update?
    var pose: PoseProvider?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var pose: PoseProvider?

        private var boxLayers: [Int: CAShapeLayer] = [:]
        private var displayLink: CADisplayLink?

        var update: LiveScanEngine.Update? {
            didSet {
                renderBoxes()
                syncDisplayLink()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            syncDisplayLink()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            renderBoxes()
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
            }
        }

        @objc private func tick() {
            renderBoxes()
        }

        // Camera motion since the anchor frame as a 2D homography over the
        // upright frame's normalized coordinates; identity-equivalent nil
        // when no pose data is available.
        private func propagationMatrix() -> simd_double3x3? {
            guard let update, update.frameTimestamp > 0,
                  let intrinsics = update.intrinsics,
                  let rotation = pose?.cameraRotation(since: update.frameTimestamp,
                                                      lookAhead: 0.02) else { return nil }
            return intrinsics * rotation * intrinsics.inverse
        }

        private func renderBoxes() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let propagation = propagationMatrix()
            var seen = Set<Int>()
            for box in update?.boxes ?? [] {
                seen.insert(box.id)
                let shape = boxLayers[box.id] ?? makeBoxLayer(id: box.id)
                let path = UIBezierPath()
                for (index, corner) in box.quad.enumerated() {
                    var point = corner
                    if let propagation {
                        let projected = propagation * simd_double3(Double(point.x), Double(point.y), 1)
                        if abs(projected.z) > 1e-9 {
                            point = CGPoint(x: projected.x / projected.z,
                                            y: projected.y / projected.z)
                        }
                    }
                    // Upright-frame normalized -> capture-device space (the
                    // unrotated sensor picture): the upright frame is the
                    // sensor image rotated 90° CW, so invert that rotation.
                    let device = CGPoint(x: point.y, y: 1 - point.x)
                    let converted = previewLayer.layerPointConverted(fromCaptureDevicePoint: device)
                    index == 0 ? path.move(to: converted) : path.addLine(to: converted)
                }
                path.close()
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
