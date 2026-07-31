import AppKit

@MainActor
protocol ActivationPolicyApplying {
    func apply(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
struct NSApplicationActivationPolicyApplier: ActivationPolicyApplying {
    func apply(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }
}

@MainActor
final class WindowActivationController: ObservableObject {
    private let policyApplier: ActivationPolicyApplying
    private var currentPolicy: NSApplication.ActivationPolicy?
    private var interfaceStyle: InterfaceStyle = .both

    init(policyApplier: ActivationPolicyApplying = NSApplicationActivationPolicyApplier()) {
        self.policyApplier = policyApplier
    }

    /// Called once at launch (with the restored preference) and again any time
    /// the user changes the picker in Settings.
    func setInterfaceStyle(_ style: InterfaceStyle) {
        interfaceStyle = style
        reapply()
    }

    func prepareToShowWindow() {
        // Tray style must never show a Dock icon, even transiently while a window opens.
        guard interfaceStyle != .tray else { return }
        apply(.regular)
    }

    private func reapply() {
        apply(interfaceStyle == .tray ? .accessory : .regular)
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard currentPolicy != policy else { return }
        currentPolicy = policy
        policyApplier.apply(policy)
    }
}
