import SwiftUI

/// RTA Analyser window view with stacked panes.
struct RTAWindowView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        RTADashboardView(
            analyzer: store.rtaAnalyzer,
            metersEnabled: store.meterStore.rtaEnabled,
            paneLayout: .stacked
        )
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            store.meterStore.rtaEnabled = true
        }
        .onDisappear {
            store.meterStore.rtaEnabled = false
        }
    }
}
