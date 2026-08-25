import SwiftUI

/// Left/right VU gauges only — no header controls (those live in
/// VUControlsRow, composed alongside the window launchers in EQWindowView).
struct VUMeterPairView: View {
    @ObservedObject var meterStore: MeterStore
    @State private var sourceKey: UUID = UUID()

    var body: some View {
        HStack(spacing: 19) {
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
        .frame(width: 220, height: 90)
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
        .frame(width: 220, height: 90)
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

    var body: some View {
        HStack(spacing: 8) {
            Text("VU")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Picker("", selection: $meterStore.vuMeterSource) {
                Text("In").tag(VUSource.input)
                Text("Out").tag(VUSource.output)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 70)

            Toggle("", isOn: $meterStore.vuMetersEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
