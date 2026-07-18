// LinearPhaseEQEngine.swift
// Overlap-save FFT convolution EQ — zero phase shift, lock-free IR updates.
import Accelerate
import Atomics
import Foundation

final class LinearPhaseEQEngine: @unchecked Sendable {

    private var designSize: Int  // Resolution for mag[] sampling and FFT_INVERSE (also kernelLength)
    private var fftSize: Int      // Size for block-convolution machinery (2 × designSize)
    private var _hopSize: Int      // fftSize / 2 = designSize
    private var log2n:   vDSP_Length  // log2(fftSize) for the FFTSetup

    private var fftSetup: FFTSetup?

    nonisolated(unsafe) private var activeReal:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeImag:  UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeRealR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var activeImagR: UnsafeMutablePointer<Float>
    private var pendingReal:  UnsafeMutablePointer<Float>
    private var pendingImag:  UnsafeMutablePointer<Float>
    private var pendingRealR: UnsafeMutablePointer<Float>
    private var pendingImagR: UnsafeMutablePointer<Float>
    private var nextPendingReal:  UnsafeMutablePointer<Float>
    private var nextPendingImag:  UnsafeMutablePointer<Float>
    private var nextPendingRealR: UnsafeMutablePointer<Float>
    private var nextPendingImagR: UnsafeMutablePointer<Float>
    private let hasPendingIR = ManagedAtomic<Bool>(false)

    nonisolated(unsafe) private var overlapL: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var overlapR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var fftWorkReal: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var fftWorkImag: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumL: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var accumPosL: Int = 0
    nonisolated(unsafe) private var accumPosR: Int = 0

    /// Output carry-over ring buffers for draining valid output across multiple process() calls.
    /// Sized to 8×hopSize to ensure dst is never underfilled for any frameCount up to hopSize.
    /// Operates as a ring buffer with readPos (drain position) and writePos (append position).
    nonisolated(unsafe) private var outputCarryL: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var outputCarryR: UnsafeMutablePointer<Float>
    nonisolated(unsafe) private var outputCarryReadPosL: Int = 0
    nonisolated(unsafe) private var outputCarryReadPosR: Int = 0
    nonisolated(unsafe) private var outputCarryWritePosL: Int = 0
    nonisolated(unsafe) private var outputCarryWritePosR: Int = 0
    nonisolated(unsafe) private var outputCarryAvailableL: Int = 0
    nonisolated(unsafe) private var outputCarryAvailableR: Int = 0

    /// Startup phase: accumulate output without draining until we have sufficient margin.
    /// This prevents underfill when frameCount doesn't evenly divide hopSize.
    nonisolated(unsafe) private var outputCarryHopsAccumulatedL: Int = 0
    nonisolated(unsafe) private var outputCarryHopsAccumulatedR: Int = 0
    private let startupHopsRequired: Int = 2  // Require 2 hops before draining begins

    /// Contiguous time-domain output buffer. Sized to fftSize.
    /// Filled by vDSP_ztoc after IFFT to unpack the split-complex result.
    private var outputBuf: UnsafeMutablePointer<Float>

    private var halfN: Int
    private var kernelLength: Int

    /// The group delay introduced by the linear-phase kernel in samples.
    /// Equal to kernelLength / 2 (the center of the causal kernel).
    var kernelDelaySamples: Int {
        kernelLength / 2
    }

    /// The hop size (number of samples per overlap-save block).
    /// Equal to fftSize / 2 = designSize.
    var hopSize: Int {
        _hopSize
    }

    init(maxFrameCount: Int) {
        _ = maxFrameCount
        designSize = 4096
        fftSize = 2 * designSize
        _hopSize = fftSize / 2
        kernelLength = designSize
        log2n   = vDSP_Length(log2(Double(fftSize)).rounded())
        halfN   = fftSize / 2
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        activeReal  = Self.alloc(fftSize)
        activeImag  = Self.alloc(fftSize)
        activeRealR = Self.alloc(fftSize)
        activeImagR = Self.alloc(fftSize)
        pendingReal  = Self.alloc(fftSize)
        pendingImag  = Self.alloc(fftSize)
        pendingRealR = Self.alloc(fftSize)
        pendingImagR = Self.alloc(fftSize)
        nextPendingReal  = Self.alloc(fftSize)
        nextPendingImag  = Self.alloc(fftSize)
        nextPendingRealR = Self.alloc(fftSize)
        nextPendingImagR = Self.alloc(fftSize)

        overlapL = Self.alloc(_hopSize)
        overlapR = Self.alloc(_hopSize)
        fftWorkReal = Self.alloc(fftSize)
        fftWorkImag = Self.alloc(fftSize)
        accumL = Self.alloc(fftSize)
        accumR = Self.alloc(fftSize)
        outputBuf = Self.alloc(fftSize)
        outputCarryL = Self.alloc(8 * _hopSize)
        outputCarryR = Self.alloc(8 * _hopSize)

        activeReal[0] = 1.0
        activeRealR[0] = 1.0
        pendingReal[0] = 1.0
        pendingRealR[0] = 1.0
    }

