import AppKit
import Combine
import Foundation
import os.log

// MARK: - Per-Output Channel Meter Data (Part 2 Task AG)

struct OutputChannelMeterData: Sendable {
    var preLimiterPeakDB: Float     // Pre-limiter peak, dBFS
    var postLimiterPeakDB: Float    // Post-limiter peak, dBFS
    var excursionGainReductionDB: Float   // Excursion limiter GR (≤ 0 dB)
    var brickwallGainReductionDB: Float   // Brickwall limiter GR (≤ 0 dB)
    var isClipping: Bool            // True when preLimiterPeakDB > –0.5 dBFS
}

/// Manages meter state and updates observers directly.
/// Uses Timer for meter updates at 30 FPS.
/// Updates are pushed directly to observers, bypassing SwiftUI's observation system.
@MainActor
final class MeterStore: ObservableObject {
    // MARK: - Observable Properties (for UI controls only)

    /// Whether meters are enabled. Published for UI toggle synchronization only.
    @Published var metersEnabled: Bool = true {
        didSet {
            if !metersEnabled {
                // Reset all observers to silent state
                notifyAllObserversSilent()
                stopMeterUpdates()
            } else {
                startMeterUpdates()
            }
        }
    }

    /// Per-visualization enable/disable flags
    @Published var rtaEnabled: Bool = true
    @Published var remainingMetersEnabled: Bool = true
    @Published var levelMetersEnabled: Bool = true
    @Published var vuMetersEnabled: Bool = true
    @Published var vuMeterSource: VUSource = .output

    // MARK: - Per-Output Channel Metering (Part 2 Task AG)

    /// Per-output channel level data (polled at MeterStore's standard 30 Hz rate)
    @Published var outputChannelLevels: [Int: OutputChannelMeterData] = [:]

    // MARK: - Observer Management
    
    private var observers: [MeterType: [WeakMeterObserver]] = [:]
    private let observerQueue = DispatchQueue(label: "net.knage.equaliser.meterObservers", qos: .userInteractive)
    
    // MARK: - Dependencies
    
    private weak var renderPipeline: RenderPipeline?
    private var visibleMeterWindowIDs: Set<String> = []
    
    // MARK: - Test Support
    
    var visibleMeterWindowIDsForTesting: Set<String> {
        visibleMeterWindowIDs
    }
    
    // MARK: - Timing
    
    private var meterTimer: AnyCancellable?
    private static let meterInterval: TimeInterval = MeterConstants.meterInterval
    
    // MARK: - State
    
    private var metersAtRest = false
    private var lastMeterValues: [MeterType: MeterValues] = [:]
    private let logger = Logger(subsystem: "net.knage.equaliser", category: "MeterStore")
    
    // MARK: - Value Storage

    private struct MeterValues {
        var peak: Float = 0
        var peakHold: Float = 0
        var peakHoldTimeRemaining: TimeInterval = 0
        var clipHold: TimeInterval = 0
        var rms: Float = 0
    }

    private struct VUValues {
        var vu: Float = 0
        var clipHold: TimeInterval = 0
    }

    private var lastVUValues: [MeterType: VUValues] = [:]
    
    // MARK: - Initialization

    init(metersEnabled: Bool = true,
         rtaEnabled: Bool = true,
         remainingMetersEnabled: Bool = true,
         levelMetersEnabled: Bool = true,
         vuMetersEnabled: Bool = true,
         vuMeterSource: VUSource = .output) {
        self.metersEnabled = metersEnabled
        self.rtaEnabled = rtaEnabled
        self.remainingMetersEnabled = remainingMetersEnabled
        self.levelMetersEnabled = levelMetersEnabled
        self.vuMetersEnabled = vuMetersEnabled
        self.vuMeterSource = vuMeterSource
    }
    
    // MARK: - Observer Registration
    
