import SwiftUI

/// Peak & RMS Meters window view.
struct LevelMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        VStack(spacing: 0) {
            WindowMetersToggleHeader(
                title: "Peak & RMS Meters",
                isEnabled: store.meterStore.levelMetersEnabled,
                onToggle: { store.meterStore.levelMetersEnabled = $0 }
            )
            LevelMetersView(meterStore: store.meterStore)
                .padding(20)
        }
        .onAppear {
            store.meterStore.levelMetersEnabled = true
        }
        .onDisappear {
            store.meterStore.levelMetersEnabled = false
        }
    }
}