    deinit {
        if let s = fftSetup { vDSP_destroy_fftsetup(s) }
        [activeReal, activeImag, activeRealR, activeImagR,
         pendingReal, pendingImag, pendingRealR, pendingImagR,
         nextPendingReal, nextPendingImag, nextPendingRealR, nextPendingImagR,
         overlapL, overlapR, fftWorkReal, fftWorkImag,
         accumL, accumR, outputBuf, outputCarryL, outputCarryR].forEach { Self.free($0) }
    }

    func updateIR(leftBands:  [EQBandConfiguration],
                  rightBands: [EQBandConfiguration],
                  sampleRate: Double) {
        let newDesignSize: Int
        switch sampleRate {
        case ...48_000:  newDesignSize = 4096
        case ...96_000:  newDesignSize = 8192
        case ...192_000: newDesignSize = 16384
        default:         newDesignSize = 32768   // 384 kHz: ~85 ms, ~11.7 Hz/bin
        }
        if newDesignSize != designSize {
            designSize = newDesignSize
            fftSize = 2 * designSize
            _hopSize = fftSize / 2
            kernelLength = designSize
            halfN   = fftSize / 2
            log2n   = vDSP_Length(log2(Double(fftSize)).rounded())
            if let s = fftSetup { vDSP_destroy_fftsetup(s) }
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            [activeReal, activeImag, activeRealR, activeImagR,
             pendingReal, pendingImag, pendingRealR, pendingImagR,
             nextPendingReal, nextPendingImag, nextPendingRealR, nextPendingImagR,
             fftWorkReal, fftWorkImag].forEach { Self.free($0) }
            activeReal   = Self.alloc(fftSize); activeImag   = Self.alloc(fftSize)
            activeRealR  = Self.alloc(fftSize); activeImagR  = Self.alloc(fftSize)
            pendingReal  = Self.alloc(fftSize); pendingImag  = Self.alloc(fftSize)
            pendingRealR = Self.alloc(fftSize); pendingImagR = Self.alloc(fftSize)
            nextPendingReal  = Self.alloc(fftSize); nextPendingImag  = Self.alloc(fftSize)
            nextPendingRealR = Self.alloc(fftSize); nextPendingImagR = Self.alloc(fftSize)
            fftWorkReal  = Self.alloc(fftSize); fftWorkImag  = Self.alloc(fftSize)
            Self.free(outputBuf); outputBuf = Self.alloc(fftSize)
            Self.free(overlapL); overlapL = Self.alloc(_hopSize)
            Self.free(overlapR); overlapR = Self.alloc(_hopSize)
            Self.free(accumL);   accumL   = Self.alloc(fftSize)
            Self.free(accumR);   accumR   = Self.alloc(fftSize)
            Self.free(outputCarryL); outputCarryL = Self.alloc(8 * _hopSize)
            Self.free(outputCarryR); outputCarryR = Self.alloc(8 * _hopSize)
            accumPosL = 0; accumPosR = 0
            outputCarryReadPosL = 0; outputCarryReadPosR = 0
            outputCarryWritePosL = 0; outputCarryWritePosR = 0
            outputCarryAvailableL = 0; outputCarryAvailableR = 0
            outputCarryHopsAccumulatedL = 0; outputCarryHopsAccumulatedR = 0
        }
        computeIRSpectrum(bands: leftBands,  sampleRate: sampleRate,
                          outReal: nextPendingReal, outImag: nextPendingImag)
        computeIRSpectrum(bands: rightBands, sampleRate: sampleRate,
                          outReal: nextPendingRealR, outImag: nextPendingImagR)
        hasPendingIR.store(true, ordering: .releasing)
    }

