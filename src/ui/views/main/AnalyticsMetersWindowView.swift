import SwiftUI

/// Analytics meters window view.
/// Contains Gain Structure, Phase Correlation, Crest Factor, ISP Latch, DR Factor, Bit Stream, Bit Rate, True Peak, and Stereo Goniometer.
struct AnalyticsMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @StateObject private var inlineMeterBridge = InlineMeterBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowMetersToggleHeader(
                title: "Meters",
                isEnabled: store.meterStore.remainingMetersEnabled,
                onToggle: { store.meterStore.remainingMetersEnabled = $0 }
            )
            if store.meterStore.remainingMetersEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    GainStructureMeterView()
                    InlinePhaseCorrelationView()
                    InlineCrestFactorView(bridge: inlineMeterBridge)
                    InlineIspLatchView(bridge: inlineMeterBridge)
                    InlineDRFactorView(bridge: inlineMeterBridge)
                    InlineBitStreamView(bridge: inlineMeterBridge)
                    InlineBitRateView()
                    InlineTruePeakView(bridge: inlineMeterBridge)
                    InlineTruePeakMeterView()
                    StereoGoniometerView(engine: store.goniometerEngine, isBypassed: store.isBypassed)
                }
                .padding(.horizontal, 12)
            } else {
                Text("Meters Disabled")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            store.meterStore.remainingMetersEnabled = true
            inlineMeterBridge.register(with: store.meterStore, equaliserStore: store)
        }
        .onDisappear {
            store.meterStore.remainingMetersEnabled = false
        }
    }
}
