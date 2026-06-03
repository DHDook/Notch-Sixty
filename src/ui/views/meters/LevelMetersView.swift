import SwiftUI

struct LevelMetersView: View {
    let meterStore: MeterStore
    
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            StereoMeterGroup(
                title: "Peak In",
                meterStore: meterStore,
                leftType: .inputPeakLeft,
                rightType: .inputPeakRight,
                showScale: true
            )
            StereoMeterGroup(
                title: "Peak Out",
                meterStore: meterStore,
                leftType: .outputPeakLeft,
                rightType: .outputPeakRight,
                showScale: true
            )
            
            StereoMeterGroupRMS(
                title: "RMS In",
                meterStore: meterStore,
                leftType: .inputRMSLeft,
                rightType: .inputRMSRight,
                showScale: true
            )
            StereoMeterGroupRMS(
                title: "RMS Out",
                meterStore: meterStore,
                leftType: .outputRMSLeft,
                rightType: .outputRMSRight,
                showScale: true
            )
        }
    }
}

struct GainControlsView: View {
    let inputGain: Float
    let outputGain: Float
    let onInputGainChange: (Float) -> Void
    let onOutputGainChange: (Float) -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                Text("Gain In")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                GainStepperControl(
                    gain: inputGain,
                    onGainChange: onInputGainChange
                )
            }
            
            VStack(spacing: 6) {
                Text("Gain Out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                GainStepperControl(
                    gain: outputGain,
                    onGainChange: onOutputGainChange
                )
            }
        }
    }
}

struct ChannelBalanceSlider: View {
    @Binding var balance: Float

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                VStack(spacing: 0) {
                    Text("L")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(balancePercentage(for: balance, channel: .left))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .leading)
                }
                CustomBalanceSlider(
                    balance: Binding(
                        get: { Double(balance) },
                        set: { newValue in
                            // Sticky center behavior
                            let centerThreshold = 0.05
                            if abs(newValue) < centerThreshold {
                                balance = 0.0
                            } else {
                                balance = Float(newValue)
                            }
                        }
                    ),
                    range: -1.0...1.0
                )
                VStack(spacing: 0) {
                    Text("R")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(balancePercentage(for: balance, channel: .right))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            Text("Balance")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private enum Channel {
        case left, right
    }

    private func balancePercentage(for value: Float, channel: Channel) -> String {
        let absValue = abs(value)
        if absValue < 0.01 {
            return "0%"
        }
        let percentage = Int(absValue * 100)
        return "\(percentage)%"
    }
}

struct CustomBalanceSlider: View {
    @Binding var balance: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track (gray when centered, blue when off-center)
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                    .frame(height: 4)

                // Fill track
                GeometryReader { fillGeometry in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fillColor)
                        .frame(width: fillWidth(in: fillGeometry.size), height: 4)
                }

                // Thumb
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: thumbOffset(in: geometry.size))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newValue = valueAt(position: value.location, in: geometry.size)
                        balance = newValue
                    }
            )
        }
        .frame(height: 20)
    }

    private var trackColor: Color {
        Color.secondary.opacity(0.3)
    }

    private var fillColor: Color {
        if abs(balance) < 0.05 {
            return Color.secondary.opacity(0.3)
        }
        return Color.accentColor.opacity(0.6)
    }

    private func fillWidth(in size: CGSize) -> CGFloat {
        let normalizedValue = (balance - range.lowerBound) / (range.upperBound - range.lowerBound)
        return size.width * CGFloat(normalizedValue)
    }

    private func thumbOffset(in size: CGSize) -> CGFloat {
        let normalizedValue = (balance - range.lowerBound) / (range.upperBound - range.lowerBound)
        return size.width * CGFloat(normalizedValue) - 6
    }

    private func valueAt(position: CGPoint, in size: CGSize) -> Double {
        let normalizedPosition = max(0, min(1, position.x / size.width))
        return range.lowerBound + normalizedPosition * (range.upperBound - range.lowerBound)
    }
}

struct StereoMeterGroup: View {
    let title: String
    let meterStore: MeterStore
    let leftType: MeterType
    let rightType: MeterType
    var showScale: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            HStack(alignment: .top, spacing: 4) {
                if showScale {
                    MeterScaleView(height: MeterConstants.meterHeight)
                }
                PeakMeter(
                    channelLabel: "L",
                    meterStore: meterStore,
                    meterType: leftType
                )
                PeakMeter(
                    channelLabel: "R",
                    meterStore: meterStore,
                    meterType: rightType
                )
            }
        }
    }
}

struct PeakMeter: View {
    let channelLabel: String
    let meterStore: MeterStore
    let meterType: MeterType
    
    var body: some View {
        VStack(spacing: 4) {
            PeakMeterNSView(meterStore: meterStore, meterType: meterType)
                .frame(width: 18, height: 126)
            
            Text(channelLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct RMSMeter: View {
    let channelLabel: String
    let meterStore: MeterStore
    let meterType: MeterType
    
    var body: some View {
        VStack(spacing: 4) {
            RMSMeterNSView(meterStore: meterStore, meterType: meterType)
                .frame(width: 14, height: 126)
            
            Text(channelLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct StereoMeterGroupRMS: View {
    let title: String
    let meterStore: MeterStore
    let leftType: MeterType
    let rightType: MeterType
    var showScale: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
            HStack(alignment: .top, spacing: 4) {
                if showScale {
                    MeterScaleView(height: MeterConstants.meterHeight)
                }
                RMSMeter(
                    channelLabel: "L",
                    meterStore: meterStore,
                    meterType: leftType
                )
                RMSMeter(
                    channelLabel: "R",
                    meterStore: meterStore,
                    meterType: rightType
                )
            }
        }
    }
}
