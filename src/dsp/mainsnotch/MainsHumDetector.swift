import Atomics
import Foundation

enum MainsRegion: String, Codable, Equatable, Sendable, CaseIterable {
    case fifty  = "50 Hz"
    case sixty  = "60 Hz"
    var nominalHz: Double { self == .fifty ? 50.0 : 60.0 }
}

final class MainsHumDetector: @unchecked Sendable {

    // MARK: - Capture (audio thread writes, main thread reads after completion)
    private static let captureSeconds: Double = 2.0
    nonisolated(unsafe) private var captureBuffer: [Float]
    private var captureLength: Int = 0
    private let _captureFramesRemaining: ManagedAtomic<Int32> = ManagedAtomic(0)
    private let _captureReady: ManagedAtomic<Bool> = ManagedAtomic(false)

    private var sampleRate: Double

    // MARK: - Frequency state (main thread only)
    /// The value the slewing mechanism is currently moving toward.
    private(set) var targetFundamentalHz: Double
    /// The value actually driving the live notch coefficients right now —
    /// moves smoothly toward targetFundamentalHz, never jumps.
    private(set) var currentFundamentalHz: Double
    private var slewPerSecond: Double = 40.0  // Hz/sec convergence rate for one-shot Detect
    private static let trackingSlewPerSecond: Double = 4.0  // much slower for continuous tracking

    // MARK: - Tracking state (main thread only)
    private(set) var isTrackingEnabled: Bool = false
    private var trackingInProgress: Bool = false
    private static let trackingIntervalSeconds: Double = 3.0
    private var trackingTimer: Timer?
    private static let trackingConfidenceThresholdDB: Float = 10.0

    /// True while a one-shot Detect (or a tracking re-measurement) capture
    /// is filling its buffer. UI-facing.
    var isCapturing: Bool { _captureFramesRemaining.load(ordering: .relaxed) > 0 }
    var captureProgress: Float {
        guard captureLength > 0 else { return 0 }
        let remaining = Int(_captureFramesRemaining.load(ordering: .relaxed))
        guard remaining > 0 else { return 0 }
        return 1.0 - Float(remaining) / Float(captureLength)
    }

    init(sampleRate: Double, region: MainsRegion) {
        self.sampleRate = sampleRate
        self.captureLength = Int(Self.captureSeconds * sampleRate)
        self.captureBuffer = [Float](repeating: 0, count: captureLength)
        self.targetFundamentalHz = region.nominalHz
        self.currentFundamentalHz = region.nominalHz
    }

    deinit { trackingTimer?.invalidate() }

    // MARK: - Main thread API

    /// Snaps both target and current frequency directly to the region's
    /// nominal value — no slew, since this is an explicit reset, not a
    /// live correction. Call when the region toggle changes or "Reset to
    /// Nominal" is pressed.
    func setNominal(_ region: MainsRegion) {
        targetFundamentalHz = region.nominalHz
        currentFundamentalHz = region.nominalHz
    }

    func updateSampleRate(_ newSampleRate: Double) {
        sampleRate = newSampleRate
        captureLength = Int(Self.captureSeconds * newSampleRate)
        captureBuffer = [Float](repeating: 0, count: captureLength)
    }

    /// Starts a one-shot Detect capture. Scans a narrow window around the
    /// current region's nominal frequency (±5 Hz) — wide enough to catch
    /// real-world drift, narrow enough to avoid locking onto a harmonic.
    func startDetect(region: MainsRegion) {
        guard !isCapturing else { return }
        _captureReady.store(false, ordering: .relaxed)
        _captureFramesRemaining.store(Int32(captureLength), ordering: .relaxed)
        pendingScanIsNarrow = false
        pendingScanCenterHz = region.nominalHz
    }

    /// Enables/disables continuous tracking. When enabling, starts the
    /// first re-measurement cycle immediately; when disabling, cancels any
    /// in-progress cycle and stops the repeat timer.
    func setTrackingEnabled(_ enabled: Bool) {
        isTrackingEnabled = enabled
        trackingTimer?.invalidate()
        trackingTimer = nil
        guard enabled else { return }
        scheduleNextTrackingCycle(immediate: true)
    }

    private var pendingScanIsNarrow = false
    private var pendingScanCenterHz: Double = 60.0

    private func scheduleNextTrackingCycle(immediate: Bool) {
        guard isTrackingEnabled else { return }
        let interval = immediate ? 0.0 : Self.trackingIntervalSeconds
        trackingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.beginTrackingCapture()
        }
    }

    private func beginTrackingCapture() {
        guard isTrackingEnabled, !isCapturing else { return }
        _captureReady.store(false, ordering: .relaxed)
        _captureFramesRemaining.store(Int32(captureLength), ordering: .relaxed)
        pendingScanIsNarrow = true
        pendingScanCenterHz = currentFundamentalHz
    }

    /// Call from a ~30 Hz main-thread timer (see MainsNotchCoordinator).
    /// Advances the frequency slew and, if a capture just completed, runs
    /// the Goertzel scan and (for Detect) applies the result immediately
    /// or (for Tracking) applies it only if confidence clears the
    /// threshold.
    func tick(deltaSeconds: Double) {
        if _captureReady.exchange(false, ordering: .relaxed) {
            runScanOnCapturedBuffer()
        }
        let rate = pendingScanIsNarrow ? Self.trackingSlewPerSecond : slewPerSecond
        let maxStep = rate * deltaSeconds
        let diff = targetFundamentalHz - currentFundamentalHz
        if abs(diff) <= maxStep {
            currentFundamentalHz = targetFundamentalHz
        } else {
            currentFundamentalHz += (diff > 0 ? maxStep : -maxStep)
        }
        if isTrackingEnabled && !isCapturing && trackingTimer == nil {
            scheduleNextTrackingCycle(immediate: false)
        }
    }

    private func runScanOnCapturedBuffer() {
        let isNarrow = pendingScanIsNarrow
        let center = pendingScanCenterHz
        let lowHz  = isNarrow ? center - 1.0 : center - 5.0
        let highHz = isNarrow ? center + 1.0 : center + 5.0
        let stepHz = isNarrow ? 0.02 : 0.05

        guard let result = GoertzelEstimator.scanForPeak(
            buffer: captureBuffer, sampleRate: sampleRate,
            lowHz: lowHz, highHz: highHz, stepHz: stepHz
        ) else { return }

        if isNarrow {
            // Tracking re-measurement: only accept if confident.
            if result.confidenceDB >= Self.trackingConfidenceThresholdDB {
                targetFundamentalHz = result.frequencyHz
            }
            // Whether accepted or not, tracking continues on its own timer.
        } else {
            // One-shot Detect: always apply — this is a deliberate user
            // action, not a background correction.
            targetFundamentalHz = result.frequencyHz
        }
    }

    // MARK: - Audio thread API

    /// Copies incoming samples into the capture buffer. Cheap, bounded,
    /// real-time safe — no analysis happens here. Call once per render
    /// callback with a mono (or single-channel) view of the input.
    @inline(__always)
    func accumulate(_ samples: UnsafePointer<Float>, count: Int) {
        let remaining = Int(_captureFramesRemaining.load(ordering: .relaxed))
        guard remaining > 0 else { return }
        let writeStart = captureLength - remaining
        let n = min(count, remaining)
        captureBuffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n { buf[writeStart + i] = samples[i] }
        }
        let newRemaining = remaining - n
        _captureFramesRemaining.store(Int32(newRemaining), ordering: .relaxed)
        if newRemaining == 0 {
            _captureReady.store(true, ordering: .relaxed)
        }
    }
}
