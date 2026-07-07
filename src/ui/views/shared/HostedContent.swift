import SwiftUI
import AppKit

/// Hosts SwiftUI content in its own independent NSHostingView (its own
/// ViewGraph), so that frequent internal updates via @Published/
/// @ObservedObject don't force the surrounding window's static content
/// through a full AppKit relayout pass. A single NSHostingView means a
/// single ViewGraph; restructuring SwiftUI-level HStack/VStack nesting
/// alone does not create this isolation — only a genuinely separate
/// NSHostingView does.
///
/// Give the SwiftUI-side usage of this wrapper an explicit, stable
/// `.frame(width:height:)` (or `.frame(maxWidth: .infinity)` for content
/// that legitimately needs to flex with window width) so the outer layout
/// has a known size to reason about and never needs to re-query this view's
/// intrinsic size on every internal update.
struct HostedContent<Content: View>: NSViewRepresentable {
    let content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        return hostingView
    }

    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
        nsView.rootView = content()
    }
}
