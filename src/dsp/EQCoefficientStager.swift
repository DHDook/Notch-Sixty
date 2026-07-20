// EQCoefficientStager.swift
// Stages EQ coefficient updates from configuration to render pipeline

import OSLog

/// Stages EQ coefficient updates from `EQConfiguration` to `RenderPipeline`.
/// Separates the DSP concern of coefficient calculation from routing orchestration.
@MainActor
final class EQCoefficientStager {

    // MARK: - Dependencies

    private let eqConfiguration: EQConfiguration
    private weak var renderPipeline: RenderPipeline?

    // MARK: - Headroom Recomputation Hook
    //
    // Called after every band update (incremental or full) so the headroom
    // compensator stays in sync with the current EQ state.
    // EqualiserStore sets this closure to call recomputeStaticPreamp().
    var onBandCoefficientsStaged: (() -> Void)?

    // MARK: - State

    /// Current sample rate for coefficient calculations.
    /// Updated when pipeline starts or sample rate changes.
    private var currentSampleRate: Double = 48000.0

    private let logger = Logger(subsystem: "net.knage.equaliser", category: "EQCoefficientStager")

    // MARK: - Initialization

    init(eqConfiguration: EQConfiguration) {
        self.eqConfiguration = eqConfiguration
    }

    // MARK: - Pipeline Lifecycle

    func setRenderPipeline(_ pipeline: RenderPipeline?) {
        renderPipeline = pipeline
    }

    func setCurrentSampleRate(_ rate: Double) {
        currentSampleRate = rate
    }

    // MARK: - Single Band Updates

