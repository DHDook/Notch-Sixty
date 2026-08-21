import SwiftUI

/// RTA Analyser window view with stacked panes.
struct RTAWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "RTA Analyser",
                isEnabled: meterStore.rtaEnabled,
                onToggle: { meterStore.rtaEnabled = $0 }
            )
            RTADashboardView(
                analyzer: store.rtaAnalyzer,
                metersEnabled: meterStore.rtaEnabled,
                paneLayout: .stacked
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            meterStore.rtaEnabled = true
            store.rtaAnalyzer.rtaWindowBecameVisible(id: "rta-window")
        }
        .onDisappear {
            meterStore.rtaEnabled = false
            store.rtaAnalyzer.rtaWindowBecameHidden(id: "rta-window")
        }
    }
}
