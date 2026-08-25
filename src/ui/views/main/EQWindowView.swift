import SwiftUI
import Combine

/// The main EQ settings window - detailed controls.
struct EQWindowView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
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
    @State private var infoPopoverWindowId: String? = nil
    @State private var vuRowHeight: CGFloat = 0
    @State private var chipWidth: CGFloat = 0

    private struct MeterDefinition {
        let title: String
        let body: String
    }

    /// Whether the driver installation overlay should be shown.
    private var needsDriverInstallation: Bool {
        !driverManager.isReady && !store.routingCoordinator.manualModeEnabled
    }

    /// Whether the driver needs updating (outdated version).
    private var needsDriverUpdate: Bool {
        store.showDriverUpdateRequired && !store.routingCoordinator.manualModeEnabled
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

    /// VU meters and EQ curve column.
    private var vuAndCurveColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    VUMeterPairView(meterStore: store.meterStore)
                        .opacity(metersEnabledUI ? 1.0 : 0.35)
                        .saturation(metersEnabledUI ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.25), value: metersEnabledUI)

                    VUControlsRow(meterStore: store.meterStore)
                }
                .reportRowHeight()

                Divider()

                launcherStack
                    .reportRowHeight()
            }
            .equalRowHeight($vuRowHeight)

            Divider()
                .padding(.vertical, 8)

            EQCurveView()
                .frame(maxWidth: .infinity, alignment: .leading)
                // .padding(.top, 4) — removed; scale canvas height provides sufficient separation
                .padding(.bottom, 12)
        }
    }

    private var launcherStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            windowLauncherRow(label: "RTA", definitions: rtaDefinitions, systemImage: "waveform.path", windowId: "rta-window")
            windowLauncherRow(label: "Levels", definitions: levelsDefinitions, systemImage: "chart.bar.fill", windowId: "levels-window")
            windowLauncherRow(label: "Analytics", definitions: analyticsDefinitions, systemImage: "gauge", windowId: "analytics-window")
        }
    }

    private func windowLauncherRow(label: String, definitions: [MeterDefinition], systemImage: String, windowId: String) -> some View {
        HStack(spacing: 6) {
            Button {
                windowActivation.prepareToShowWindow()
                openWindow(id: windowId)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                    Text(label)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            Button {
                infoPopoverWindowId = windowId
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { infoPopoverWindowId == windowId },
                set: { if !$0 { infoPopoverWindowId = nil } }
            )) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(definitions.enumerated()), id: \.offset) { index, def in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(def.title).font(.caption.bold())
                                Text(def.body).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if index < definitions.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxWidth: 280, maxHeight: 320)
            }
        }
    }

    private var rtaDefinitions: [MeterDefinition] {
        [
            MeterDefinition(title: "Pre-EQ", body: "Real-time spectrum before processing."),
            MeterDefinition(title: "Post-EQ", body: "Real-time spectrum after processing.")
        ]
    }

    private var levelsDefinitions: [MeterDefinition] {
        [
            MeterDefinition(title: "Peak In", body: "Instantaneous input level."),
            MeterDefinition(title: "Peak Out", body: "Instantaneous output level."),
            MeterDefinition(title: "RMS In", body: "Average input level."),
            MeterDefinition(title: "RMS Out", body: "Average output level.")
        ]
    }

    private var analyticsDefinitions: [MeterDefinition] {
        [
            MeterDefinition(title: "Gain Structure", body: "Headroom through the processing chain."),
            MeterDefinition(title: "Phase Correlation", body: "Mono compatibility between left and right channels."),
            MeterDefinition(title: "Crest Factor", body: "Peak-to-average ratio."),
            MeterDefinition(title: "ISP Latch", body: "Inter-sample peak overshoot detection."),
            MeterDefinition(title: "DR Factor", body: "Dynamic range rating."),
            MeterDefinition(title: "Bit Stream", body: "Real-time bit depth of the input signal."),
            MeterDefinition(title: "True Peak", body: "Oversampled peak reading with inter-sample peak indicator."),
            MeterDefinition(title: "Stereo Goniometer", body: "Vectorscope showing stereo image width.")
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top section: 8-column layout
            HStack(alignment: .top, spacing: 12) {
                preampVolumeColumn
                Divider()
                DynamicsInlineView()
                Divider()
                vuAndCurveColumn
            }

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
                    .frame(width: 128)

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
        .frame(width: 1320, height: 580)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                VStack(spacing: 2) {
                    Text("Meters")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $metersEnabledUI)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Master switch for all level meters, RTA, and analytics graphs. Disabling reduces CPU overhead.")
                }
                .frame(minWidth: 40, alignment: .center)
                .padding(.leading, 8)
                .padding(.trailing, 6)

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
                guard let window = window else { return }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMiniaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        store.meterStore.meterWindowBecameHidden(id: "equaliser")
                        store.rtaAnalyzer.rtaWindowBecameHidden(id: "equaliser")
                    }
                }
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didDeminiaturizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        store.meterStore.meterWindowBecameVisible(id: "equaliser")
                        store.rtaAnalyzer.rtaWindowBecameVisible(id: "equaliser")
                    }
                }
            }
        )
        .onAppear {
            store.meterStore.meterWindowBecameVisible(id: "equaliser")
            store.rtaAnalyzer.rtaWindowBecameVisible(id: "equaliser")
            metersEnabledUI = store.meterStore.metersEnabled
            showStateResetAlert = store.didResetStateOnLaunch
        }
        .onChange(of: metersEnabledUI) { _, newValue in
            store.meterStore.metersEnabled = newValue
        }
        .onReceive(store.meterStore.$metersEnabled) { newValue in
            metersEnabledUI = newValue
        }
        .onDisappear {
            store.meterStore.meterWindowBecameHidden(id: "equaliser")
            store.rtaAnalyzer.rtaWindowBecameHidden(id: "equaliser")
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