    /// Updates the IR directly from pre-computed time-domain FIR kernels.
    /// Used by adaptive excess-phase correction where the kernel is computed externally.
    func updateIRFromKernel(leftKernel: [Float], rightKernel: [Float], sampleRate: Double) {
        let newDesignSize: Int
        switch sampleRate {
        case ...48_000:  newDesignSize = 4096
        case ...96_000:  newDesignSize = 8192
        case ...192_000: newDesignSize = 16384
        default:         newDesignSize = 32768
        }
        if newDesignSize != designSize {
            designSize = newDesignSize
            fftSize = 2 * designSize
            _hopSize = fftSize / 2
            kernelLength = designSize
            halfN   = fftSize / 2
            log2n   = vDSP_Length(log2(Double(fftSize)).rounded())
            if let s = fftSetup { vDSP_destroy_fftsetup(s) }
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            [activeReal, activeImag, activeRealR, activeImagR,
             pendingReal, pendingImag, pendingRealR, pendingImagR,
             nextPendingReal, nextPendingImag, nextPendingRealR, nextPendingImagR,
             fftWorkReal, fftWorkImag].forEach { Self.free($0) }
            activeReal   = Self.alloc(fftSize); activeImag   = Self.alloc(fftSize)
            activeRealR  = Self.alloc(fftSize); activeImagR  = Self.alloc(fftSize)
            pendingReal  = Self.alloc(fftSize); pendingImag  = Self.alloc(fftSize)
            pendingRealR = Self.alloc(fftSize); pendingImagR = Self.alloc(fftSize)
            nextPendingReal  = Self.alloc(fftSize); nextPendingImag  = Self.alloc(fftSize)
            nextPendingRealR = Self.alloc(fftSize); nextPendingImagR = Self.alloc(fftSize)
            fftWorkReal  = Self.alloc(fftSize); fftWorkImag  = Self.alloc(fftSize)
            Self.free(outputBuf); outputBuf = Self.alloc(fftSize)
            Self.free(overlapL); overlapL = Self.alloc(_hopSize)
            Self.free(overlapR); overlapR = Self.alloc(_hopSize)
            Self.free(accumL);   accumL   = Self.alloc(fftSize)
            Self.free(accumR);   accumR   = Self.alloc(fftSize)
            Self.free(outputCarryL); outputCarryL = Self.alloc(8 * _hopSize)
            Self.free(outputCarryR); outputCarryR = Self.alloc(8 * _hopSize)
            accumPosL = 0; accumPosR = 0
            outputCarryReadPosL = 0; outputCarryReadPosR = 0
            outputCarryWritePosL = 0; outputCarryWritePosR = 0
            outputCarryAvailableL = 0; outputCarryAvailableR = 0
            outputCarryHopsAccumulatedL = 0; outputCarryHopsAccumulatedR = 0
        }
        computeIRSpectrumFromKernel(kernel: leftKernel, outReal: nextPendingReal, outImag: nextPendingImag)
        computeIRSpectrumFromKernel(kernel: rightKernel, outReal: nextPendingRealR, outImag: nextPendingImagR)
        hasPendingIR.store(true, ordering: .releasing)
    }

