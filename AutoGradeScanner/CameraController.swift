import AVFoundation
import SwiftUI
import simd

// Camera session feeding the live grading loop.
//
// Sampled video frames go out as upright images with their timestamps and
// intrinsics, and the buffer itself rides along so a cell can be read at
// sensor resolution. There is no photo output and no shutter: the Vision
// rectangle pass that used to watch for a stable document and fire a still
// capture went with the path that graded those stills on a server.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    // Motion backbone for overlay propagation between XFeat anchors; runs
    // alongside the session so timestamps share the host clock.
    let pose: PoseProvider = GyroPoseProvider()

    @Published var isAuthorized = true

    // The only tap there is: sampled video frames as upright UIImages, with the
    // frame's capture timestamp (host clock) and, when the device delivers
    // them, its intrinsics mapped into the upright frame's normalized
    // coordinates. The scanner grades the stream in place; nothing here waits
    // for, or takes, a still photograph.
    var onLiveFrame: ((UIImage, TimeInterval, simd_double3x3?, CellPixelSource?) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "autograde.camera.session")
    private let videoQueue = DispatchQueue(label: "autograde.camera.video")
    private let ciContext = CIContext()

    private var configured = false
    private var currentPosition: AVCaptureDevice.Position = .back
    private var frameIndex = 0

    // Sensor -> upright rotation for the analysis path. Only ever touched on
    // videoQueue, the queue that reads it, so the preview's own copy on the
    // main thread and this one never race.
    private var captureOrientation: CaptureOrientation = .portrait

    // Pushed in by the preview view, which is the thing that actually knows
    // which window scene it is living in.
    func setOrientation(_ orientation: CaptureOrientation) {
        videoQueue.async { self.captureOrientation = orientation }
    }

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

        // The .photo preset gives the *photo* output full sensor resolution but
        // hands the video data output a preview-sized buffer, around 1080px
        // wide. An answer cell is roughly a tenth of the page, so it arrives at
        // 48-70px — and measured on real handwriting, 64px reads 3/6 while 96px
        // reads 6/6. What fails first is the printed-box filter: at that size
        // the border is one or two pixels and the connected-component analysis
        // that erases it stops being reliable.
        //
        // 4K doubles the linear resolution. Alignment is unaffected — it still
        // runs on the 1200px downscale, since XFeat resizes to 832x608 anyway —
        // and cells are cropped out of the buffer individually, so the extra
        // pixels are only paid for where they are read.
        //
        // The preset must be set after the input is attached; a device that
        // cannot do 4K keeps .photo rather than failing to configure.
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
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
}

