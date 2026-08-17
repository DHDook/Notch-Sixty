import SwiftUI

// MARK: - Cleanup Delegate

@MainActor
final class AppCleanupDelegate: NSObject, NSApplicationDelegate {
    private weak var store: EqualiserStore?
    var openEqualiserWindow: (() -> Void)?

    func setStore(_ store: EqualiserStore) {
        self.store = store
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Notch Sixty is a tray/menu-bar utility app: closing the window (traffic lights)
        // must never quit the app, in any interface style. The user quits explicitly via
        // Cmd+Q, the tray's Quit button, or the Dock icon's context menu.
        false
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
        .defaultSize(width: 1060, height: 450)
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
                let img = NSImage(named: "TrayIcon")
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

        // RTA Analyser window
        Window("RTA Analyser", id: "rta-window") {
            RTAWindowView()
                .environmentObject(store)
                .environmentObject(windowActivation)
        }
        .defaultPosition(.center)
        .defaultSize(width: 600, height: 500)
        .windowResizability(.contentSize)

        // Peak & RMS Meters window
        Window("Peak & RMS Meters", id: "levels-window") {
            LevelMetersWindowView()
                .environmentObject(store)
                .environmentObject(windowActivation)
        }
        .defaultPosition(.center)
        .defaultSize(width: 400, height: 350)
        .windowResizability(.contentSize)

        // Analytics meters window
        Window("Meters", id: "analytics-window") {
            AnalyticsMetersWindowView()
                .environmentObject(store)
                .environmentObject(windowActivation)
        }
        .defaultPosition(.center)
        .defaultSize(width: 500, height: 650)
        .windowResizability(.contentSize)
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
