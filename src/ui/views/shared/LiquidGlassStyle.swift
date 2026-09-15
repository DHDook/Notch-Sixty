import SwiftUI

/// Shared presentation primitives for the macOS 27 Liquid Glass interface.
///
/// Glass is reserved for controls and navigation surfaces. Graphs, meters, and
/// other information-dense content keep their opaque backgrounds so that live
/// audio data remains legible in every appearance.
enum LiquidGlassStyle {
    static let panelRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12
    static let contentPadding: CGFloat = 12
}

extension View {
    /// Places a related group of controls on a native, appearance-aware glass surface.
    func liquidGlassPanel(
        cornerRadius: CGFloat = LiquidGlassStyle.panelRadius
    ) -> some View {
        glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
