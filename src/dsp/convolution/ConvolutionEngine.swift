//
//  ConvolutionEngine.swift
//  Equaliser
//
//  Uniformly-partitioned FFT convolution engine.
//

import Foundation
import Accelerate
import Atomics

/// Uniformly-partitioned FFT convolution engine for FIR impulse response processing.
final class ConvolutionEngine {
    
    // MARK: - Configuration
    private static let partitionSize: Int = 512  // B
    private static let fftSize: Int = 1024       // N = 2B
    private static let halfN: Int = fftSize / 2
    private static let log2n: vDSP_Length = vDSP_Length(log2(Double(fftSize)))
    
    // MARK: - FFT setup
    private let fftSetup: FFTSetup
    
    // MARK: - IR storage (frequency-domain partitions)
    // P = ceil(irLength / B) partitions per channel
    private var partitionCount: Int = 0
    nonisolated(unsafe) private var leftIRSpectra: [DSPSplitComplex] = []
    nonisolated(unsafe) private var rightIRSpectra: [DSPSplitComplex] = []
    
    // MARK: - Audio-thread state (input history ring + overlap buffer)
    // Input history ring: P partitions, each N-point complex spectrum
    nonisolated(unsafe) private var leftInputHistory: [DSPSplitComplex] = []
    nonisolated(unsafe) private var rightInputHistory: [DSPSplitComplex] = []
    nonisolated(unsafe) private var inputHistoryPos: Int = 0
    
    // Current partition buffer (time-domain, B samples)
    nonisolated(unsafe) private var currentPartitionL: [Float]
    nonisolated(unsafe) private var currentPartitionR: [Float]
    nonisolated(unsafe) private var currentPartitionPos: Int = 0
    
    // Output overlap buffer (B samples)
    nonisolated(unsafe) private var outputOverlapL: [Float]
    nonisolated(unsafe) private var outputOverlapR: [Float]
    
    // Scratch buffers for FFT/IFFT (N-point)
    nonisolated(unsafe) private var fftReal: [Float]
    nonisolated(unsafe) private var fftImag: [Float]
    
    // MARK: - Pending IR swap (main-thread → audio-thread)
    private let _pendingIRSwap: ManagedAtomic<Bool>
    nonisolated(unsafe) private var pendingLeftIRSpectra: [DSPSplitComplex] = []
    nonisolated(unsafe) private var pendingRightIRSpectra: [DSPSplitComplex] = []
    nonisolated(unsafe) private var pendingPartitionCount: Int = 0
    
    // MARK: - Enable flag
    private let _enabled: ManagedAtomic<Int32>
    
    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        
        currentPartitionL = [Float](repeating: 0, count: Self.partitionSize)
        currentPartitionR = [Float](repeating: 0, count: Self.partitionSize)
        outputOverlapL = [Float](repeating: 0, count: Self.partitionSize)
        outputOverlapR = [Float](repeating: 0, count: Self.partitionSize)
        fftReal = [Float](repeating: 0, count: Self.fftSize)
        fftImag = [Float](repeating: 0, count: Self.fftSize)
        
