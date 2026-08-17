import SwiftUI

/// VU meter pair view with header controls.
/// Displays left and right VU meters with input/output source selection and enable toggle.
struct VUMeterPairView: View {
    @ObservedObject var meterStore: MeterStore
    @State private var sourceKey: UUID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            metersRow
        }
        .frame(width: 333, alignment: .leading)
        .id(sourceKey)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("VU")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: $meterStore.vuMeterSource) {
                Text("In").tag(VUSource.input)
                Text("Out").tag(VUSource.output)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 70)
            .onChange(of: meterStore.vuMeterSource) { _, _ in
                // Force view recreation to re-register observers
                sourceKey = UUID()
            }

            Toggle("", isOn: $meterStore.vuMetersEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Spacer()

            helpButton
        }
    }

    private var metersRow: some View {
        HStack(spacing: 12) {
            leftMeter
            rightMeter
        }
    }

    private var leftMeter: some View {
        VUMeterNSView(
            meterStore: meterStore,
            meterType: meterStore.vuMeterSource == .input ? .inputVULeft : .outputVULeft,
            channelLabel: "L"
        )
        .frame(height: 120)
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
        .frame(height: 120)
        .opacity(meterStore.vuMetersEnabled ? 1.0 : 0.35)
        .saturation(meterStore.vuMetersEnabled ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: meterStore.vuMetersEnabled)
    }

    private var helpButton: some View {
        Button {
            // Show help popover
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("VU meters with analog ballistics. Shows average level with slower response than peak meters.")
    }
}
