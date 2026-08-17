import SwiftUI

/// Peak & RMS Meters window view.
struct LevelMetersWindowView: View {
    @EnvironmentObject var store: EqualiserStore

    var body: some View {
        LevelMetersView(meterStore: store.meterStore)
            .frame(minWidth: 400, minHeight: 300)
            .onAppear {
                store.meterStore.levelMetersEnabled = true
            }
            .onDisappear {
                store.meterStore.levelMetersEnabled = false
            }
    }
}
