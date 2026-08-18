import SwiftUI

struct WindowMetersToggleHeader: View {
    let title: String
    let isEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
