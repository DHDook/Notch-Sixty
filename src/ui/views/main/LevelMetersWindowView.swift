import SwiftUI

/// Peak & RMS Meters window view.
struct LevelMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore
    @State private var windowObservers: [NSObjectProtocol] = []

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "Peak & RMS Meters",
                isEnabled: meterStore.levelMetersEnabled,
                masterMetersEnabled: meterStore.metersEnabled,
                onToggle: { meterStore.levelMetersEnabled = $0 }
            )
            LevelMetersView(meterStore: meterStore)
                .padding(20)
        }
        .onAppear {
            meterStore.meterWindowBecameVisible(id: "levels-window")
        }
        .onDisappear {
            meterStore.levelMetersEnabled = false
            meterStore.meterWindowBecameHidden(id: "levels-window")
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
                        meterStore.levelMetersEnabled = false
                        meterStore.meterWindowBecameHidden(id: "levels-window")
                    }
                }
                let deminiaturizeToken = NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        meterStore.meterWindowBecameVisible(id: "levels-window")
                    }
                }
                windowObservers = [miniaturizeToken, deminiaturizeToken]
            }
        )
    }
}