    /// Computes the frequency spectrum of a time-domain FIR kernel.
    ///
    /// - Important: The forward transform below must run at `log2n` (the
    ///   `fftSize`-resolution FFT used by `processChannel`'s spectral multiply),
    ///   and the packed split-complex buffers must therefore be sized to the
    ///   class's `halfN` (== fftSize / 2), NOT to `designSize / 2`. Using a
    ///   locally-shadowed, half-sized `halfN` here previously caused
    ///   `vDSP_fft_zrip` to read/write a `fftSize`-order transform into
    ///   buffers only allocated for a `designSize`-order transform — a
    ///   silent heap buffer overflow on every call (see incident
    ///   950FA9B7-DEDC-4461-9AB8-F50E8387BCCA).
    private func computeIRSpectrumFromKernel(kernel: [Float], outReal: UnsafeMutablePointer<Float>, outImag: UnsafeMutablePointer<Float>) {
        let N = designSize

        // Build a causal, zero-padded fftSize-length kernel buffer: the kernel's
        // (up to N) taps occupy [0, N), and [N, fftSize) is zero padding. This is
        // the same layout `processChannel` expects when it multiplies this
        // spectrum against the fftSize-point signal-block FFT.
        var causalKernel = [Float](repeating: 0, count: fftSize)
        let copyCount = min(kernel.count, N)
        for i in 0..<copyCount {
            causalKernel[i] = kernel[i]
        }

        // Pack real fftSize-length samples into `halfN` (== fftSize / 2) complex
        // pairs for vDSP_fft_zrip. `halfN` here is intentionally the class
        // property (fftSize / 2), matching the buffer sizes below.
        var packedReal = [Float](repeating: 0, count: halfN)
        var packedImag = [Float](repeating: 0, count: halfN)
        causalKernel.withUnsafeMutableBufferPointer { kernelBuf in
            kernelBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                packedReal.withUnsafeMutableBufferPointer { realBuf in
                    packedImag.withUnsafeMutableBufferPointer { imagBuf in
                        var kernelSC = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(cBuf, 2, &kernelSC, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        // Forward FFT on the packed halfN (= fftSize/2) buffer — log2n matches
        // this buffer's size, so this no longer overruns packedReal/packedImag.
        packedReal.withUnsafeMutableBufferPointer { realBuf in
            packedImag.withUnsafeMutableBufferPointer { imagBuf in
                var kernelSC = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                guard let setup = fftSetup else { return }
                vDSP_fft_zrip(setup, &kernelSC, 1, log2n, Int32(FFT_FORWARD))
            }
        }

        // Note: unlike the biquad path (computeIRSpectrum), no additional
        // manual normalisation is applied here — unnormalised, this carries
        // the same implicit 2x forward-transform scale that computeIRSpectrum's
        // output carries, which processChannel's final 1/(4*fftSize) scale
        // already accounts for. Copy directly into the output spectrum.
        memcpy(outReal, &packedReal, halfN * MemoryLayout<Float>.size)
        memcpy(outImag, &packedImag, halfN * MemoryLayout<Float>.size)
    }

    @inline(__always)
    func process(bufL: UnsafeMutablePointer<Float>,
                 bufR: UnsafeMutablePointer<Float>?,
                 frameCount: Int) {
        if hasPendingIR.load(ordering: .acquiring) {
            // First swap: nextPending → pending (main thread → audio thread handoff)
            swap(&nextPendingReal,  &pendingReal)
            swap(&nextPendingImag,  &pendingImag)
            swap(&nextPendingRealR, &pendingRealR)
            swap(&nextPendingImagR, &pendingImagR)
            // Second swap: pending → active (audio thread internal swap)
            swap(&activeReal,  &pendingReal)
            swap(&activeImag,  &pendingImag)
            swap(&activeRealR, &pendingRealR)
            swap(&activeImagR, &pendingImagR)
            hasPendingIR.store(false, ordering: .relaxed)
        }

        processChannel(src: bufL, dst: bufL, overlap: overlapL, accum: accumL,
                       accumPos: &accumPosL,
                       specReal: activeReal, specImag: activeImag, frameCount: frameCount)
        if let r = bufR {
            processChannel(src: r, dst: r, overlap: overlapR, accum: accumR,
                           accumPos: &accumPosR,
                           specReal: activeRealR, specImag: activeImagR, frameCount: frameCount)
        }
    }

    func reset() {
        vDSP_vclr(overlapL, 1, vDSP_Length(_hopSize))
        vDSP_vclr(overlapR, 1, vDSP_Length(_hopSize))
        vDSP_vclr(accumL,   1, vDSP_Length(fftSize))
        vDSP_vclr(accumR,   1, vDSP_Length(fftSize))
        vDSP_vclr(outputCarryL, 1, vDSP_Length(8 * _hopSize))
        vDSP_vclr(outputCarryR, 1, vDSP_Length(8 * _hopSize))
        accumPosL = 0
        accumPosR = 0
        outputCarryReadPosL = 0
        outputCarryReadPosR = 0
        outputCarryWritePosL = 0
        outputCarryWritePosR = 0
        outputCarryAvailableL = 0
        outputCarryAvailableR = 0
        outputCarryHopsAccumulatedL = 0
        outputCarryHopsAccumulatedR = 0
    }

    @inline(__always)
    private func processChannel(
        src: UnsafePointer<Float>, dst: UnsafeMutablePointer<Float>,
        overlap: UnsafeMutablePointer<Float>,
        accum: UnsafeMutablePointer<Float>,
        accumPos: inout Int,
        specReal: UnsafePointer<Float>, specImag: UnsafePointer<Float>,
        frameCount: Int
    ) {
        assert(_hopSize >= frameCount,
            "LinearPhaseEQEngine: frameCount \(frameCount) exceeds hopSize \(_hopSize). Increase FFT size.")
        guard let setup = fftSetup else {
            if src != dst { memcpy(dst, src, frameCount * 4) }
            return
        }

        // PHASE 1 — consume every sample of `src` for this call, running any
        // hop completions along the way. This phase never writes to `dst`.
        var srcPos = 0
        while srcPos < frameCount {
            let chunk = min(_hopSize - accumPos, frameCount - srcPos)
            memcpy(accum.advanced(by: _hopSize + accumPos), src.advanced(by: srcPos),
                   chunk * MemoryLayout<Float>.size)
            accumPos += chunk
            srcPos += chunk

            if accumPos == _hopSize {
                memcpy(accum, overlap, _hopSize * MemoryLayout<Float>.size)

                var sc = DSPSplitComplex(realp: fftWorkReal, imagp: fftWorkImag)
                accum.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                    var sc2 = sc
                    vDSP_ctoz(cBuf, 2, &sc2, 1, vDSP_Length(halfN))
                }
                vDSP_fft_zrip(setup, &sc, 1, log2n, Int32(FFT_FORWARD))

                var irSC = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: specReal),
                                           imagp: UnsafeMutablePointer(mutating: specImag))

                // Index 0 is special in vDSP's packed real-FFT format: realp[0] is the DC bin,
                // imagp[0] is the Nyquist bin — two independent real values, not one complex
                // number. A plain complex multiply at this index is mathematically wrong (it
                // mixes DC and Nyquist energy together). Handle it as two real multiplies.
                let sigNyquist = sc.imagp[0]
                let irNyquist  = irSC.imagp[0]
                sc.imagp[0]    = 0
                irSC.imagp[0]  = 0

                vDSP_zvmul(&sc, 1, &irSC, 1, &sc, 1, vDSP_Length(halfN), 1)

                sc.imagp[0]   = sigNyquist * irNyquist   // correct Nyquist product
                irSC.imagp[0] = irNyquist                // MUST restore — irSC points to persistent IR spectrum

                vDSP_fft_zrip(setup, &sc, 1, log2n, Int32(FFT_INVERSE))

                // After vDSP_fft_zrip inverse, the N real time-domain samples are packed
                // into the split-complex pair as N/2 interleaved complex values:
                //   fftWorkReal[k] = x[2k],  fftWorkImag[k] = x[2k+1]
                // Use vDSP_ztoc to unpack into a contiguous array of N real samples.
                outputBuf.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                    vDSP_ztoc(&sc, 1, cBuf, 2, vDSP_Length(halfN))
                }

                // Normalise. Two forward vDSP_fft_zrip transforms are multiplied together here
                // (the signal block's spectrum and the pre-computed kernel spectrum from
                // computeIRSpectrum), and each forward zrip carries an implicit 2x scale
                // (Apple's documented forward+inverse round-trip factor is 2N, split as
                // forward=2x, inverse=Nx). Squaring that 2x from the two multiplied spectra
                // gives a compounded 4x that a single inverse zrip + 1/N normalisation does not
                // remove, so the correct scale is 1/(4N), not 1/N.
                var scale = Float(1.0 / (4.0 * Float(fftSize)))
                vDSP_vsmul(outputBuf, 1, &scale, outputBuf, 1, vDSP_Length(fftSize))

                // The valid (alias-free) output is the SECOND half of the IFFT result,
                // indices [_hopSize .. fftSize-1]. Append this to the carry-over ring buffer.
                let carryCapacity = 8 * _hopSize
                if accum == accumL {
                    let writePos = outputCarryWritePosL
                    let writeEnd = min(writePos + _hopSize, carryCapacity)
                    let firstPart = writeEnd - writePos
                    memcpy(outputCarryL.advanced(by: writePos), outputBuf.advanced(by: _hopSize), firstPart * MemoryLayout<Float>.size)
                    if _hopSize > firstPart {
                        memcpy(outputCarryL, outputBuf.advanced(by: _hopSize + firstPart), (_hopSize - firstPart) * MemoryLayout<Float>.size)
                    }
                    outputCarryWritePosL = (writePos + _hopSize) % carryCapacity
                    outputCarryAvailableL += _hopSize
                    outputCarryHopsAccumulatedL += 1
                } else {
                    let writePos = outputCarryWritePosR
                    let writeEnd = min(writePos + _hopSize, carryCapacity)
                    let firstPart = writeEnd - writePos
                    memcpy(outputCarryR.advanced(by: writePos), outputBuf.advanced(by: _hopSize), firstPart * MemoryLayout<Float>.size)
                    if _hopSize > firstPart {
                        memcpy(outputCarryR, outputBuf.advanced(by: _hopSize + firstPart), (_hopSize - firstPart) * MemoryLayout<Float>.size)
                    }
                    outputCarryWritePosR = (writePos + _hopSize) % carryCapacity
                    outputCarryAvailableR += _hopSize
                    outputCarryHopsAccumulatedR += 1
                }

                // Save second half of INPUT as the overlap for the next frame (overlap-save).
                memcpy(overlap, accum.advanced(by: _hopSize), _hopSize * MemoryLayout<Float>.size)
                accumPos = 0
            }
        }

        // PHASE 2 — now that every read of `src` is done, it's safe to overwrite
        // dst (even if dst === src). Drain the carry ring buffer to fill dst.
        // Only drain after startup phase (accumulate 2 hops first to prevent underfill).
        var dstPos = 0
        var readPos: Int
        var available: Int
        var hopsAccumulated: Int
        if accum == accumL {
            readPos = outputCarryReadPosL
            available = outputCarryAvailableL
            hopsAccumulated = outputCarryHopsAccumulatedL
        } else {
            readPos = outputCarryReadPosR
            available = outputCarryAvailableR
            hopsAccumulated = outputCarryHopsAccumulatedR
        }

        // Skip draining during startup phase
        if hopsAccumulated >= startupHopsRequired {
            let carryCapacity = 8 * _hopSize
            while available > 0 && dstPos < frameCount {
                let chunk = min(available, frameCount - dstPos)
                let readEnd = min(readPos + chunk, carryCapacity)
                let firstPart = readEnd - readPos
                if accum == accumL {
                    memcpy(dst.advanced(by: dstPos), outputCarryL.advanced(by: readPos), firstPart * MemoryLayout<Float>.size)
                    if chunk > firstPart {
                        memcpy(dst.advanced(by: dstPos + firstPart), outputCarryL, (chunk - firstPart) * MemoryLayout<Float>.size)
                    }
                } else {
                    memcpy(dst.advanced(by: dstPos), outputCarryR.advanced(by: readPos), firstPart * MemoryLayout<Float>.size)
                    if chunk > firstPart {
                        memcpy(dst.advanced(by: dstPos + firstPart), outputCarryR, (chunk - firstPart) * MemoryLayout<Float>.size)
                    }
                }
                dstPos += chunk
                readPos = (readPos + chunk) % carryCapacity
                available -= chunk
            }
        }

        if accum == accumL {
            outputCarryReadPosL = readPos
            outputCarryAvailableL = available
        } else {
            outputCarryReadPosR = readPos
            outputCarryAvailableR = available
        }

    }

