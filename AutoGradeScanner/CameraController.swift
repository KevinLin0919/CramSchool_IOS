import AVFoundation
import SwiftUI
import Vision

// Camera session with automatic paper detection: Vision rectangle
// detection runs on the video feed and, once a document-like rectangle
// is stable for a few frames, a still photo is captured automatically.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isAuthorized = true
    @Published var isTorchOn = false
    @Published var paperDetected = false

    var onCapture: ((UIImage) -> Void)?

    // Live-grading tap: sampled video frames as upright UIImages. While set
    // with autoCaptureEnabled = false, the scanner grades the stream in place
    // instead of waiting for a still capture.
    var onLiveFrame: ((UIImage) -> Void)?
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
        sessionQueue.async {
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
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
        // cadence is just an upper bound on conversion work.
        if let onLiveFrame, frameIndex % 3 == 0,
           let image = uprightImage(from: pixelBuffer) {
            onLiveFrame(image)
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

// MARK: - SwiftUI preview layer

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
