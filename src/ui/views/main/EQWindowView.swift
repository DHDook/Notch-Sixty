import SwiftUI
import Combine

/// The main EQ settings window - detailed controls.
struct EQWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var store: EqualiserStore
    @EnvironmentObject var windowActivation: WindowActivationController
    @StateObject private var driverManager = DriverManager.shared
    @State private var showCompareHelp = false
    @State private var showSnapshotCompareHelp = false
    @State private var showChannelHelp = false
    @State private var metersEnabledUI = true
    @State private var showSnapshotCompare = false
    @State private var localVolume: Float = 1.0
    @State private var localIsMuted: Bool = false
    @State private var showDriverSheet = true
    @State private var showSaveSheet = false
    @State private var showStateResetAlert = false

    /// Whether the driver installation overlay should be shown.
    private var needsDriverInstallation: Bool {
        !driverManager.isReady && !store.routingCoordinator.manualModeEnabled
    }

    /// Whether the driver needs updating (outdated version).
    private var needsDriverUpdate: Bool {
        store.showDriverUpdateRequired && !store.routingCoordinator.manualModeEnabled
    }

    /// View model for routing status.
    private var routingViewModel: RoutingViewModel {
        RoutingViewModel(store: store)
    }

    /// View model for EQ configuration.
    private var eqViewModel: EQViewModel {
        EQViewModel(store: store)
    }

    // MARK: - Column Views

    /// Preamp and volume controls column.
    private var preampVolumeColumn: some View {
        VStack(spacing: 12) {
            GainControlsView(
                inputGain: store.inputGain,
                outputGain: store.outputGain,
                onInputGainChange: { store.updateInputGain($0) },
                onOutputGainChange: { store.updateOutputGain($0) }
            )

            ChannelBalanceSlider(
                balance: Binding(
                    get: { store.dynamicsConfig.channelBalance },
                    set: { store.updateChannelBalance($0) }
                )
            )

            MasterVolumeSlider(
                volume: Binding(
                    get: {
                        if store.routingStatus.isActive {
                            return store.routingCoordinator.masterVolume
                        } else {
                            return localVolume
                        }
                    },
                    set: { newVolume in
                        if store.routingStatus.isActive {
                            store.routingCoordinator.setMasterVolume(newVolume)
                        } else {
                            localVolume = newVolume
                        }
                    }
                ),
                isMuted: Binding(
                    get: {
                        if store.routingStatus.isActive {
                            return store.routingCoordinator.isMuted
                        } else {
                            return localIsMuted
                        }
                    },
                    set: { newMuted in
                        if store.routingStatus.isActive {
                            store.routingCoordinator.setMuted(newMuted)
                        } else {
                            localIsMuted = newMuted
                        }
                    }
                )
            )
        }
    }

    /// Meters and EQ curve column.
    private var metersAndCurveColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.meterStore.levelMetersEnabled {
                LevelMetersView(meterStore: store.meterStore)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .opacity(metersEnabledUI ? 1.0 : 0.35)
                    .saturation(metersEnabledUI ? 1.0 : 0.0)
                    .animation(.easeInOut(duration: 0.25), value: metersEnabledUI)
            }

            EQCurveView(metersEnabled: metersEnabledUI)
                .frame(width: 333, alignment: .leading)
                // .padding(.top, 4) — removed; scale canvas height provides sufficient separation
        }
    }

    /// Manual routing column (device pickers + routing toggle).
    private var manualRoutingColumn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            DevicePickerView()

            ToggleWithHelp(
                label: "Audio Routing",
                isOn: Binding(
                    get: { routingViewModel.isActive },
                    set: { newValue in
                        if newValue {
                            store.reconfigureRouting()
                        } else {
                            store.stopRouting()
                        }
                    }
                ),
                helpText: "Enable or disable audio routing between the selected input and output devices. Both devices must be selected to enable routing."
            )
            .disabled(!routingViewModel.canToggleRouting)
            .errorTint({
                if case .error = store.routingStatus { return true }
                return false
            }())
        }
        .frame(minWidth: 376)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top section: 8-column layout
            HStack(alignment: .top, spacing: 12) {
                preampVolumeColumn
                Divider()
                metersAndCurveColumn
                Divider()
                DynamicsInlineView()
                if routingViewModel.manualModeEnabled {
                    Divider()
                    manualRoutingColumn
                }
            }

            // Dual 31-band real-time spectrum analyser
            RTADashboardView(analyzer: store.rtaAnalyzer, metersEnabled: metersEnabledUI)
                .padding(.top, -8)

            Divider()

            // Preset and band controls toolbar
            HStack(alignment: .top) {
                PresetToolbar()
                    .frame(minWidth: 280, maxWidth: 280, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Compare")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            showSnapshotCompareHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSnapshotCompareHelp, arrowEdge: .trailing) {
                            VStack(alignment: .leading, spacing: 10) {
                                TooltipDefinitionEntry(
                                    title: "A/B/C/D Snapshot Compare",
                                    detail: "Save up to four full EQ configurations and switch between them instantly for A/B comparison."
                                )
                                Divider()
                                TooltipDefinitionEntry(
                                    title: "Click to Recall",
                                    detail: "Click a lettered slot to load its saved EQ."
                                )
                                Divider()
                                TooltipDefinitionEntry(
                                    title: "Right-Click to Save or Clear",
                                    detail: "Right-click a slot to save the current EQ into it, or to clear it."
                                )
                            }
                            .padding(12)
                            .frame(width: 280)
                        }
                    }

                    HStack(spacing: 4) {
                        Toggle("", isOn: $showSnapshotCompare)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                        if showSnapshotCompare {
                            HStack(spacing: 2) {
                                ForEach(["A", "B", "C", "D"], id: \.self) { key in
                                    Button(action: {
                                        store.restoreSnapshot(key: key)
                                    }) {
                                        Text(key)
                                            .font(.system(size: 11, weight: .medium))
                                            .frame(width: 18, height: 20)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .background(store.selectedSnapshotKey == key ? Color.accentColor.opacity(0.3) : Color.clear)
                                    .overlay(
                                        store.snapshots[key] != nil ?
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 4, height: 4)
                                                .offset(x: 6, y: -8)
                                            : nil
                                    )
                                    .contextMenu {
                                        Button("Save Current EQ to Slot \(key)") {
                                            store.saveSnapshot(key: key)
                                        }
                                        if store.snapshots[key] != nil {
                                            Divider()
                                            Button("Clear Slot \(key)", role: .destructive) {
                                                store.clearSnapshot(key: key)
                                            }
                                        }
                                    }
                                    .help("Click to recall slot \(key). Right-click to save or clear.")
                                }
                            }
                        }
                    }
                }

                Spacer()
                Spacer()
                    .frame(width: 192)

                VStack(spacing: 4) {
                    Text("Bands")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BandCountControl()
                }

                Spacer()
                    .frame(width: 128)

                HStack(spacing: 12) {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Channel")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                showChannelHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showChannelHelp, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 10) {
                                    TooltipDefinitionEntry(
                                        title: "Linked",
                                        detail: "One EQ curve applied equally to both channels."
                                    )
                                    Divider()
                                    TooltipDefinitionEntry(
                                        title: "Stereo",
                                        detail: "Independent left and right EQ curves. Use the Edit picker to choose which channel you're editing."
                                    )
                                    Divider()
                                    TooltipDefinitionEntry(
                                        title: "M/S",
                                        detail: "Independent Mid (center, L+R) and Side (width, L−R) EQ curves. Use the Edit picker to choose which one you're editing."
                                    )
                                }
                                .padding(12)
                                .frame(width: 300)
                            }
                        }
                        Picker("", selection: $store.channelMode) {
                            Text("Linked").tag(ChannelMode.linked)
                            Text("Stereo").tag(ChannelMode.stereo)
                            Text("M/S").tag(ChannelMode.midSide)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 145)
                    }

                    if store.channelMode == .stereo || store.channelMode == .midSide {
                        VStack(spacing: 4) {
                            Text("Edit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if store.channelMode == .stereo {
                                Picker("", selection: $store.channelFocus) {
                                    Text("L").tag(ChannelFocus.left)
                                    Text("R").tag(ChannelFocus.right)
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(width: 60)
                            } else {
                                Picker("", selection: $store.channelFocus) {
                                    Text("Mid").tag(ChannelFocus.mid)
                                    Text("Side").tag(ChannelFocus.side)
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(width: 80)
                            }
                        }
                    }

                    Spacer()

                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                showCompareHelp = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $showCompareHelp, arrowEdge: .trailing) {
                                VStack(alignment: .leading, spacing: 10) {
                                    TooltipDefinitionEntry(title: "EQ", detail: "Full biquad IIR processing. Minimum latency.")
                                    Divider()
                                    TooltipDefinitionEntry(title: "Linear", detail: "Zero-phase FIR convolution EQ. Eliminates phase distortion entirely at the cost of increased latency and pre-ringing artefacts.")
                                    Divider()
                                    TooltipDefinitionEntry(title: "Mixed", detail: "Biquad EQ with all-pass phase correction. Reduces phase distortion without pre-ringing or added latency. A practical middle ground between EQ and Linear modes.")
                                    Divider()
                                    TooltipDefinitionEntry(title: "Flat", detail: "Bypasses EQ at matched volume to audition unprocessed audio. Reverts automatically after 5 minutes.")
                                    Divider()
                                    TooltipDefinitionEntry(title: "Delta", detail: "Solos the EQ difference signal to hear the processed effect.")
                                }
                                .padding(12)
                                .frame(width: 320)
                            }
                        }

                        Picker("", selection: $store.compareMode) {
                            Text("EQ").tag(CompareMode.eq)
                            Text("Linear").tag(CompareMode.linearEQ)
                            Text("Mixed").tag(CompareMode.mixedPhase)
                            Text("Flat").tag(CompareMode.flat)
                            Text("Delta").tag(CompareMode.delta)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 225)
                    }

                    VStack(spacing: 4) {
                        Text("Flatten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(0)
                        Button {
                            store.flattenBands()
                        } label: {
                            Text("Flatten")
                                .frame(width: 40, height: 16)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reset all gains to 0 dB while keeping current band configuration")
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)

            EQBandGridView()
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .frame(minWidth: 1280, minHeight: 700)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VStack(spacing: 2) {
                    Text("Master")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { !store.isBypassed },
                        set: { store.isBypassed = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Enable or disable EQ processing. When disabled, audio passes through without EQ applied.")
                }
                .frame(minWidth: 40, alignment: .center)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .padding(.leading, 4)
                .padding(.trailing, 8)

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .frame(height: 20)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .frame(minWidth: 40, alignment: .center)
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
        .background(
            WindowAccessor { window in
                store.setEqualiserWindow(window)
            }
        )
        .onAppear {
            windowActivation.windowBecameVisible(.equaliser)
            store.meterStore.windowBecameVisible()
            metersEnabledUI = store.meterStore.metersEnabled
            showStateResetAlert = store.didResetStateOnLaunch
        }
        .onChange(of: metersEnabledUI) { _, newValue in
            store.meterStore.metersEnabled = newValue
        }
        .onReceive(store.meterStore.$metersEnabled.removeDuplicates()) { value in
            if metersEnabledUI != value { metersEnabledUI = value }
        }
        .onDisappear {
            windowActivation.windowBecameHidden(.equaliser)
            store.meterStore.windowBecameHidden()
        }
        .sheet(isPresented: $showDriverSheet) {
            DriverInstallationView(
                onInstall: {
                    store.handleDriverInstalled()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
            .environmentObject(store)
            .frame(minWidth: 500, minHeight: 400)
        }
        .onChange(of: needsDriverInstallation) { _, newValue in
            showDriverSheet = newValue
        }
        .onChange(of: needsDriverUpdate) { _, newValue in
            if newValue {
                openSettings()
            }
        }
        .onAppear {
            showDriverSheet = needsDriverInstallation
            if needsDriverUpdate {
                openSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .savePresetShortcut)) { _ in
            showSaveSheet = true
        }
        .sheet(isPresented: $showSaveSheet) {
            SavePresetSheet()
                .environmentObject(store)
        }
        .alert("Settings Reset to Defaults", isPresented: $showStateResetAlert) {
            Button("OK") {
                store.didResetStateOnLaunch = false
            }
        } message: {
            Text("Your saved settings could not be loaded and have been reset to defaults. This can happen after certain app updates. Your previous settings file has been preserved in UserDefaults for diagnosis.")
        }
    }
}

struct SystemEQToggleView: View {
    enum Style {
        case standard
        case menuBar
    }

    @EnvironmentObject var store: EqualiserStore
    var style: Style = .standard

    var body: some View {
        switch style {
        case .standard:
            ToggleWithHelp(
                label: "System EQ",
                isOn: binding,
                helpText: "Enable or disable the equalizer processing. When disabled, audio passes through without EQ applied."
            )
        case .menuBar:
            Toggle("System EQ", isOn: binding)
                .controlSize(.small)
                .toggleStyle(.switch)
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { !store.isBypassed },
            set: { store.isBypassed = !$0 }
        )
    }
}

#Preview("EQ Window") {
    EQWindowView()
        .environmentObject(EqualiserStore())
        .environmentObject(WindowActivationController())
}