    /// Updates a band's gain by recalculating and staging coefficients.
    func updateBandGain(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's Q factor by recalculating and staging coefficients.
    func updateBandQ(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's frequency by recalculating and staging coefficients.
    func updateBandFrequency(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's filter type by recalculating and staging coefficients.
    func updateBandFilterType(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's filter slope by recalculating and staging coefficients.
    func updateBandSlope(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Updates a band's bypass state.
    func updateBandBypass(index: Int) {
        guard index >= 0 && index < eqConfiguration.bands.count else { return }
        let config = eqConfiguration.bands[index]
        stageBandCoefficients(index: index, config: config)
    }

    /// Returns the current band capacity from EQConfiguration.
    func currentBandCapacity() -> Int {
        eqConfiguration.activeBandCount
    }

    /// Reapplies all coefficients from the current configuration.
    func reapplyConfiguration() {
        reapplyAllCoefficients()
    }

    func applyRoomCorrectionBands(_ bands: [EQBandConfiguration]) {
        let layerIdx = EQLayerConstants.roomCorrectionLayerIndex
        guard let pipeline = renderPipeline else { return }
        var sections: [[BiquadCoefficients]] = []
        var bypassFlags: [Bool] = []
        let decoupling = eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        for band in bands {
            let designRate = BiquadMath.designSampleRate(
                actualRate: currentSampleRate,
                coefficientDecouplingEnabled: decoupling)
            let freq = designRate != currentSampleRate
                ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                              actualRate: currentSampleRate,
                                              designRate: designRate)
                : Double(band.frequency)
            guard band.filterType != .fir else {
                sections.append([])
                bypassFlags.append(true)
                continue
            }
            let secs = BiquadMath.calculateSections(
                type: band.filterType, sampleRate: designRate,
                frequency: freq, q: Double(band.q),
                gain: Double(band.gain), slope: band.slope)
            sections.append(secs)
            bypassFlags.append(band.bypass)
        }
        pipeline.stageFullEQUpdate(
            channel: .both,
            layerIndex: layerIdx,
            sections: sections,
            bypassFlags: bypassFlags,
            activeBandCount: bands.count,
            layerBypass: false
        )

        // Task 6: Write applied bands back into the model layer so preset save,
        // CamillaDSP export, and headroom compensation can all read real data.
        let correctionState = EQLayerState(
            label: "Room Correction",
            bands: {
                var padded = EQConfiguration.defaultBands()
                for (i, b) in bands.prefix(padded.count).enumerated() { padded[i] = b }
                return padded
            }(),
            activeBandCount: bands.count,
            bypass: false
        )
        eqConfiguration.setRoomCorrectionLayer(correctionState)

        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
    }

    func clearRoomCorrectionBands() {
        let layerIdx = EQLayerConstants.roomCorrectionLayerIndex
        renderPipeline?.stageFullEQUpdate(
            channel: .both,
            layerIndex: layerIdx,
            sections: [],
            bypassFlags: [],
            activeBandCount: 0,
            layerBypass: true
        )

        // Task 6: Reset the model layer to passthrough so downstream reads see empty bands.
        eqConfiguration.clearRoomCorrectionLayer()

        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
    }

    func setRoomCorrectionLayerBypass(_ bypass: Bool) {
        renderPipeline?.stageEQLayerBypass(
            channel: .both,
            layerIndex: EQLayerConstants.roomCorrectionLayerIndex,
            bypass: bypass
        )

        // Task 6: Keep the model bypass flag in sync.
        eqConfiguration.setRoomCorrectionLayerBypass(bypass)
    }

    func refreshLinearPhaseIRIfNeeded() {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext,
              ctx.isLinearPhaseEnabled else { return }

        // Task 7: Merge userEQ + roomCorrection bands so the linear-phase IR
        // reflects the full cascade, not just layer 0.
        // The render pipeline's linear-phase branch bypasses per-layer biquad chains
        // entirely and only runs linearPhaseEngine.process(), so there is no risk of
        // double-applying room correction here.
        let leftUserBands = Array(eqConfiguration.leftState.userEQ.bands.prefix(
            eqConfiguration.leftState.userEQ.activeBandCount))
        let leftRCBands   = Array(eqConfiguration.leftState.roomCorrection.bands.prefix(
            eqConfiguration.leftState.roomCorrection.activeBandCount))
            .filter { !$0.bypass }
        let leftBands = leftUserBands + leftRCBands

        // For .fir bands on the right channel, substitute firKernelRight into the
        // firKernelLeft slot so computeIRSpectrum uses the correct per-channel kernel.
        let rawRightBands = Array(eqConfiguration.rightState.userEQ.bands.prefix(
            eqConfiguration.rightState.userEQ.activeBandCount))
        let rightRCBands  = Array(eqConfiguration.rightState.roomCorrection.bands.prefix(
            eqConfiguration.rightState.roomCorrection.activeBandCount))
            .filter { !$0.bypass }
        let rightUserRemapped: [EQBandConfiguration] = rawRightBands.map { band in
            guard band.filterType == .fir,
                  let rightKernel = band.firKernelRight,
                  rightKernel != (band.firKernelLeft ?? []) else {
                return band
            }
            var b = band
            b.firKernelLeft = rightKernel
            return b
        }
        let rightBands = rightUserRemapped + rightRCBands

        ctx.updateLinearPhaseIR(leftBands: leftBands,
                                 rightBands: rightBands,
                                 sampleRate: currentSampleRate)
    }

    func refreshMixedPhaseIRIfNeeded() {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext,
              ctx.isMixedPhaseEnabled else { return }

        let decoupling  = eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled

        // Task 7: Include room correction bands in the mixed-phase all-pass sections.
        let activeCount = eqConfiguration.activeBandCount
        let leftUserBands  = Array(eqConfiguration.leftState.userEQ.bands.prefix(activeCount))
        let rightUserBands = Array(eqConfiguration.rightState.userEQ.bands.prefix(activeCount))
        let leftRCBands    = Array(eqConfiguration.leftState.roomCorrection.bands.prefix(
            eqConfiguration.leftState.roomCorrection.activeBandCount))
            .filter { !$0.bypass }
        let rightRCBands   = Array(eqConfiguration.rightState.roomCorrection.bands.prefix(
            eqConfiguration.rightState.roomCorrection.activeBandCount))
            .filter { !$0.bypass }

        // Build per-band section arrays (bypassed bands contribute no sections).
        var leftSections:  [[BiquadCoefficients]] = []
        var rightSections: [[BiquadCoefficients]] = []

        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: decoupling)

        func addSections(for bands: [EQBandConfiguration], into target: inout [[BiquadCoefficients]]) {
            for band in bands where !band.bypass && !band.isDynamic && band.filterType != .fir {
                let freq = designRate != currentSampleRate
                    ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                                  actualRate: currentSampleRate,
                                                  designRate: designRate)
                    : Double(band.frequency)
                let secs = BiquadMath.calculateSections(
                    type: band.filterType, sampleRate: designRate,
                    frequency: freq, q: Double(band.q),
                    gain: Double(band.gain), slope: band.slope)
                target.append(secs)
            }
        }

        addSections(for: leftUserBands + leftRCBands,   into: &leftSections)

        // In linked mode, right = left; in stereo, compute independently.
        if eqConfiguration.channelMode == .linked {
            rightSections = leftSections
        } else {
            addSections(for: rightUserBands + rightRCBands, into: &rightSections)
        }

        pipeline.updateMixedPhaseSections(
            leftSections:  leftSections,
            rightSections: rightSections
        )
    }

    // MARK: - Excess-Phase Correction (Part 5.4)

    /// Refreshes the excess-phase correction impulse response in the convolution engine
    /// when excess-phase correction is enabled and measurement data is available.
    func refreshExcessPhaseIRIfNeeded(measuredResponse: [(frequency: Double, real: Double, imag: Double)]? = nil,
                                     minPhaseResponse: [(frequency: Double, real: Double, imag: Double)]? = nil) {
        guard let pipeline = renderPipeline,
              let ctx = pipeline.callbackContext else { return }

        // Check if excess-phase correction is enabled in the configuration
        let excessPhaseConfig = eqConfiguration.dynamicsConfig.advanced.excessPhaseConfig
        guard excessPhaseConfig.enabled else {
            // Disable convolution if excess-phase correction is disabled
            ctx.setConvolutionEnabled(false)
            return
        }

        // Compute excess-phase correction impulse response if measurement data is available
        guard let measured = measuredResponse,
              let minPhase = minPhaseResponse else {
            logger.warning("Excess-phase correction enabled but measurement data not available")
            return
        }

        let ir = ExcessPhaseCorrector.computeCorrectionFilter(
            measuredResponse: measured,
            minPhaseResponse: minPhase,
            config: excessPhaseConfig,
            sampleRate: currentSampleRate
        )

        // Update convolution engine with the excess-phase IR (same for both channels)
        ctx.updateConvolutionIR(left: ir, right: ir)
        ctx.setConvolutionEnabled(true)
        logger.info("Excess-phase correction IR updated: \(ir.count) taps, cutoff: \(excessPhaseConfig.cutoffFreqHz) Hz")
    }

    // MARK: - Private Coefficient Helpers

    /// Computes biquad sections for a band, routing Linkwitz-Transform and constant-Q
    /// through their dedicated math. Single source of truth used by both the incremental
    /// (stageBandCoefficients) and full-reload (reapplyAllCoefficients) paths.
    func computeSections(for config: EQBandConfiguration, warpedFrequency: Double, designRate: Double) -> [BiquadCoefficients] {
        if config.filterType == .parametric && config.constantQ {
            let single = BiquadMath.peakingEQConstantQ(
                sampleRate: designRate,
                frequency: warpedFrequency,
                q: Double(config.q),
                gain: Double(config.gain)
            )
            return [single]
        } else if config.filterType == .linkwitzTransform {
            let fp = config.linkwitzTargetHz.map { Double($0) } ?? (warpedFrequency * 0.7)
            // BiquadMath.linkwitzTransform internally guards against non-positive Q values
            // and non-finite results, returning identity coefficients if invalid — safe to call directly.
            let single = BiquadMath.linkwitzTransform(
                f0: warpedFrequency, q0: Double(config.q),
                fp: fp, qp: Double(config.gain),
                sampleRate: designRate
            )
            return [single]
        } else {
            return BiquadMath.calculateSections(
                type: config.filterType,
                sampleRate: designRate,
                frequency: warpedFrequency,
                q: Double(config.q),
                gain: Double(config.gain),
                slope: config.slope
            )
        }
    }

    /// Stages coefficients for a single band (incremental update path).
    private func stageBandCoefficients(index: Int, config: EQBandConfiguration) {
        if config.filterType == .fir {
            renderPipeline?.updateBandCoefficients(
                channel: .both,
                layerIndex: EQLayerConstants.userEQLayerIndex,
                bandIndex: index,
                sections: [],
                bypass: true,
                needsDoublePrecision: false
            )
            refreshLinearPhaseIRIfNeeded()
            refreshMixedPhaseIRIfNeeded()
            return
        }
        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        )
        let warpedFrequency: Double
        if designRate != currentSampleRate {
            warpedFrequency = BiquadMath.prewarpFrequency(
                frequency: Double(config.frequency),
                actualRate: currentSampleRate,
                designRate: designRate
            )
        } else {
            warpedFrequency = Double(config.frequency)
        }

        let target: EQChannelTarget
        switch eqConfiguration.channelMode {
        case .linked:
            target = .both
        case .stereo:
            target = eqConfiguration.channelFocus == .left ? .left : .right
        case .midSide:
            let editingMid = (eqConfiguration.channelFocus == .mid ||
                              eqConfiguration.channelFocus == .left)
            target = editingMid ? .left : .right
        }

        // Validate parameters before calculation.
        let paramResult = BiquadValidator.validate(
            type: config.filterType,
            sampleRate: designRate,
            frequency: warpedFrequency,
            q: Double(config.q),
            gain: Double(config.gain)
        )
        if case .invalid(let message) = paramResult {
            logger.warning("Band \(index) invalid parameters: \(message) — using passthrough")
            renderPipeline?.updateBandCoefficients(
                channel: target,
                layerIndex: EQLayerConstants.userEQLayerIndex,
                bandIndex: index,
                sections: [],
                bypass: true,
                needsDoublePrecision: false
            )
            return
        }
        if case .warning(let message) = paramResult {
            logger.debug("Band \(index) parameter warning: \(message)")
        }

        let sections = computeSections(for: config, warpedFrequency: warpedFrequency, designRate: designRate)

        // Validate every computed section — a cascade is only as stable as its weakest section.
        for (sectionIndex, section) in sections.enumerated() {
            if !BiquadValidator.isFinite(section) {
                logger.warning("Band \(index) section \(sectionIndex) coefficients are non-finite — using passthrough")
                renderPipeline?.updateBandCoefficients(
                    channel: target,
                    layerIndex: EQLayerConstants.userEQLayerIndex,
                    bandIndex: index,
                    sections: [],
                    bypass: true,
                    needsDoublePrecision: false
                )
                return
            }
            if !BiquadValidator.isStable(section) {
                logger.warning("Band \(index) section \(sectionIndex) coefficients are unstable — using passthrough")
                renderPipeline?.updateBandCoefficients(
                    channel: target,
                    layerIndex: EQLayerConstants.userEQLayerIndex,
                    bandIndex: index,
                    sections: [],
                    bypass: true,
                    needsDoublePrecision: false
                )
                return
            }
        }

        renderPipeline?.updateBandCoefficients(
            channel: target,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            bandIndex: index,
            sections: sections,
            bypass: config.bypass,
            needsDoublePrecision: !config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0)
        )
        refreshMixedPhaseIRIfNeeded()
        onBandCoefficientsStaged?()
    }