// MARK: - Live frames

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
        let orientation = captureOrientation
        if let onLiveFrame, frameIndex % liveCadence == 0,
           let image = uprightImage(from: pixelBuffer, orientation: orientation) {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let intrinsics = uprightIntrinsics(sampleBuffer: sampleBuffer,
                                               pixelBuffer: pixelBuffer,
                                               uprightSize: image.size,
                                               orientation: orientation)
            // Alignment gets the downscaled image; recognition gets the buffer
            // itself, so it can read a cell at whatever the sensor captured
            // rather than at the 1200px XFeat is capped to. Handing the buffer
            // on retains it until the engine is done with the frame — one at a
            // time, since frames arriving during an alignment are dropped.
            let source = PixelBufferCellSource(buffer: pixelBuffer,
                                               orientation: orientation,
                                               context: ciContext)
            onLiveFrame(image, timestamp, intrinsics, source)
        }

    }

    // Camera intrinsics mapped into the upright analysis frame, expressed for
    // normalized coordinates: K maps a camera ray onto (x, y) in 0...1 of the
    // upright image. Used to turn a physical camera rotation into the 2D
    // homography that shifts the overlay (K · R · K⁻¹). Falls back to a
    // typical wide-camera focal length when delivery is unavailable.
    private func uprightIntrinsics(sampleBuffer: CMSampleBuffer,
                                   pixelBuffer: CVPixelBuffer,
                                   uprightSize: CGSize,
                                   orientation: CaptureOrientation) -> simd_double3x3? {
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

        // Sensor -> upright is the interface's rotation then a uniform
        // downscale. A quarter turn swaps which buffer axis the upright
        // width was measured along, so the scale factor follows suit.
        let bufferSize = CGSize(width: bufferWidth, height: bufferHeight)
        let uprightBufferWidth = orientation.swapsAxes ? bufferHeight : bufferWidth
        let scale = Double(uprightSize.width) / uprightBufferWidth
        let center = orientation.upright(point: CGPoint(x: centerX, y: centerY),
                                         bufferSize: bufferSize)
        let uprightFocal = focal * scale
        let uprightCenterX = Double(center.x) * scale
        let uprightCenterY = Double(center.y) * scale

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
    private func uprightImage(from pixelBuffer: CVPixelBuffer,
                              orientation: CaptureOrientation) -> UIImage? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation.cgOrientation)
        let width = image.extent.width
        if width > 1200 {
            let scale = 1200 / width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
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
// read as twitching. A CADisplayLink drives the DISPLAYED oriented rect toward
// the latest anchor's target every screen frame through a One-Euro filter, so
// alignment updates arrive smoothly instead of snapping, and small rotations
// are damped to upright. This is the "calm like the old overlay, accurate like
// the new one" path; gyro propagation is off here (it pushed boxes the wrong
// way under translation) and reserved for the ARKit backbone.
// Projective map from the unit square to a convex quad given as (tl, tr, br,
// bl) — the images of (0,0), (1,0), (1,1), (0,1). Lets the overlay take one
// smoothed sheet quad and place every box on it from its template
// coordinates, so all boxes share the sheet's perspective instead of each
// carrying an independent estimate of it.
struct UnitQuad {
    private let a, b, c, d, e, f, g, h: CGFloat

    init?(quad: [CGPoint]) {
        guard quad.count == 4 else { return nil }
        let p0 = quad[0], p1 = quad[1], p2 = quad[2], p3 = quad[3]
        let sx = p0.x - p1.x + p2.x - p3.x
        let sy = p0.y - p1.y + p2.y - p3.y
        if abs(sx) < 1e-9 && abs(sy) < 1e-9 {
            g = 0; h = 0
            a = p1.x - p0.x; b = p2.x - p1.x; c = p0.x
            d = p1.y - p0.y; e = p2.y - p1.y; f = p0.y
        } else {
            let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x
            let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > 1e-12 else { return nil }
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
            a = p1.x - p0.x + g * p1.x
            b = p3.x - p0.x + h * p3.x
            c = p0.x
            d = p1.y - p0.y + g * p1.y
            e = p3.y - p0.y + h * p3.y
            f = p0.y
        }
    }

    func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        let w = g * u + h * v + 1
        guard abs(w) > 1e-9 else { return .zero }
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }

    func corners(of rect: CGRect) -> [CGPoint] {
        [point(rect.minX, rect.minY), point(rect.maxX, rect.minY),
         point(rect.maxX, rect.maxY), point(rect.minX, rect.maxY)]
    }
}

struct CameraPreviewView: UIViewRepresentable {
    /// Settings switch: annotate wrong/unsure boxes with what the model read as
    /// well as what the answer should be.
    static let showsReadingKey = "scan.showsReading"

    let session: AVCaptureSession
    var live: LiveScanEngine.Update?
    var pose: PoseProvider?
    var showsReading = false
    var onOrientationChange: ((CaptureOrientation) -> Void)?

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        var pose: PoseProvider?   // retained for the AR path; unused here

        // An oriented rectangle in upright-frame normalized coordinates.
        private struct ORect {
            var cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, angle: CGFloat
        }

        // One-Euro filter: a low-pass whose cutoff rises with the signal's own
        // speed, so it damps hard when the value is nearly still and opens up
        // the moment it genuinely moves. Crucially it never stops moving
        // toward the target — a fixed dead-zone froze the box until the error
        // grew past the threshold and then jumped it forward in one step, and
        // that hold-then-jump staircase is what read as twitching.
        private struct OneEuro {
            private let minCutoff: CGFloat   // Hz, the resting smoothness
            private let beta: CGFloat        // how fast the cutoff opens with speed
            private let dCutoff: CGFloat     // Hz, smoothing of the speed estimate
            private var x: CGFloat
            private var dx: CGFloat = 0

            init(minCutoff: CGFloat, beta: CGFloat, dCutoff: CGFloat = 1, initial: CGFloat) {
                self.minCutoff = minCutoff
                self.beta = beta
                self.dCutoff = dCutoff
                self.x = initial
            }

            private func alpha(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
                let tau = 1 / (2 * .pi * cutoff)
                return 1 / (1 + tau / dt)
            }

            mutating func filter(_ value: CGFloat, dt: CGFloat) -> CGFloat {
                dx += alpha(cutoff: dCutoff, dt: dt) * ((value - x) / dt - dx)
                x += alpha(cutoff: minCutoff + beta * abs(dx), dt: dt) * (value - x)
                return x
            }
        }

