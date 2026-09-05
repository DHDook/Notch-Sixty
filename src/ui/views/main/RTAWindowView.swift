import SwiftUI

/// RTA Analyser window view with stacked panes.
struct RTAWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore
    @State private var windowObservers: [NSObjectProtocol] = []

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "RTA Analyser",
                isEnabled: meterStore.rtaEnabled,
                masterMetersEnabled: meterStore.metersEnabled,
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
            store.rtaAnalyzer.rtaWindowBecameVisible(id: "rta-window")
        }
        .onDisappear {
            meterStore.rtaEnabled = false
            store.rtaAnalyzer.rtaWindowBecameHidden(id: "rta-window")
            NotificationCenter.default.removeObservers(windowObservers)
            windowObservers.removeAll()
        }
        .background(
            WindowAccessor { window in
                NotificationCenter.default.removeObservers(windowObservers)
                windowObservers.removeAll()
                guard let window = window else { return }
                let miniaturizeToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        meterStore.rtaEnabled = false
                        store.rtaAnalyzer.rtaWindowBecameHidden(id: "rta-window")
                    }
                }
                let deminiaturizeToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        store.rtaAnalyzer.rtaWindowBecameVisible(id: "rta-window")
                    }
                }
                windowObservers = [miniaturizeToken, deminiaturizeToken]
            }
        )
    }
}
