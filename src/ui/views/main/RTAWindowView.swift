import SwiftUI

/// RTA Analyser window view with stacked panes.
struct RTAWindowView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "RTA Analyser",
                isEnabled: store.meterStore.rtaEnabled,
                onToggle: { store.meterStore.rtaEnabled = $0 }
            )
            RTADashboardView(
                analyzer: store.rtaAnalyzer,
                metersEnabled: store.meterStore.rtaEnabled,
                paneLayout: .stacked
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            store.meterStore.rtaEnabled = true
            store.rtaAnalyzer.rtaWindowBecameVisible(id: "rta-window")
        }
        .onDisappear {
            store.meterStore.rtaEnabled = false
            store.rtaAnalyzer.rtaWindowBecameHidden(id: "rta-window")
        }
    }
}
