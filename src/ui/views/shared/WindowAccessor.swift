import SwiftUI
import AppKit

/// A view that captures its containing NSWindow and passes it to a callback.
/// Use this to get a reference to the parent window for visibility checking.
///
/// `onWindowFound` is invoked only when the resolved window actually changes
/// (nil -> window, or window A -> window B) rather than on every SwiftUI
/// update pass. `updateNSView` runs on every body re-evaluation of the host
/// view, so without this guard, any work done inside `onWindowFound` (such as
/// registering a NotificationCenter observer) would repeat and accumulate
/// without bound for as long as the window is open.
struct WindowAccessor: NSViewRepresentable {
    let onWindowFound: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window will be available after the view is added to the view hierarchy
        DispatchQueue.main.async {
            notifyIfChanged(view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        notifyIfChanged(nsView.window, coordinator: context.coordinator)
    }

    private func notifyIfChanged(_ window: NSWindow?, coordinator: Coordinator) {
        guard window !== coordinator.lastWindow else { return }
        coordinator.lastWindow = window
        onWindowFound(window)
    }

    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

extension NotificationCenter {
    /// Removes multiple previously-registered block-based observer tokens.
    /// Pairs with call sites that store the return value of
    /// `addObserver(forName:object:queue:using:)` for later cleanup.
    func removeObservers(_ tokens: [NSObjectProtocol]) {
        tokens.forEach(removeObserver)
    }
}
