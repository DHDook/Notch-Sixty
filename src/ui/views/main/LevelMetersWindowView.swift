import SwiftUI

/// Peak & RMS Meters window view.
struct LevelMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore
    @ObservedObject var meterStore: MeterStore

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "Peak & RMS Meters",
                isEnabled: meterStore.levelMetersEnabled,
                onToggle: { meterStore.levelMetersEnabled = $0 }
            )
            .disabled(!meterStore.metersEnabled)
            LevelMetersView(meterStore: meterStore)
                .padding(20)
        }
        .onAppear {
            meterStore.meterWindowBecameVisible(id: "levels-window")
        }
        .onDisappear {
            meterStore.levelMetersEnabled = false
            meterStore.meterWindowBecameHidden(id: "levels-window")
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
                        meterStore.levelMetersEnabled = false
                        meterStore.meterWindowBecameHidden(id: "levels-window")
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        meterStore.meterWindowBecameVisible(id: "levels-window")
                    }
                }
            }
        )
    }
}
