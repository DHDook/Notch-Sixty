import SwiftUI

/// Left/right VU gauges only — no header controls (those live in
/// VUControlsRow, composed alongside the window launchers in EQWindowView).
struct VUMeterPairView: View {
    @ObservedObject var meterStore: MeterStore
    /// Target combined width for both gauges plus the gap between them.
    /// Defaults to the original hardcoded size so any other call site that
    /// doesn't pass this keeps its current appearance.
    var totalWidth: CGFloat = 312
    @State private var sourceKey: UUID = UUID()

    private static let baseMeterWidth: CGFloat = 150
    private static let baseMeterHeight: CGFloat = 62
    private static let interMeterGap: CGFloat = 12

    /// Each meter's width, derived from totalWidth. Floors at the original
    /// 150 so meters never render smaller than the pre-migration size.
    private var meterWidth: CGFloat {
        max(Self.baseMeterWidth, (totalWidth - Self.interMeterGap) / 2)
    }

    /// Height scaled by the same factor as width, preserving the original
    /// 150:62 aspect ratio exactly.
    private var meterHeight: CGFloat {
        meterWidth * (Self.baseMeterHeight / Self.baseMeterWidth)
    }

    var body: some View {
        HStack(spacing: Self.interMeterGap) {
            leftMeter
            rightMeter
        }
        .id(sourceKey)
        .onChange(of: meterStore.vuMeterSource) { _, _ in
            sourceKey = UUID()
        }
    }

    private var leftMeter: some View {
        VUMeterNSView(
            meterStore: meterStore,
            meterType: meterStore.vuMeterSource == .input ? .inputVULeft : .outputVULeft,
            channelLabel: "L"
        )
        .frame(width: meterWidth, height: meterHeight)
        .background(Color.black)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .gray.opacity(0.45)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 3
                )
        )
        .opacity(meterStore.vuMetersEnabled ? 1.0 : 0.35)
        .saturation(meterStore.vuMetersEnabled ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: meterStore.vuMetersEnabled)
    }

    private var rightMeter: some View {
        VUMeterNSView(
            meterStore: meterStore,
            meterType: meterStore.vuMeterSource == .input ? .inputVURight : .outputVURight,
            channelLabel: "R"
        )
        .frame(width: meterWidth, height: meterHeight)
        .background(Color.black)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .gray.opacity(0.45)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 3
                )
        )
        .opacity(meterStore.vuMetersEnabled ? 1.0 : 0.35)
        .saturation(meterStore.vuMetersEnabled ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: meterStore.vuMetersEnabled)
    }
}

/// VU header controls — In/Out source, enable toggle, help. Now lives in
/// the combined controls/launcher stack rather than above the gauges.
struct VUControlsRow: View {
    @ObservedObject var meterStore: MeterStore
    @State private var showMasterDisabledAlert = false

    var body: some View {
        HStack(spacing: 8) {
            Text("VU")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ZStack {
                Picker("", selection: $meterStore.vuMeterSource) {
                    Text("In").tag(VUSource.input)
                    Text("Out").tag(VUSource.output)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 70)
                .disabled(!meterStore.metersEnabled)

                if !meterStore.metersEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showMasterDisabledAlert = true
                        }
                }
            }

            ZStack {
                Toggle("", isOn: $meterStore.vuMetersEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!meterStore.metersEnabled)

                if !meterStore.metersEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showMasterDisabledAlert = true
                        }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .alert("Master Meters Is Off", isPresented: $showMasterDisabledAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Turn on the master “Meters” toggle before enabling this meter cluster.")
        }
    }
}
