import SwiftUI

/// Shared presentation primitives for the macOS 27 Liquid Glass interface.
///
/// Glass is reserved for controls and navigation surfaces. Graphs, meters, and
/// other information-dense content keep their opaque backgrounds so that live
/// audio data remains legible in every appearance.
enum LiquidGlassStyle {
    static let windowWidth: CGFloat = 1300
    static let windowHeight: CGFloat = 660
    static let windowPadding: CGFloat = 10
    static let panelRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12
    static let contentPadding: CGFloat = 12
    /// Vertical gap between stacked glass panels. Deliberately smaller than
    /// contentPadding: this is empty space between two separate panels, not the
    /// margin between content and its own panel's glass edge, so it can be tighter
    /// without crowding the glass material itself.
    static let panelGap: CGFloat = 6
    /// Fixed height for the EQ band grid's glass panel. EQBandGridView contains a
    /// GeometryReader (for width-based centering), which has no intrinsic height of
    /// its own, so this section needs an explicit height from its parent rather than
    /// inheriting whatever space happens to be left over. This matches the band
    /// card's intrinsic height so `contentPadding` remains visible on both edges.
    static let bandGridHeight: CGFloat = 258

    /// Keeps every panel on the same horizontal bounds, even when a panel's
    /// controls have a larger intrinsic width than the window can accommodate.
    static let panelWidth = windowWidth - (windowPadding * 2)
    static let panelContentWidth = panelWidth - (contentPadding * 2)
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