    private func computeIRSpectrum(
        bands: [EQBandConfiguration],
        sampleRate: Double,
        outReal: UnsafeMutablePointer<Float>,
        outImag: UnsafeMutablePointer<Float>
    ) {
        /// - Note: For `.fir` bands, the `firKernelLeft` property of each
        ///   `EQBandConfiguration` is used as the kernel. The caller must substitute
        ///   `firKernelRight` into the right-channel band array when the two channels
        ///   differ (see `EQCoefficientStager.refreshLinearPhaseIRIfNeeded`).
        guard let setup = fftSetup else { return }
        let N = designSize  // Use designSize for mag[] sampling and FFT_INVERSE
        let halfNDesign = N / 2  // Half of designSize for the design FFT
        let log2nDesign = vDSP_Length(log2(Double(N)).rounded())  // log2 of designSize

        var mag = [Double](repeating: 1.0, count: halfNDesign + 1)
        for band in bands where !band.bypass && !band.isDynamic {
            if band.filterType == .fir {
                // FIR band: fold the user kernel spectrum into the magnitude accumulator.
                // firKernelLeft is used as the kernel source; the caller is responsible
                // for substituting firKernelRight when processing the right channel.
                guard let kernel = band.firKernelLeft, !kernel.isEmpty else { continue }
                let copyCount = min(kernel.count, N)
                var paddedKernel = [Float](repeating: 0, count: N)
                var paddedImag   = [Float](repeating: 0, count: N)
                paddedKernel.withUnsafeMutableBufferPointer { dst in
                    kernel.withUnsafeBufferPointer { src in
                        memcpy(dst.baseAddress!, src.baseAddress!,
                               copyCount * MemoryLayout<Float>.size)
                    }
                }
                // Pack real kernel samples into halfNDesign complex pairs for vDSP_fft_zrip
                var packedReal = [Float](repeating: 0, count: halfNDesign)
                var packedImag = [Float](repeating: 0, count: halfNDesign)
                paddedKernel.withUnsafeMutableBufferPointer { kernelBuf in
                    kernelBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfNDesign) { cBuf in
                        packedReal.withUnsafeMutableBufferPointer { realBuf in
                            packedImag.withUnsafeMutableBufferPointer { imagBuf in
                                var kernelSC = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                                vDSP_ctoz(cBuf, 2, &kernelSC, 1, vDSP_Length(halfNDesign))
                            }
                        }
                    }
                }

                // Forward FFT on packed halfNDesign buffer (use designSize log2n)
                packedReal.withUnsafeMutableBufferPointer { realBuf in
                    packedImag.withUnsafeMutableBufferPointer { imagBuf in
                        var kernelSC = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_fft_zrip(setup, &kernelSC, 1, log2nDesign, Int32(FFT_FORWARD))
                    }
                }

                // vDSP_fft_zrip applies a 2× scale on forward pass; normalise it out.
                var invScale = Float(1.0 / Float(N))
                // Use separate source/dest buffers to satisfy exclusivity.
                var scaledKernel = [Float](repeating: 0, count: halfNDesign)
                var scaledImag   = [Float](repeating: 0, count: halfNDesign)
                vDSP_vsmul(&packedReal, 1, &invScale, &scaledKernel, 1, vDSP_Length(halfNDesign))
                vDSP_vsmul(&packedImag, 1, &invScale, &scaledImag,   1, vDSP_Length(halfNDesign))
                // Multiply the kernel magnitude into the accumulator.
                for k in 0...halfNDesign {
                    let re = Double(scaledKernel[k])
                    let im = Double(scaledImag[k])
                    mag[k] *= sqrt(re * re + im * im)
                }
                continue  // skip IIR coefficient path for this band
            }
            let designRate = BiquadMath.designSampleRate(
                actualRate: sampleRate,
                coefficientDecouplingEnabled: true)
            let freq = designRate != sampleRate
                ? BiquadMath.prewarpFrequency(frequency: Double(band.frequency),
                                              actualRate: sampleRate,
                                              designRate: designRate)
                : Double(band.frequency)
            let sections = BiquadMath.calculateSections(
                type: band.filterType, sampleRate: designRate,
                frequency: freq, q: Double(band.q),
                gain: Double(band.gain), slope: band.slope)
            for k in 0...halfNDesign {
                let f = Double(k) * sampleRate / Double(N)
                var bandMag = 1.0
                for sec in sections {
                    let w  = 2.0 * Double.pi * f / sampleRate
                    let cr = cos(w), sr = sin(w)
                    let cr2 = cos(2*w), sr2 = sin(2*w)
                    let numR = sec.b0 + sec.b1 * cr  + sec.b2 * cr2
                    let numI =          sec.b1 * sr  + sec.b2 * sr2
                    let denR = 1.0  + sec.a1 * cr  + sec.a2 * cr2
                    let denI =          sec.a1 * sr  + sec.a2 * sr2
                    let denom = denR*denR + denI*denI
                    if denom > 1e-30 {
                        bandMag *= sqrt((numR*numR + numI*numI) / denom)
                    }
                }
                mag[k] *= bandMag
            }
        }