        _pendingIRSwap = ManagedAtomic(false)
        _enabled = ManagedAtomic(0)
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        
        // Deallocate split-complex storage
        for sc in leftIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in rightIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in pendingLeftIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in pendingRightIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in leftInputHistory {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in rightInputHistory {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
    }
    
    /// Updates the impulse response for both channels (main thread only).
    func updateIR(left: [Float], right: [Float]) {
        let P = max(1, (max(left.count, right.count) + Self.partitionSize - 1) / Self.partitionSize)
        
        // Allocate and compute pending spectra
        var pendingLeft: [DSPSplitComplex] = []
        var pendingRight: [DSPSplitComplex] = []
        
        for _ in 0..<P {
            pendingLeft.append(allocateSplitComplex())
            pendingRight.append(allocateSplitComplex())
        }
        
        // Partition and FFT left IR
        partitionAndFFT(ir: left, spectra: pendingLeft, partitionCount: P)
        
        // Partition and FFT right IR
        partitionAndFFT(ir: right, spectra: pendingRight, partitionCount: P)
        
        // Store pending spectra
        pendingLeftIRSpectra = pendingLeft
        pendingRightIRSpectra = pendingRight
        pendingPartitionCount = P
        
        // Signal audio thread to swap
        _pendingIRSwap.store(true, ordering: .releasing)
    }
    
    /// Enables or disables convolution processing (main thread only).
    func setEnabled(_ enabled: Bool) {
        _enabled.store(enabled ? 1 : 0, ordering: .relaxed)
    }
    
    /// Resets all audio-thread state (clears history and overlap buffers).
    func reset() {
        currentPartitionPos = 0
        inputHistoryPos = 0
        
        for i in 0..<currentPartitionL.count { currentPartitionL[i] = 0 }
        for i in 0..<currentPartitionR.count { currentPartitionR[i] = 0 }
        for i in 0..<outputOverlapL.count { outputOverlapL[i] = 0 }
        for i in 0..<outputOverlapR.count { outputOverlapR[i] = 0 }
        
        // Zero input history spectra
        for sc in leftInputHistory {
            vDSP_vclr(sc.realp, 1, vDSP_Length(Self.fftSize))
            vDSP_vclr(sc.imagp, 1, vDSP_Length(Self.fftSize))
        }
        for sc in rightInputHistory {
            vDSP_vclr(sc.realp, 1, vDSP_Length(Self.fftSize))
            vDSP_vclr(sc.imagp, 1, vDSP_Length(Self.fftSize))
        }
    }
    
    /// Processes audio buffers through the convolution engine (audio thread only).
    func process(bufL: UnsafeMutablePointer<Float>, bufR: UnsafeMutablePointer<Float>?, frameCount: Int) {
        guard _enabled.load(ordering: .relaxed) != 0 else { return }
        guard partitionCount > 0 else { return }
        
        // Check for pending IR swap
        if _pendingIRSwap.load(ordering: .acquiring) {
            swapPendingIR()
            reset()
        }
        
        var srcPos = 0
        while srcPos < frameCount {
            let chunk = min(Self.partitionSize - currentPartitionPos, frameCount - srcPos)
            
            // Buffer samples into current partition
            for i in 0..<chunk {
                currentPartitionL[currentPartitionPos + i] = bufL[srcPos + i]
                if let bufR = bufR {
                    currentPartitionR[currentPartitionPos + i] = bufR[srcPos + i]
                }
            }
            currentPartitionPos += chunk
            srcPos += chunk
            
            // When partition is full, process it
            if currentPartitionPos == Self.partitionSize {
                processPartition(bufR: bufR)
                currentPartitionPos = 0
            }
        }
        
        // Drain overlap buffer to output
        let drainCount = min(frameCount, Self.partitionSize)
        for i in 0..<drainCount {
            bufL[i] = outputOverlapL[i]
            if let bufR = bufR {
                bufR[i] = outputOverlapR[i]
            }
            outputOverlapL[i] = 0
            outputOverlapR[i] = 0
        }
    }
    
    // MARK: - Private methods
    
    private func allocateSplitComplex() -> DSPSplitComplex {
        let realPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.fftSize)
        let imagPtr = UnsafeMutablePointer<Float>.allocate(capacity: Self.fftSize)
        realPtr.initialize(repeating: 0, count: Self.fftSize)
        imagPtr.initialize(repeating: 0, count: Self.fftSize)
        return DSPSplitComplex(realp: realPtr, imagp: imagPtr)
    }
    
    private func partitionAndFFT(ir: [Float], spectra: [DSPSplitComplex], partitionCount: Int) {
        let B = Self.partitionSize
        let N = Self.fftSize
        
        for p in 0..<partitionCount {
            var sc = spectra[p]
            
            // Clear buffer
            vDSP_vclr(sc.realp, 1, vDSP_Length(N))
            vDSP_vclr(sc.imagp, 1, vDSP_Length(N))
            
            // Copy partition into real part (zero-padded to N)
            let startIdx = p * B
            let copyCount = min(B, ir.count - startIdx)
            if copyCount > 0 {
                for i in 0..<copyCount {
                    sc.realp[i] = ir[startIdx + i]
                }
            }
            
            // FFT
            vDSP_fft_zrip(fftSetup, &sc, 1, Self.log2n, Int32(FFT_FORWARD))
        }
    }
    
    private func swapPendingIR() {
        // Deallocate old spectra
        for sc in leftIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        for sc in rightIRSpectra {
            sc.realp.deallocate()
            sc.imagp.deallocate()
        }
        
        // Allocate new input history if partition count changed
        if partitionCount != pendingPartitionCount {
            for sc in leftInputHistory {
                sc.realp.deallocate()
                sc.imagp.deallocate()
            }
            for sc in rightInputHistory {
                sc.realp.deallocate()
                sc.imagp.deallocate()
            }
            
            leftInputHistory = []
            rightInputHistory = []
            for _ in 0..<pendingPartitionCount {
                leftInputHistory.append(allocateSplitComplex())
                rightInputHistory.append(allocateSplitComplex())
            }
        }
        
        // Swap spectra
        leftIRSpectra = pendingLeftIRSpectra
        rightIRSpectra = pendingRightIRSpectra
        partitionCount = pendingPartitionCount
        
        // Clear pending
        pendingLeftIRSpectra = []
        pendingRightIRSpectra = []
        pendingPartitionCount = 0
        
        _pendingIRSwap.store(false, ordering: .relaxed)
    }
    