    func addObserver(_ observer: MeterObserver, for type: MeterType) {
        observerQueue.sync {
            if observers[type] == nil {
                observers[type] = []
            }
            // Remove dead observers and check if already registered
            observers[type]?.removeAll { $0.observer == nil || $0.observer === observer }
            observers[type]?.append(WeakMeterObserver(observer: observer))
        }
        
        // Send initial silent state if meters disabled
        if !metersEnabled {
            observer.meterUpdated(value: 0, hold: 0, clipping: false)
        }
    }
    
    func removeObserver(_ observer: MeterObserver, for type: MeterType) {
        observerQueue.sync {
            observers[type]?.removeAll { $0.observer == nil || $0.observer === observer }
        }
    }
    
    func removeAllObservers(for observer: MeterObserver) {
        observerQueue.sync {
            for type in MeterType.allCases {
                observers[type]?.removeAll { $0.observer == nil || $0.observer === observer }
            }
        }
    }
    
    // MARK: - Lifecycle
    
    func setRenderPipeline(_ pipeline: RenderPipeline?) {
        self.renderPipeline = pipeline
        // Propagate initial meters enabled state to the pipeline
        pipeline?.setMetersEnabled(metersEnabled)
    }
    
    func meterWindowBecameVisible(id: String) {
        visibleMeterWindowIDs.insert(id)
        guard metersEnabled else { return }
        startMeterUpdates()
    }

    func meterWindowBecameHidden(id: String) {
        visibleMeterWindowIDs.remove(id)
        if visibleMeterWindowIDs.isEmpty {
            stopMeterUpdates()
        }
    }
    
    func startMeterUpdates() {
        guard meterTimer == nil else { return }
        guard metersEnabled else { return }

        meterTimer = Timer.publish(every: Self.meterInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshMeterSnapshot()
            }

        // Enable audio thread meter calculations
        renderPipeline?.setMetersEnabled(true)
    }

    func stopMeterUpdates() {
        meterTimer?.cancel()
        meterTimer = nil
        metersAtRest = false
        notifyAllObserversSilent()

        // Disable audio thread meter calculations
        renderPipeline?.setMetersEnabled(false)
    }
    
    // MARK: - Update Cycle

