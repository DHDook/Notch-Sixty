// SpectralDenoiser.swift — corrected
// Fixes: IFFT output unpacking (ztoc), N-point windowing with prev-hop buffer,
// synthesis window (WOLA), DC/Nyquist gating, inputAccum clearing.

import Accelerate
import Atomics
import Foundation

final class SpectralDenoiser: @unchecked Sendable {

    // MARK: - Configuration
    private static let fftSize: Int = 1024  // N
    private static let hopSize: Int = 512   // N/2 — 50% overlap
    private static let halfN:   Int = fftSize / 2

    // MARK: - FFT
    private let log2n:    vDSP_Length
    private let fftSetup: FFTSetup

    // MARK: - Pre-computed N-point Hann window
    private let hannWindow: [Float]  // length N, used for both analysis and synthesis

    // MARK: - Buffers
    // FIX #2: prevHop stores the previous hop so we can form the full N-point frame.
    nonisolated(unsafe) private var prevHop:       [Float]  // length hopSize
    nonisolated(unsafe) private var inputAccum:    [Float]  // length hopSize (current hop)
    nonisolated(unsafe) private var accumPos:      Int = 0
    nonisolated(unsafe) private var outputOverlap: [Float]  // length N
    nonisolated(unsafe) private var workReal:      [Float]  // length N
    nonisolated(unsafe) private var workImag:      [Float]  // length N

    // MARK: - Output ring
    nonisolated(unsafe) private var outRing:     [Float]    // length N * 2
    nonisolated(unsafe) private var outWritePos: Int = 0
    nonisolated(unsafe) private var outReadPos:  Int = 0

    // MARK: - Threshold
    private let _thresholdLinearBits: ManagedAtomic<Int32>

