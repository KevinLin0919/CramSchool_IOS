import CoreMotion
import QuartzCore
import simd

// Per-frame camera pose increments for overlay propagation between XFeat
// anchors (the "fast path" of the layered scan architecture). XFeat answers
// "where is the paper" a few times a second; a PoseProvider answers "how has
// the camera moved since that anchor frame" at display rate, so the overlay
// tracks motion instead of trailing it. The protocol hides the source:
// CoreMotion gyro today, ARKit world tracking as a drop-in upgrade.
protocol PoseProvider: AnyObject {
    func start()
    func stop()

    // Rotation of the camera between `since` and now (+lookAhead seconds of
    // prediction, to cover render latency), expressed in the camera frame of
    // the upright analysis image. nil when motion data doesn't bracket the
    // interval (simulator, provider stopped, anchor too old) — callers then
    // draw the un-propagated anchor overlay, which is Phase 1 behavior.
    func cameraRotation(since: TimeInterval, lookAhead: TimeInterval) -> simd_double3x3?

    // True after ~1.5 s without meaningful rotation — the "iPad on a stand"
    // case, where consumers can relax their processing cadence.
    var isStationary: Bool { get }
}

// Gyro-only implementation: compensates handheld rotation, which dominates
// close-range viewfinder motion. Integration drift never accumulates because
// every XFeat anchor resets the reference time.
final class GyroPoseProvider: PoseProvider {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, attitude: simd_quatd)] = []
    private var latestRate = simd_double3.zero
    private var lastMotionAt: TimeInterval = 0

    // Back camera axes in the device-locked portrait frame: image x = device
    // x, image y = -device y (screen y points up, image y down), camera
    // forward = -device z. Diagonal ±1, so the matrix is its own inverse.
    private static let deviceToCamera = simd_double3x3(rows: [
        simd_double3(1, 0, 0),
        simd_double3(0, -1, 0),
        simd_double3(0, 0, -1)])

    // Propagating beyond this total rotation would be extrapolation, not
    // compensation — wait for the next anchor instead.
    private static let maxAngle = 0.10   // radians, ~5.7°

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] deviceMotion, _ in
            guard let self, let deviceMotion else { return }
            let q = deviceMotion.attitude.quaternion
            self.lock.lock()
            self.samples.append((deviceMotion.timestamp,
                                 simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)))
            if self.samples.count > 300 {
                self.samples.removeFirst(self.samples.count - 300)
            }
            self.latestRate = simd_double3(deviceMotion.rotationRate.x,
                                           deviceMotion.rotationRate.y,
                                           deviceMotion.rotationRate.z)
            if simd_length(self.latestRate) > 0.03 {
                self.lastMotionAt = deviceMotion.timestamp
            }
            self.lock.unlock()
        }
    }

    var isStationary: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = samples.last else { return false }
        return last.time - lastMotionAt > 1.5
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        lock.lock()
        samples = []
        lock.unlock()
    }

    func cameraRotation(since anchorTime: TimeInterval,
                        lookAhead: TimeInterval) -> simd_double3x3? {
        lock.lock()
        let samples = self.samples
        let rate = latestRate
        lock.unlock()
        guard let first = samples.first, let last = samples.last,
              anchorTime >= first.time,
              let anchorAttitude = GyroPoseProvider.attitude(at: anchorTime, in: samples) else {
            return nil
        }

        // Predict slightly past the newest sample so boxes land where the
        // camera will be when this frame reaches the screen.
        var current = last.attitude
        let dt = max(0, CACurrentMediaTime() - last.time) + lookAhead
        let speed = simd_length(rate)
        if speed * dt > 1e-5 {
            current = current * simd_quatd(angle: speed * dt, axis: simd_normalize(rate))
        }

        let delta = simd_double3x3(current).transpose * simd_double3x3(anchorAttitude)
        let angle = acos(min(1, max(-1, ((delta.columns.0.x + delta.columns.1.y + delta.columns.2.z) - 1) / 2)))
        guard angle < GyroPoseProvider.maxAngle else { return nil }

        let m = GyroPoseProvider.deviceToCamera
        return m * delta * m
    }

    private static func attitude(
        at time: TimeInterval,
        in samples: [(time: TimeInterval, attitude: simd_quatd)]
    ) -> simd_quatd? {
        guard !samples.isEmpty else { return nil }
        // Nearest sample; 100 Hz spacing keeps the error sub-pixel.
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return samples[low].attitude
    }
}