        // Build halfNDesign-length packed target spectrum per vDSP convention:
        // specReal[0] = DC, specImag[0] = Nyquist (packed together)
        // specReal[1..halfNDesign-1], specImag[1..halfNDesign-1] = remaining complex bins
        var specReal = [Float](repeating: 0, count: halfNDesign)
        var specImag = [Float](repeating: 0, count: halfNDesign)
        specReal[0] = Float(mag[0])              // DC
        specImag[0] = Float(mag[halfNDesign])    // Nyquist, packed per vDSP convention
        for k in 1..<halfNDesign {
            specReal[k] = Float(mag[k])
            specImag[k] = 0
        }

        // Inverse FFT on packed halfNDesign spectrum (use designSize log2n)
        specReal.withUnsafeMutableBufferPointer { specRealBuf in
            specImag.withUnsafeMutableBufferPointer { specImagBuf in
                var sc = DSPSplitComplex(realp: specRealBuf.baseAddress!, imagp: specImagBuf.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2nDesign, Int32(FFT_INVERSE))

                // Unpack halfNDesign complex pairs into N real time-domain samples
                var timeDomain = [Float](repeating: 0, count: N)
                timeDomain.withUnsafeMutableBufferPointer { tdBuf in
                    tdBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfNDesign) { cBuf in
                        vDSP_ztoc(&sc, 1, cBuf, 2, vDSP_Length(halfNDesign))
                    }
                }

                // Scale by 1/N on the correctly-unpacked N-length buffer
                var invN = Float(1.0 / Float(N))
                var scaled = [Float](repeating: 0, count: N)
                vDSP_vsmul(&timeDomain, 1, &invN, &scaled, 1, vDSP_Length(N))

                // Build causal, zero-padded kernel of length kernelLength (designSize).
                // The kernel is centered within the shorter window to maintain linear phase,
                // but the overall response is causal (support in [0, kernelLength)) to satisfy
                // the overlap-save constraint. This eliminates circular-convolution aliasing.
                // `scaled` is designSize samples long; `causalKernel` is fftSize samples long
                // (designSize taps of real content + fftSize - designSize samples of zero padding).
                let L = kernelLength
                let center = L / 2
                var causalKernel = [Float](repeating: 0, count: fftSize)  // indices [L, fftSize) stay 0

                var window = [Float](repeating: 0, count: L)
                for i in 0..<L {
                    let x = 2.0 * Double.pi * Double(i) / Double(L - 1)
                    window[i] = Float(0.355768 - 0.487396 * cos(x) + 0.144232 * cos(2*x) - 0.012604 * cos(3*x))
                }

                for i in 0..<L {
                    // Pull from `scaled` centered at index 0 (with wraparound), offset so the
                    // response's peak lands at `center` instead of at N/2. `scaled` is the
                    // already-normalized (1/N) true impulse response computed just above.
                    let srcIndex = ((i - center) % N + N) % N
                    causalKernel[i] = scaled[srcIndex] * window[i]
                }

                // Re-pack causal fftSize-length buffer into halfN split-complex form before forward FFT
                var shiftedReal = [Float](repeating: 0, count: halfN)
                var shiftedImag = [Float](repeating: 0, count: halfN)
                causalKernel.withUnsafeMutableBufferPointer { shiftBuf in
                    shiftBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cBuf in
                        shiftedReal.withUnsafeMutableBufferPointer { shiftedRealBuf in
                            shiftedImag.withUnsafeMutableBufferPointer { shiftedImagBuf in
                                var packSC = DSPSplitComplex(realp: shiftedRealBuf.baseAddress!, imagp: shiftedImagBuf.baseAddress!)
                                vDSP_ctoz(cBuf, 2, &packSC, 1, vDSP_Length(halfN))
                            }
                        }
                    }
                }

                // Forward FFT on packed halfN buffer (use fftSize log2n), and copy the result to outReal/outImag —
                // both happen inside this same closure so the pointers are guaranteed to refer
                // to shiftedReal/shiftedImag (the actual final result), not an outer shadowed name.
                shiftedReal.withUnsafeMutableBufferPointer { shiftedRealBuf in
                    shiftedImag.withUnsafeMutableBufferPointer { shiftedImagBuf in
                        var fwdSC = DSPSplitComplex(realp: shiftedRealBuf.baseAddress!, imagp: shiftedImagBuf.baseAddress!)
                        vDSP_fft_zrip(setup, &fwdSC, 1, log2n, Int32(FFT_FORWARD))

                        memcpy(outReal, shiftedRealBuf.baseAddress!, halfN * MemoryLayout<Float>.size)
                        memcpy(outImag, shiftedImagBuf.baseAddress!, halfN * MemoryLayout<Float>.size)
                    }
                }
            }
        }
    }

    private static func alloc(_ count: Int) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        p.initialize(repeating: 0, count: count)
        return p
    }
    private static func free(_ p: UnsafeMutablePointer<Float>) {
        p.deallocate()
    }
}
