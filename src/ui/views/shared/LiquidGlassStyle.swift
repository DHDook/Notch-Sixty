import SwiftUI

/// Shared presentation primitives for the macOS 27 Liquid Glass interface.
///
/// Glass is reserved for controls and navigation surfaces. Graphs, meters, and
/// other information-dense content keep their opaque backgrounds so that live
/// audio data remains legible in every appearance.
enum LiquidGlassStyle {
    static let mainWindowHeight: CGFloat = 608
    static let panelRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12
    static let contentPadding: CGFloat = 10
    /// Vertical gap between stacked glass panels. Deliberately smaller than
    /// contentPadding: this is empty space between two separate panels, not the
    /// margin between content and its own panel's glass edge, so it can be tighter
    /// without crowding the glass material itself.
    static let panelGap: CGFloat = 6
    /// Keeps the meter controls visually separated from the EQ curve without
    /// leaving a full control-row gap beneath the final launcher button.
    static let meterCurveDividerPadding: CGFloat = 4
    /// Exact width every panel's inner content is pinned to (window width 1400,
    /// minus 12pt outer horizontal padding each side, minus 10pt contentPadding
    /// each side = 1356). All three panels use this exact value rather than
    /// maxWidth: .infinity — the middle panel's row depends on flexible Spacers to
    /// create breathing room around its controls, and maxWidth: .infinity doesn't
    /// reliably guarantee three independently-laid-out rows converge on the same
    /// resolved width. An exact, shared width removes that ambiguity outright.
    /// Widened from 1256 — the top panel's DynamicsInlineView has no width ceiling
    /// on its column4 Dither picker (Off/TPDF/Shape/5th, wider than its Stereo/
    /// Latency Mode siblings in the same column), so 1256 wasn't enough room for
    /// that picker plus the preamp column without visible crowding. NOTE: this
    /// value is summed into the window's locked width in EQWindowView.swift and
    /// EqualiserApp.swift — if this number changes again, those need to change by
    /// the same amount (new window width = this value + 44).
    static let panelContentWidth: CGFloat = 1356
    /// Fixed height for the EQ band grid's glass panel. EQBandGridView contains a
    /// GeometryReader (for width-based centering), which has no intrinsic height of
    /// its own, so this section needs an explicit height from its parent rather than
    /// inheriting whatever space happens to be left over. Tightened from 280 — 260
    /// sits closer to the sliders' actual content height (175pt track plus
    /// header/readout rows). NOTE: this value is summed into the window's locked
    /// height in EQWindowView.swift and EqualiserApp.swift (Tasks 7–8) — if this
    /// number changes again later, those two need to change by the same amount.
    static let bandGridHeight: CGFloat = 260
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
