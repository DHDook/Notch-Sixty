import SwiftUI

/// Analytics meters window view.
/// Contains Gain Structure, Phase Correlation, Crest Factor, ISP Latch, DR Factor, Bit Stream, Bit Rate, True Peak, and Stereo Goniometer.
struct AnalyticsMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore
    @StateObject private var inlineMeterBridge = InlineMeterBridge()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowMetersToggleHeader(
                title: "Meters",
                isEnabled: meterStore.remainingMetersEnabled,
                onToggle: { meterStore.remainingMetersEnabled = $0 }
            )
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
            .opacity(meterStore.remainingMetersEnabled ? 1.0 : 0.35)
            .saturation(meterStore.remainingMetersEnabled ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.25), value: meterStore.remainingMetersEnabled)
            .allowsHitTesting(meterStore.remainingMetersEnabled)
        }
        .frame(minWidth: 500, minHeight: 600)
        .onAppear {
            meterStore.remainingMetersEnabled = true
            meterStore.meterWindowBecameVisible(id: "analytics-window")
            inlineMeterBridge.register(with: meterStore, equaliserStore: store)
        }
        .onDisappear {
            meterStore.remainingMetersEnabled = false
            meterStore.meterWindowBecameHidden(id: "analytics-window")
        }
    }
}
