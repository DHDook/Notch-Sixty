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
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        GainStructureMeterView()
                        InlineBitStreamView(bridge: inlineMeterBridge)
                    }
                    .frame(width: 220, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        InlinePhaseCorrelationView()
                        InlineCrestFactorView(bridge: inlineMeterBridge)
                        InlineDRFactorView(bridge: inlineMeterBridge)
                        HStack(spacing: 16) {
                            InlineIspLatchView(bridge: inlineMeterBridge)
                            InlineTruePeakView(bridge: inlineMeterBridge)
                        }
                        InlineTruePeakMeterView()
                    }
                    .frame(width: 220, alignment: .leading)
                }

                Divider()

                StereoGoniometerView(engine: store.goniometerEngine, isBypassed: store.isBypassed)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 12)
            .opacity(meterStore.remainingMetersEnabled ? 1.0 : 0.35)
            .saturation(meterStore.remainingMetersEnabled ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.25), value: meterStore.remainingMetersEnabled)
            .allowsHitTesting(meterStore.remainingMetersEnabled)
        }
        .frame(minWidth: 500, minHeight: 500)
        .onAppear {
            meterStore.remainingMetersEnabled = true
            meterStore.meterWindowBecameVisible(id: "analytics-window")
            inlineMeterBridge.register(with: meterStore, equaliserStore: store)
        }
        .onDisappear {
            meterStore.remainingMetersEnabled = false
            meterStore.meterWindowBecameHidden(id: "analytics-window")
        }
        .background(
            WindowAccessor { window in
                guard let window = window else { return }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        meterStore.remainingMetersEnabled = false
                        meterStore.meterWindowBecameHidden(id: "analytics-window")
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        meterStore.remainingMetersEnabled = true
                        meterStore.meterWindowBecameVisible(id: "analytics-window")
                    }
                }
            }
        )
    }
}