    private func processPartition(bufR: UnsafeMutablePointer<Float>?) {
        let N = Self.fftSize
        let halfN = Self.halfN
        let P = partitionCount
        
        // Zero current partition in FFT buffer
        vDSP_vclr(fftReal.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
        vDSP_vclr(fftImag.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
        
        // Copy current partition into FFT buffer (zero-padded)
        for i in 0..<Self.partitionSize {
            fftReal[i] = currentPartitionL[i]
        }
        
        // FFT current partition
        fftReal.withUnsafeMutableBufferPointer { rp in
            fftImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &sc, 1, Self.log2n, Int32(FFT_FORWARD))
                
                // Store in input history ring
                let histIdx = inputHistoryPos
                leftInputHistory[histIdx].realp.withMemoryRebound(to: Float.self, capacity: N) { dst in
                    memcpy(dst, rp.baseAddress!, N * MemoryLayout<Float>.size)
                }
                leftInputHistory[histIdx].imagp.withMemoryRebound(to: Float.self, capacity: N) { dst in
                    memcpy(dst, ip.baseAddress!, N * MemoryLayout<Float>.size)
                }
                
                // Process right channel if present
                if !currentPartitionR.allSatisfy({ $0 == 0 }) {
                    vDSP_vclr(sc.realp, 1, vDSP_Length(N))
                    vDSP_vclr(sc.imagp, 1, vDSP_Length(N))
                    for i in 0..<Self.partitionSize {
                        sc.realp[i] = currentPartitionR[i]
                    }
                    vDSP_fft_zrip(fftSetup, &sc, 1, Self.log2n, Int32(FFT_FORWARD))
                    rightInputHistory[histIdx].realp.withMemoryRebound(to: Float.self, capacity: N) { dst in
                        memcpy(dst, rp.baseAddress!, N * MemoryLayout<Float>.size)
                    }
                    rightInputHistory[histIdx].imagp.withMemoryRebound(to: Float.self, capacity: N) { dst in
                        memcpy(dst, ip.baseAddress!, N * MemoryLayout<Float>.size)
                    }
                }
            }
        }
        
        inputHistoryPos = (inputHistoryPos + 1) % P
        
        // Accumulate convolution across all partitions
        vDSP_vclr(fftReal.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
        vDSP_vclr(fftImag.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
        
        for p in 0..<P {
            let histIdx = (inputHistoryPos - p + P) % P
            
            // Left channel
            fftReal.withUnsafeMutableBufferPointer { rp in
                fftImag.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    var irSC = leftIRSpectra[p]
                    vDSP_zvmul(&leftInputHistory[histIdx], 1, &irSC, 1, &sc, 1, vDSP_Length(halfN), 0)
                }
            }
        }
        
        // IFFT
        fftReal.withUnsafeMutableBufferPointer { rp in
            fftImag.withUnsafeMutableBufferPointer { ip in
                var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &sc, 1, Self.log2n, Int32(FFT_INVERSE))
                
                // Normalize
                var scale: Float = 1.0 / Float(2 * N)
                vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(halfN))
                vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(halfN))
            }
        }
        
        // Add first B samples to overlap buffer (left channel)
        for i in 0..<Self.partitionSize {
            outputOverlapL[i] += fftReal[i]
        }
        
        // Process right channel if needed
        if let bufR = bufR {
            vDSP_vclr(fftReal.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
            vDSP_vclr(fftImag.withUnsafeMutableBufferPointer { $0.baseAddress! }, 1, vDSP_Length(N))
            
            for p in 0..<P {
                let histIdx = (inputHistoryPos - p + P) % P
                fftReal.withUnsafeMutableBufferPointer { rp in
                    fftImag.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        var irSC = rightIRSpectra[p]
                        vDSP_zvmul(&rightInputHistory[histIdx], 1, &irSC, 1, &sc, 1, vDSP_Length(halfN), 0)
                    }
                }
            }
            
            fftReal.withUnsafeMutableBufferPointer { rp in
                fftImag.withUnsafeMutableBufferPointer { ip in
                    var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &sc, 1, Self.log2n, Int32(FFT_INVERSE))
                    var scale: Float = 1.0 / Float(2 * N)
                    vDSP_vsmul(rp.baseAddress!, 1, &scale, rp.baseAddress!, 1, vDSP_Length(halfN))
                    vDSP_vsmul(ip.baseAddress!, 1, &scale, ip.baseAddress!, 1, vDSP_Length(halfN))
                }
            }
            
            for i in 0..<Self.partitionSize {
                outputOverlapR[i] += fftReal[i]
            }
        }
    }
}
