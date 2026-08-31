import SwiftUI

struct WindowMetersToggleHeader: View {
    let title: String
    let isEnabled: Bool
    let masterMetersEnabled: Bool
    let onToggle: (Bool) -> Void

    @State private var showMasterDisabledAlert = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            ZStack {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!masterMetersEnabled)

                // Catches taps the disabled Toggle above would otherwise
                // silently swallow, so we can explain why it's frozen.
                if !masterMetersEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showMasterDisabledAlert = true
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .alert("Master Meters Is Off", isPresented: $showMasterDisabledAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Turn on the master “Meters” toggle before enabling this meter cluster.")
        }
    }
}
