import SwiftUI

// MARK: - Cleanup Delegate

@MainActor
final class AppCleanupDelegate: NSObject, NSApplicationDelegate {
    private weak var store: EqualiserStore?
    var openEqualiserWindow: (() -> Void)?

    func setStore(_ store: EqualiserStore) {
        self.store = store
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openEqualiserWindow?()
        }
        return true
    }
}

// MARK: - Main App

@main
struct EqualiserMain: App {
    @StateObject private var store = EqualiserStore()
    @StateObject private var windowActivation = WindowActivationController()
    @NSApplicationDelegateAdaptor(AppCleanupDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        // IMPORTANT: Do NOT access @StateObject (self.store) here.
        // SwiftUI initializes @StateObject AFTER init() completes.
        // Accessing it in init() causes SwiftUI to create two instances.
        // Wire appDelegate.setStore(store) in body using .onAppear instead.

        // Note: Microphone permission is NOT requested here.
        // It's only requested when needed (HAL input capture mode or manual mode).
        // Shared memory capture (default) does NOT require microphone permission.
    }

    var body: some Scene {
        // Main EQ settings window (hidden by default, opened on demand)
        Window("Notch Sixty", id: "equaliser") {
            EQWindowView()
                .environmentObject(store)
                .environmentObject(windowActivation)
                .onAppear {
                    bootstrapAppDelegate()
                }
        }
        .defaultPosition(.center)
        .defaultSize(width: 1060, height: 530)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(store.interfaceStyle == .dock ? .presented : .suppressed)
        .commands {
            // Cmd+B: Toggle bypass
            CommandGroup(replacing: .toolbar) {
                Button("Toggle Bypass") {
                    store.isBypassed.toggle()
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Save Preset") {
                    NotificationCenter.default.post(name: .savePresetShortcut, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }

        // Menu bar popover (always available)
        MenuBarExtra(isInserted: Binding(
            get: { store.interfaceStyle != .dock },
            set: { _ in } // presence is controlled by the picker, not by user dismissal
        )) {
            MenuBarContentView()
                .environmentObject(store)
                .environmentObject(windowActivation)
                .onAppear {
                    bootstrapAppDelegate()
                }
        } label: {
            Image(nsImage: {
                let img = NSImage(named: "MenuBarIcon")
                    ?? NSImage(systemSymbolName: "slider.vertical.3",
                               accessibilityDescription: "Notch Sixty")!
                img.isTemplate = true
                return img
            }())
        }
        .menuBarExtraStyle(.window)

        // Settings window (Cmd+,)
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(windowActivation)
                .onAppear {
                    bootstrapAppDelegate()
                }
        }
    }

    private func bootstrapAppDelegate() {
        appDelegate.setStore(store)
        appDelegate.openEqualiserWindow = { openWindow(id: "equaliser") }
        store.onInterfaceStyleChanged = { [weak windowActivation] style in
            windowActivation?.setInterfaceStyle(style)
        }
        windowActivation.setInterfaceStyle(store.interfaceStyle)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let savePresetShortcut = Notification.Name("savePresetShortcut")
}
