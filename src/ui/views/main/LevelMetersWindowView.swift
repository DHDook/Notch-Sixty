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
            LevelMetersView(meterStore: meterStore)
                .padding(20)
        }
        .onAppear {
            meterStore.levelMetersEnabled = true
            meterStore.meterWindowBecameVisible(id: "levels-window")
        }
        .onDisappear {
            meterStore.levelMetersEnabled = false
            meterStore.meterWindowBecameHidden(id: "levels-window")
        }
    }
}