        // Filter bank for the projected sheet's four corners. Alignment error
        // is a rigid error of the whole sheet — measured on device footage the
        // boxes move together with a coherence of 0.89, i.e. one wrong
        // homography drags the entire constellation — so this is the level the
        // smoothing belongs at. Filtering eight boxes separately smoothed the
        // symptom while letting them drift apart; from one smoothed quad they
        // stay rigid by construction.
        private struct QuadSmoother {
            private var fx: [OneEuro]
            private var fy: [OneEuro]
            private(set) var value: [CGPoint]

            init(start: [CGPoint]) {
                value = start
                fx = start.map { OneEuro(minCutoff: 0.8, beta: 12, initial: $0.x) }
                fy = start.map { OneEuro(minCutoff: 0.8, beta: 12, initial: $0.y) }
            }

            mutating func update(to target: [CGPoint], dt: CGFloat) {
                guard target.count == value.count else { return }
                for i in target.indices {
                    value[i] = CGPoint(x: fx[i].filter(target[i].x, dt: dt),
                                       y: fy[i].filter(target[i].y, dt: dt))
                }
            }

            // How far this quad sits from another, as the mean corner offset.
            func distance(to quad: [CGPoint]) -> CGFloat {
                guard quad.count == value.count, !quad.isEmpty else { return 0 }
                let total = zip(value, quad).reduce(CGFloat(0)) {
                    $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)
                }
                return total / CGFloat(quad.count)
            }
        }

        private var sheet: QuadSmoother?
        private var rejectStreak = 0
        private var boxLayers: [Int: CAShapeLayer] = [:]
        private var labelLayers: [Int: CATextLayer] = [:]
        /// Diagnostic overlay: also show what the model read, not just what the
        /// answer should be. Driven by a Settings switch rather than #if DEBUG,
        /// because the sideloaded .ipa is a Release build and DEBUG code never
        /// reaches the device.
        var showsReading = false
        private var displayLink: CADisplayLink?

        var update: LiveScanEngine.Update? {
            didSet { syncDisplayLink() }
        }

        // Sensor -> upright rotation currently in force. The overlay's inverse
        // mapping reads it here; the analysis pipeline gets its own copy via
        // onOrientationChange, so both sides of the projection always agree.
        private(set) var orientation: CaptureOrientation = .portrait
        var onOrientationChange: ((CaptureOrientation) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshOrientation()
            syncDisplayLink()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Rotating the device resizes this view, so this is also the
            // moment the interface orientation may have changed.
            refreshOrientation()
            render()
        }

        private func refreshOrientation() {
            // No window means we are being torn down, not turned.
            guard window != nil else { return }
            let next = CaptureOrientation.current(for: self)
            let connection = previewLayer.connection
            let angle = next.videoRotationAngle
            if let connection, connection.isVideoRotationAngleSupported(angle),
               connection.videoRotationAngle != angle {
                connection.videoRotationAngle = angle
            }
            guard next != orientation else { return }
            orientation = next
            // Anchors captured before the turn describe the old frame, so drop
            // them rather than briefly drawing boxes through the wrong map.
            sheet = nil
            onOrientationChange?(next)
        }

        private func syncDisplayLink() {
            let wanted = window != nil && !(update?.boxes.isEmpty ?? true)
            if wanted && displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                displayLink = link
            } else if !wanted, let link = displayLink {
                link.invalidate()
                displayLink = nil
                sheet = nil
                rejectStreak = 0
                boxLayers.values.forEach { $0.removeFromSuperlayer() }
                boxLayers = [:]
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            // Real frame duration, so the filters behave identically at 60 and
            // 120 Hz. Clamped in case a stalled frame reports a huge interval.
            let dt = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 20)
            step(dt: CGFloat(dt))
            render()
        }

        // Drive each displayed oriented rect toward its anchor target through
        // the One-Euro bank. Successive XFeat anchors jitter the target ~1% of
        // the frame even when the sheet is still (RANSAC sampling + feature
        // noise); the filter damps that at rest yet keeps closing on the target
        // every frame, so a slowly drifting sheet is followed continuously
        // instead of being held and snapped. Anchors arrive at ~15 Hz while
        // this runs at display rate, which is exactly the gap that a held
        // target would otherwise turn into visible steps.
        private func step(dt: CGFloat) {
            guard let target = update?.sheetQuad, target.count == 4 else {
                sheet = nil
                return
            }
            guard var current = sheet else {
                sheet = QuadSmoother(start: target)   // appear in place
                rejectStreak = 0
                return
            }

            // Outlier anchors: a single bad RANSAC solution throws the whole
            // sheet sideways and, being a fresh independent fit, the next one
            // need not repeat the error. Smoothing cannot undo a target that
            // is itself wrong, so an implausible jump is skipped outright —
            // but only briefly, since genuine fast motion keeps producing
            // large offsets and must not be locked out.
            if current.distance(to: target) > 0.045, rejectStreak < 3 {
                rejectStreak += 1
                return
            }
            rejectStreak = 0
            current.update(to: target, dt: dt)
            sheet = current
        }

        // Every box re-derived from the one smoothed sheet quad, so they can
        // never drift relative to one another.
        private func displayedRects() -> [(id: Int, rect: ORect, box: LiveScanEngine.Box)] {
            guard let quad = sheet?.value,
                  let map = UnitQuad(quad: quad) else { return [] }
            return (update?.boxes ?? []).map { box in
                (box.id, Self.orientedRect(from: map.corners(of: box.templateRect)), box)
            }
        }

        // Pull a nearly straight sheet the rest of the way to upright. Applied
        // to the target rather than the filter output, so it biases the input
        // instead of fighting the filter's own state.
        private static func uprighted(_ angle: CGFloat) -> CGFloat {
            abs(angle) < 0.10 ? angle * 0.35 : angle   // ~5.7° → reads upright
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

            var seen = Set<Int>()
            for (id, rect, box) in displayedRects() {
                seen.insert(id)
                let shape = boxLayers[id] ?? makeBoxLayer(id: id)
                let path = roundedPath(for: rect)
                shape.path = path
                let color = Self.color(for: box.verdict)
                shape.strokeColor = color.cgColor
                shape.fillColor = color.withAlphaComponent(box.verdict == nil ? 0.05 : 0.15).cgColor
                updateLabel(id: id, box: box, boxPath: path, color: color)
            }
            for (id, stale) in boxLayers where !seen.contains(id) {
                stale.removeFromSuperlayer()
                boxLayers[id] = nil
                labelLayers[id]?.removeFromSuperlayer()
                labelLayers[id] = nil
            }
            CATransaction.commit()
        }

        private static func color(for verdict: LiveScanEngine.Verdict?) -> UIColor {
            switch verdict {
            case .correct: return UIColor(AG.ok)
            case .wrong:   return UIColor(AG.bad)
            case .unsure:  return UIColor(AG.warn)
            case nil:      return .white
            }
        }

        /// The expected answer, pinned just outside the box's top-left corner.
        ///
        /// Only wrong and unsure boxes get one. A green box would be labelled
        /// with the answer the teacher already knows is there, so the label
        /// would be pure noise — and leaving greens bare is what makes the
        /// annotated cells the ones your eye goes to.
        private func updateLabel(id: Int, box: LiveScanEngine.Box,
                                 boxPath: CGPath, color: UIColor) {
            let expected = box.expectedText.trimmingCharacters(in: .whitespaces)
            guard box.verdict == .wrong || box.verdict == .unsure, !expected.isEmpty else {
                labelLayers[id]?.removeFromSuperlayer()
                labelLayers[id] = nil
                return
            }

            var text = expected
            if showsReading, let read = box.readText, !read.isEmpty, read != expected {
                // Diagnostic mode: a red box alone cannot tell you whether the
                // student was wrong or the model was. This can.
                text = "\(read)→\(expected)"
            }

            let label = labelLayers[id] ?? makeLabelLayer(id: id)
            label.string = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .bold),
                .foregroundColor: UIColor.white,
            ])
            let size = label.preferredFrameSize()
            let padded = CGSize(width: size.width + 10, height: size.height + 4)
            let corner = boxPath.boundingBox.origin
            label.frame = CGRect(x: corner.x, y: corner.y - padded.height - 3,
                                 width: padded.width, height: padded.height)
            label.backgroundColor = color.withAlphaComponent(0.92).cgColor
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
                // Upright-frame normalized -> capture-device space, undoing
                // whichever rotation produced the upright frame.
                return previewLayer.layerPointConverted(
                    fromCaptureDevicePoint: orientation.devicePoint(
                        fromUpright: CGPoint(x: nx, y: ny)))
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

        private func makeLabelLayer(id: Int) -> CATextLayer {
            let text = CATextLayer()
            text.contentsScale = UIScreen.main.scale
            text.alignmentMode = .center
            text.cornerRadius = 5
            text.masksToBounds = true
            // Labels ride above every box so a neighbouring box cannot cover one.
            layer.addSublayer(text)
            labelLayers[id] = text
            return text
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.pose = pose
        view.onOrientationChange = onOrientationChange
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.pose = pose
        uiView.onOrientationChange = onOrientationChange
        uiView.showsReading = showsReading
        uiView.update = live
    }
}