    /// Recalculates and stages all coefficients for all active bands (full update path).
    private func reapplyAllCoefficients() {
        let activeCount = eqConfiguration.activeBandCount

        let leftBands = eqConfiguration.leftState.userEQ.bands
        let rightBands = eqConfiguration.rightState.userEQ.bands

        // Build left-channel sections
        var leftSections: [[BiquadCoefficients]] = []
        var leftBypassFlags: [Bool] = []
        var leftNeedsDoublePrecision: [Bool] = []

        let designRate = BiquadMath.designSampleRate(
            actualRate: currentSampleRate,
            coefficientDecouplingEnabled: eqConfiguration.dynamicsConfig.advanced.coefficientDecouplingEnabled
        )

        for index in 0..<activeCount {
            guard index < leftBands.count else { break }
            let config = leftBands[index]
            // FIR bands produce no IIR coefficients — append identity slot and continue.
            guard config.filterType != .fir else {
                leftSections.append([])
                leftBypassFlags.append(true)
                leftNeedsDoublePrecision.append(false)
                continue
            }
            let warpedFrequency: Double
            if designRate != currentSampleRate {
                warpedFrequency = BiquadMath.prewarpFrequency(
                    frequency: Double(config.frequency),
                    actualRate: currentSampleRate,
                    designRate: designRate
                )
            } else {
                warpedFrequency = Double(config.frequency)
            }
            let sections = computeSections(for: config, warpedFrequency: warpedFrequency, designRate: designRate)
            leftSections.append(sections)
            leftBypassFlags.append(config.bypass)
            leftNeedsDoublePrecision.append(!config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0))
        }