    // MARK: - Init
    init() {
        let N  = Self.fftSize
        let hop = Self.hopSize
        log2n    = vDSP_Length(log2(Double(N)).rounded())
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        // Pre-compute N-point Hann window once.
        // Using N-1 in the denominator gives w[0]=0, w[N-1]=0 (periodic Hann).
        var hann = [Float](repeating: 0, count: N)
        for i in 0..<N {
            hann[i] = 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / Float(N - 1)))
        }
        hannWindow = hann

        prevHop       = [Float](repeating: 0, count: hop)
        inputAccum    = [Float](repeating: 0, count: hop)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        outRing       = [Float](repeating: 0, count: N * 2)

        _thresholdLinearBits = ManagedAtomic(Self.floatBits(pow(10.0, -60.0 / 20.0)))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    // MARK: - Main Thread
    func setThresholdDB(_ db: Float) {
        let linear = pow(10.0, db / 20.0)
        _thresholdLinearBits.store(Self.floatBits(linear), ordering: .relaxed)
    }

    // MARK: - Audio Thread
    func reset() {
        let N   = Self.fftSize
        let hop = Self.hopSize
        prevHop       = [Float](repeating: 0, count: hop)
        inputAccum    = [Float](repeating: 0, count: hop)
        outputOverlap = [Float](repeating: 0, count: N)
        workReal      = [Float](repeating: 0, count: N)
        workImag      = [Float](repeating: 0, count: N)
        outRing       = [Float](repeating: 0, count: N * 2)
        outWritePos   = 0
        outReadPos    = 0
        accumPos      = 0
    }

    @inline(__always)
    func process(buffer: UnsafeMutablePointer<Float>, count: Int) {
        let N         = Self.fftSize
        let hop       = Self.hopSize
        let halfN     = Self.halfN
        let ringSize  = outRing.count
        let threshold = Self.bitsToFloat(_thresholdLinearBits.load(ordering: .relaxed))

        var srcPos = 0
        while srcPos < count {
            let chunk = min(hop - accumPos, count - srcPos)
            for i in 0..<chunk { inputAccum[accumPos + i] = buffer[srcPos + i] }
            accumPos += chunk
            srcPos   += chunk

            if accumPos == hop {

                // FIX #2: Form the full N-point analysis frame [prevHop | currentHop]
                // and apply the N-point Hann window to all N samples.
                for i in 0..<hop    { workReal[i]       = prevHop[i]     * hannWindow[i] }
                for i in 0..<hop    { workReal[hop + i] = inputAccum[i]  * hannWindow[hop + i] }
                workImag = [Float](repeating: 0, count: N)

                // Save current hop as prevHop for the next frame.
                for i in 0..<hop { prevHop[i] = inputAccum[i] }

                // FIX #5: Clear inputAccum explicitly.
                for i in 0..<hop { inputAccum[i] = 0 }
                accumPos = 0

                // Forward FFT (vDSP_fft_zrip — ctoz packs real data into split-complex).
                workReal.withUnsafeMutableBufferPointer { rp in
                    workImag.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ctoz(cBuf, 2, &sc, 1, vDSP_Length(halfN))
                        }
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_FORWARD))

                        // FIX #4: Handle DC (realp[0]) and Nyquist (imagp[0]) independently.
                        // zrip packing: realp[0] = DC (real), imagp[0] = Nyquist (real).
                        if abs(rp[0]) < threshold { rp[0] = 0 }  // DC
                        if abs(ip[0]) < threshold { ip[0] = 0 }  // Nyquist

                        // Gate bins 1..halfN-1 (complex pairs).
                        for k in 1..<halfN {
                            let mag = sqrt(rp[k] * rp[k] + ip[k] * ip[k])
                            if mag < threshold { rp[k] = 0; ip[k] = 0 }
                        }

                        // Inverse FFT.
                        vDSP_fft_zrip(fftSetup, &sc, 1, log2n, Int32(FFT_INVERSE))

                        // Scale by 1/N (vDSP_fft_zrip inverse output is scaled by N).
                        var scale: Float = 1.0 / Float(N)
                        vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1,
                                   vDSP_Length(halfN))
                        vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1,
                                   vDSP_Length(halfN))

                        // FIX #1: Convert split-complex back to interleaved real (ztoc).
                        // After IFFT, realp[k]=x[2k] and imagp[k]=x[2k+1].
                        // ztoc interleaves them back into a contiguous real array.
                        rp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                           capacity: halfN) { cBuf in
                            vDSP_ztoc(&sc, 1, cBuf, 2, vDSP_Length(halfN))
                        }
                        // workReal[0..N-1] now holds the N interleaved real output samples.
                    }
                }

                // FIX #3: Apply synthesis Hann window before overlap-add (WOLA).
                // For Hann analysis + Hann synthesis at 50% overlap, the combined
                // response is Hann² which sums to a constant (COLA-2 / power complementary).
                for i in 0..<N { workReal[i] *= hannWindow[i] }

                // Overlap-add into outputOverlap.
                for i in 0..<N { outputOverlap[i] += workReal[i] }

                // Write the first hop of the overlap buffer to the output ring.
                for i in 0..<hop {
                    outRing[outWritePos] = outputOverlap[i]
                    outWritePos = (outWritePos + 1) % ringSize
                }

                // Shift: second half of overlap becomes the new first half.
                for i in 0..<hop { outputOverlap[i] = outputOverlap[hop + i] }
                for i in hop..<N { outputOverlap[i] = 0 }
            }
        }

        // Read count samples from the output ring.
        for i in 0..<count {
            buffer[i] = outRing[outReadPos]
            outRing[outReadPos] = 0
            outReadPos = (outReadPos + 1) % ringSize
        }
    }

    // MARK: - Helpers
    private static func floatBits(_ f: Float) -> Int32 {
        Int32(bitPattern: f.bitPattern)
    }
    private static func bitsToFloat(_ bits: Int32) -> Float {
        Float(bitPattern: UInt32(bitPattern: bits))
    }
}
