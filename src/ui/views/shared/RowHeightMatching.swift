import SwiftUI

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports this view's rendered height up the tree, for use with
    /// .equalRowHeight(_:) on the containing HStack.
    func reportRowHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: RowHeightKey.self, value: geo.size.height)
            }
        )
    }

    /// Sizes this view (an HStack) to the max height reported by children
    /// that called .reportRowHeight() — makes unequal siblings resolve to
    /// the same row height instead of leaving a gap after the shorter one.
    func equalRowHeight(_ height: Binding<CGFloat>) -> some View {
        self
            .onPreferenceChange(RowHeightKey.self) { height.wrappedValue = $0 }
            .frame(height: height.wrappedValue > 0 ? height.wrappedValue : nil)
    }
}
