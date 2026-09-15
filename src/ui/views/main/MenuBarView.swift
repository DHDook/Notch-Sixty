import SwiftUI

/// The menu bar popover content - quick access controls.
/// Designed with compact controls: each control (label + picker) in its own row.
struct MenuBarContentView: View {
    @EnvironmentObject var store: EqualiserStore
    @EnvironmentObject var windowActivation: WindowActivationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    
    /// View model for routing status and device selection.
    private var routingViewModel: RoutingViewModel {
        RoutingViewModel(store: store)
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                headerSection

                controlGroupSection
                    .padding(LiquidGlassStyle.contentPadding)
                    .liquidGlassPanel()

                actionButtonsSection
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            Image(nsImage: {
                let img = NSImage(named: "TrayIcon")
                    ?? NSImage(systemSymbolName: "slider.vertical.3",
                               accessibilityDescription: "Notch Sixty")!
                img.isTemplate = true
                return img
            }())
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notch Sixty")
                    .font(.headline)
                Text("System audio equaliser")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Control Groups

    private var controlGroupSection: some View {
        VStack(spacing: 14) {
            statusRow

            // Show device pickers in manual mode
            if routingViewModel.manualModeEnabled {
                DevicePickerView(layout: .vertical)
            }

            presetPickerRow
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack {
            HStack(spacing: 4) {
                Circle()
                    .fill(routingViewModel.statusColor)
                    .frame(width: 8, height: 8)
                Text(routingViewModel.simplifiedStatusText)
                    .font(.subheadline)
            }
            Spacer()
            SystemEQToggleView(style: SystemEQToggleView.Style.menuBar)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Preset Picker Row

    private var presetPickerRow: some View {
        HStack {
            Text("Preset")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            CompactPresetPicker()
        }
    }

    // MARK: - Action Buttons (each in own section like mockup)

    private var actionButtonsSection: some View {
        HStack(spacing: 10) {
            Button {
                windowActivation.prepareToShowWindow()
                openWindow(id: "equaliser")
                NSApp.activate(ignoringOtherApps: true)
                dismiss()
            } label: {
                Label("Open Notch Sixty", systemImage: "slider.vertical.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .accessibilityLabel("Quit")
            }
            .buttonStyle(.glass)
            .help("Quit Notch Sixty")
        }
    }
}

// #Preview("Menu Bar") {
//     MenuBarContentView()
//         .environmentObject(EqualiserStore())
// }
