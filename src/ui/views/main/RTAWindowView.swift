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
            .disabled(!meterStore.metersEnabled)
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
                        meterStore.rtaEnabled = false
                        store.rtaAnalyzer.rtaWindowBecameHidden(id: "rta-window")
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        store.rtaAnalyzer.rtaWindowBecameVisible(id: "rta-window")
                    }
                }
            }
        )
    }
}
