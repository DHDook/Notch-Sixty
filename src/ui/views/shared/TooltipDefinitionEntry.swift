import SwiftUI

/// A single bold-title + description row for definition-style tooltip
/// popovers. Matches the format already used by the Dynamics section's
/// "?" popover (see `definitionEntry` in `DynamicsView.swift`), so every
/// tooltip in the EQ window shares one visual language. Pair with a
/// `Divider()` between entries in the containing `VStack`.
struct TooltipDefinitionEntry: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