        let leftTarget: EQChannelTarget = eqConfiguration.channelMode == .linked ? .both : .left

        renderPipeline?.stageFullEQUpdate(
            channel: leftTarget,
            layerIndex: EQLayerConstants.userEQLayerIndex,
            sections: leftSections,
            bypassFlags: leftBypassFlags,
            activeBandCount: activeCount,
            layerBypass: eqConfiguration.globalBypass,
            needsDoublePrecision: leftNeedsDoublePrecision
        )

        // In stereo mode, also stage right-channel coefficients
        if eqConfiguration.channelMode == .stereo {
            var rightSections: [[BiquadCoefficients]] = []
            var rightBypassFlags: [Bool] = []
            var rightNeedsDoublePrecision: [Bool] = []

            for index in 0..<activeCount {
                guard index < rightBands.count else { break }
                let config = rightBands[index]
                // FIR bands produce no IIR coefficients — append identity slot and continue.
                guard config.filterType != .fir else {
                    rightSections.append([])
                    rightBypassFlags.append(true)
                    rightNeedsDoublePrecision.append(false)
                    continue
                }
                let warpedFrequency: Double
                if designRate != currentSampleRate {
                    warpedFrequency = BiquadMath.prewarpFrequency(
                        frequency: Double(config.frequency),
                        actualRate: currentSampleRate,
                        designRate: designRate
                    )
                } else {
                    warpedFrequency = Double(config.frequency)
                }
                let sections = computeSections(for: config, warpedFrequency: warpedFrequency, designRate: designRate)
                rightSections.append(sections)
                rightBypassFlags.append(config.bypass)
                rightNeedsDoublePrecision.append(!config.bypass && (Double(config.q) > 4.0 || Double(config.frequency) < 300.0))
            }

            renderPipeline?.stageFullEQUpdate(
                channel: .right,
                layerIndex: EQLayerConstants.userEQLayerIndex,
                sections: rightSections,
                bypassFlags: rightBypassFlags,
                activeBandCount: activeCount,
                layerBypass: eqConfiguration.globalBypass,
                needsDoublePrecision: rightNeedsDoublePrecision
            )
        }
        refreshLinearPhaseIRIfNeeded()
        refreshMixedPhaseIRIfNeeded()
        onBandCoefficientsStaged?()
    }
}