    func refreshMeterSnapshot() {
        guard metersEnabled else {
            notifyAllObserversSilent()
            return
        }

        guard let pipeline = renderPipeline else { return }

        pipeline.decayEQPeakMeters()

        let snapshot = pipeline.currentMeters()

        // Check if at rest (all meters silent)
        if metersAtRest {
            let stillSilent = snapshot.inputDB.allSatisfy({ $0 <= MeterConstants.silenceThreshold }) &&
                              snapshot.outputDB.allSatisfy({ $0 <= MeterConstants.silenceThreshold }) &&
                              snapshot.inputRmsDB.allSatisfy({ $0 <= MeterConstants.silenceThreshold }) &&
                              snapshot.outputRmsDB.allSatisfy({ $0 <= MeterConstants.silenceThreshold })

            if stillSilent {
                return
            }
            metersAtRest = false
        }

        // Batch all meter updates in a single CATransaction to reduce render server calls
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Process each meter type (shared by Level Meters and Analytics)
        if levelMetersEnabled || remainingMetersEnabled {
            let interval = MeterConstants.meterInterval

            // Input Peak - Left
            updateMeter(
                type: .inputPeakLeft,
                dbValue: snapshot.inputDB.indices.contains(0) ? snapshot.inputDB[0] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Input Peak - Right
            updateMeter(
                type: .inputPeakRight,
                dbValue: snapshot.inputDB.indices.contains(1) ? snapshot.inputDB[1] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Output Peak - Left
            updateMeter(
                type: .outputPeakLeft,
                dbValue: snapshot.outputDB.indices.contains(0) ? snapshot.outputDB[0] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Output Peak - Right
            updateMeter(
                type: .outputPeakRight,
                dbValue: snapshot.outputDB.indices.contains(1) ? snapshot.outputDB[1] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Input RMS - Left
            updateRMSMeter(
                type: .inputRMSLeft,
                dbValue: snapshot.inputRmsDB.indices.contains(0) ? snapshot.inputRmsDB[0] : MeterConstants.meterRange.lowerBound
            )

            // Input RMS - Right
            updateRMSMeter(
                type: .inputRMSRight,
                dbValue: snapshot.inputRmsDB.indices.contains(1) ? snapshot.inputRmsDB[1] : MeterConstants.meterRange.lowerBound
            )

            // Output RMS - Left
            updateRMSMeter(
                type: .outputRMSLeft,
                dbValue: snapshot.outputRmsDB.indices.contains(0) ? snapshot.outputRmsDB[0] : MeterConstants.meterRange.lowerBound
            )

            // Output RMS - Right
            updateRMSMeter(
                type: .outputRMSRight,
                dbValue: snapshot.outputRmsDB.indices.contains(1) ? snapshot.outputRmsDB[1] : MeterConstants.meterRange.lowerBound
            )
        }

        // VU meters - both input and output computed continuously
        if vuMetersEnabled {
            let interval = MeterConstants.meterInterval

            // Input VU - Left
            updateVUMeter(
                type: .inputVULeft,
                dbValue: snapshot.inputDB.indices.contains(0) ? snapshot.inputDB[0] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Input VU - Right
            updateVUMeter(
                type: .inputVURight,
                dbValue: snapshot.inputDB.indices.contains(1) ? snapshot.inputDB[1] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Output VU - Left
            updateVUMeter(
                type: .outputVULeft,
                dbValue: snapshot.outputDB.indices.contains(0) ? snapshot.outputDB[0] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )

            // Output VU - Right
            updateVUMeter(
                type: .outputVURight,
                dbValue: snapshot.outputDB.indices.contains(1) ? snapshot.outputDB[1] : MeterConstants.meterRange.lowerBound,
                interval: interval
            )
        }

        // MARK: - Per-Output Channel Metering (Part 2 Task AG)
        let outputChannelMeters = pipeline.currentOutputChannelMeters()
        outputChannelLevels = outputChannelMeters

        // Check if we should go back to rest
        let inputPeakLeft = lastMeterValues[.inputPeakLeft]?.peak ?? Float(0)
        let inputPeakRight = lastMeterValues[.inputPeakRight]?.peak ?? Float(0)
        let outputPeakLeft = lastMeterValues[.outputPeakLeft]?.peak ?? Float(0)
        let outputPeakRight = lastMeterValues[.outputPeakRight]?.peak ?? Float(0)
        let inputRMSLeft = lastMeterValues[.inputRMSLeft]?.rms ?? Float(0)
        let inputRMSRight = lastMeterValues[.inputRMSRight]?.rms ?? Float(0)
        let outputRMSLeft = lastMeterValues[.outputRMSLeft]?.rms ?? Float(0)
        let outputRMSRight = lastMeterValues[.outputRMSRight]?.rms ?? Float(0)

        let inputVULeft = lastVUValues[.inputVULeft]?.vu ?? Float(0)
        let inputVURight = lastVUValues[.inputVURight]?.vu ?? Float(0)
        let outputVULeft = lastVUValues[.outputVULeft]?.vu ?? Float(0)
        let outputVURight = lastVUValues[.outputVURight]?.vu ?? Float(0)

        let allValues: [Float] = [
            inputPeakLeft, inputPeakRight, outputPeakLeft, outputPeakRight,
            inputRMSLeft, inputRMSRight, outputRMSLeft, outputRMSRight,
            inputVULeft, inputVURight, outputVULeft, outputVURight
        ]

        let inputHoldLeft = lastMeterValues[.inputPeakLeft]?.peakHold ?? Float(0)
        let inputHoldRight = lastMeterValues[.inputPeakRight]?.peakHold ?? Float(0)
        let outputHoldLeft = lastMeterValues[.outputPeakLeft]?.peakHold ?? Float(0)
        let outputHoldRight = lastMeterValues[.outputPeakRight]?.peakHold ?? Float(0)

        let allHolds: [Float] = [inputHoldLeft, inputHoldRight, outputHoldLeft, outputHoldRight]

        let allValuesSilent = allValues.allSatisfy({ $0 < MeterConstants.atRestThreshold })
        let allHoldsSilent = allHolds.allSatisfy({ $0 < MeterConstants.atRestThreshold })
        metersAtRest = allValuesSilent && allHoldsSilent

        CATransaction.commit()
    }
    
    private func updateMeter(type: MeterType, dbValue: Float, interval: TimeInterval) {
        var values = lastMeterValues[type] ?? MeterValues()
        
        let normalized = MeterConstants.normalizedPosition(for: dbValue)
        let delta = normalized - values.peak
        let smoothing = delta >= 0 ? MeterConstants.peakAttackSmoothing : MeterConstants.peakReleaseSmoothing
        let rawPeak = values.peak + delta * smoothing
        let peak = max(0, min(1, rawPeak))
        
        let isClipping = dbValue >= 0
        let actualPeakForHold = isClipping ? normalized : peak
        let isNewPeak = actualPeakForHold > values.peakHold
        
        let newHoldTime: TimeInterval
        let peakHold: Float
        if isNewPeak {
            newHoldTime = MeterConstants.peakHoldDuration
            peakHold = actualPeakForHold
        } else if values.peakHoldTimeRemaining > 0 {
            newHoldTime = max(0, values.peakHoldTimeRemaining - interval)
            peakHold = values.peakHold
        } else {
            newHoldTime = 0
            let rawPeakHold = values.peakHold - MeterConstants.peakHoldDecayPerTick
            peakHold = max(0, min(1, rawPeakHold))
        }
        
        let clipHold = isClipping ? MeterConstants.clipHoldDuration : max(0, values.clipHold - interval)
        
        values.peak = peak
        values.peakHold = peakHold
        values.peakHoldTimeRemaining = newHoldTime
        values.clipHold = clipHold
        
        // Notify observers BEFORE storing new values so comparison uses old values
        notifyObservers(
            type: type,
            value: peak,
            hold: peakHold,
            clipping: clipHold > 0
        )
        
        lastMeterValues[type] = values
    }
    
    private func updateRMSMeter(type: MeterType, dbValue: Float) {
        var values = lastMeterValues[type] ?? MeterValues()

        let normalized = MeterConstants.normalizedPosition(for: dbValue)
        let delta = normalized - values.rms
        let rawRMS = values.rms + delta * MeterConstants.rmsSmoothing
        let rms = max(0, min(1, rawRMS))

        values.rms = rms

        // Notify observers BEFORE storing new values so comparison uses old values
        notifyObservers(type: type, value: rms, hold: 0, clipping: false)

        lastMeterValues[type] = values
    }

    func updateVUMeter(type: MeterType, dbValue: Float, interval: TimeInterval) {
        var values = lastVUValues[type] ?? VUValues()
        let target = MeterConstants.normalizedPosition(for: dbValue)
        values.vu += (target - values.vu) * MeterConstants.vuSmoothing

        let isClipping = dbValue >= 0
        values.clipHold = isClipping ? MeterConstants.clipHoldDuration : max(0, values.clipHold - interval)

        notifyObservers(type: type, value: max(0, min(1, values.vu)), hold: 0, clipping: values.clipHold > 0)
        lastVUValues[type] = values
    }
    
    private func notifyObservers(type: MeterType, value: Float, hold: Float, clipping: Bool) {
        // Check if value changed enough to notify
        if let last = lastMeterValues[type] {
            let lastTotal = last.peak + last.peakHold
            let newTotal = value + hold
            if abs(newTotal - lastTotal) < MeterConstants.changeThreshold && !clipping {
                return
            }
        }
        
        observerQueue.sync {
            guard let typeObservers = observers[type] else { return }
            
            for wrapper in typeObservers {
                wrapper.observer?.meterUpdated(value: value, hold: hold, clipping: clipping)
            }
        }
    }

    private func notifyAllObserversSilent() {
        observerQueue.sync {
            for type in MeterType.allCases {
                guard let typeObservers = observers[type] else { continue }
                for wrapper in typeObservers {
                    wrapper.observer?.meterUpdated(value: 0, hold: 0, clipping: false)
                }
            }
        }
        
        // Reset stored values
        lastMeterValues.removeAll()
    }
}
