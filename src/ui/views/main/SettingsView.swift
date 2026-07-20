import AppKit
import CoreAudio
import SwiftUI

/// Tab identifier for Settings window.
enum SettingsTab: String {
    case display = "display"
    case driver = "driver"
    case userGuide = "userGuide"
    case roomCalibration = "roomCalibration"
    case outputMatrix = "outputMatrix"
}

// MARK: - Mic Calibration Mode (Part 2 Task AC)
enum MicCalibrationMode: String, CaseIterable {
    case none = "none"
    case single = "single"
    case dual = "dual"
}

struct SettingsView: View {
    @EnvironmentObject var store: EqualiserStore
    @EnvironmentObject var windowActivation: WindowActivationController
    @State private var selectedTab: SettingsTab = .display
    
    /// Allows programmatic selection of tab (e.g., to show Driver tab when update required).
    var initialTab: SettingsTab? {
        if store.showDriverUpdateRequired {
            return .driver
        }
        return nil
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DisplaySettingsTab()
                .tabItem {
                    Label("Display", systemImage: "paintbrush")
                }
                .tag(SettingsTab.display)

            DriverSettingsTab()
                .tabItem {
                    Label("Driver", systemImage: "speaker.wave.3")
                }
                .tag(SettingsTab.driver)

            RoomCalibrationTab()
                .tabItem {
                    Label("Room Cal.", systemImage: "waveform.path.ecg.rectangle")
                }
                .tag(SettingsTab.roomCalibration)

            OutputChannelMatrixView(store: store, meterStore: store.meterStore)
                .tabItem {
                    Label("Crossover", systemImage: "speaker.wave.3.fill")
                }
                .tag(SettingsTab.outputMatrix)

            UserGuideTab()
                .tabItem {
                    Label("User Guide", systemImage: "book")
                }
                .tag(SettingsTab.userGuide)
        }
        .frame(width: 760, height: 640)
        .onAppear {
            windowActivation.windowBecameVisible(.settings)

            // Auto-select Driver tab if update required
            if let initialTab = initialTab {
                selectedTab = initialTab
                // Clear the flag so user doesn't get forced back on subsequent opens
                store.clearDriverUpdateRequired()
            }
        }
        .onDisappear {
            windowActivation.windowBecameHidden(.settings)
        }
    }
}

struct DisplaySettingsTab: View {
    @EnvironmentObject var store: EqualiserStore
    @State private var showDriverRequiredAlert = false
    @State private var showPermissionDeniedAlert = false

    private var routingViewModel: RoutingViewModel {
        RoutingViewModel(store: store)
    }

    private enum Mode {
        case automatic
        case manual
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Mode", selection: Binding(
                            get: { store.manualModeEnabled ? Mode.manual : Mode.automatic },
                            set: { newValue in
                                switch newValue {
                                case .automatic:
                                    if !DriverManager.shared.isReady {
                                        showDriverRequiredAlert = true
                                        return
                                    }
                                    store.switchToAutomaticMode()
                                case .manual:
                                    Task {
                                        let granted = await store.switchToManualMode()
                                        if !granted {
                                            showPermissionDeniedAlert = true
                                        }
                                    }
                                }
                            }
                        )) {
                            Text("Automatic").tag(Mode.automatic)
                            Text("Manual").tag(Mode.manual)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatic mode (recommended):")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("App manages device selection automatically")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Works with macOS Sound settings")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manual mode:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("You choose input and output devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Requires microphone permission")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Device Selection Mode")
            }

            Section {
                RoutingStatusView(viewModel: routingViewModel)
            } header: {
                Text("Routing Status")
            }

            if store.manualModeEnabled {
                Section {
                    DevicePickerView(layout: .vertical)

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
                } header: {
                    Text("Device Selection")
                }
            }

            Section {
                HStack {
                    Spacer()
                    Picker("Appearance", selection: $store.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                }
            } header: {
                Text("Appearance")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Format", selection: $store.bandwidthDisplayMode) {
                            ForEach(BandwidthDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Q Factor:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Bandwidth as precision value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Higher = narrower, more surgical")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Octaves:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Bandwidth as musical intervals")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Higher = wider frequency range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Bandwidth Display")
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Driver Required", isPresented: $showDriverRequiredAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Automatic mode requires the virtual audio driver. Please install it from the Driver tab in Settings.")
        }
        .alert("Permission Required", isPresented: $showPermissionDeniedAlert) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Manual mode requires microphone permission.\n\nOpen System Settings to enable it.")
        }
    }
}

struct DriverSettingsTab: View {
    @EnvironmentObject var store: EqualiserStore
    @StateObject private var driverManager = DriverManager.shared
    @State private var showUninstallConfirm = false
    @State private var showHALPermissionDeniedAlert = false
    
    /// Whether the driver lacks shared memory capability
    private var driverNeedsUpdate: Bool {
        driverManager.isReady && !driverManager.hasSharedMemoryCapability()
    }
    
    var body: some View {
        Form {
            Section {
                contentView
            } header: {
                Text("Virtual Audio Driver")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Picker("Method", selection: Binding(
                            get: { store.effectiveCaptureMode },
                            set: { newMode in
                                if newMode == .halInput {
                                    Task {
                                        let granted = await store.requestMicPermissionAndSwitchToHALCapture()
                                        if !granted {
                                            await MainActor.run {
                                                showHALPermissionDeniedAlert = true
                                            }
                                        }
                                    }
                                } else {
                                    store.captureMode = newMode
                                }
                            }
                        )) {
                            Text("Shared Memory").tag(CaptureMode.sharedMemory)
                            Text("HAL Input").tag(CaptureMode.halInput)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(store.manualModeEnabled)
                        .opacity(store.manualModeEnabled ? 0.5 : 1.0)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shared Memory (recommended):")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("No microphone permission required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("No indicator in Control Center")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("HAL Input:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Requires microphone permission")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Shows microphone indicator")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Capture Mode")
            } footer: {
                if store.manualModeEnabled {
                    Text("Capture mode is not available in manual mode.")
                } else if driverNeedsUpdate {
                    Text("Using HAL Input because your driver version doesn't support shared memory. Update the driver to enable this feature.")
                }
            }
            
            Section {
                if driverManager.isInstalling {
                    HStack {
                        Spacer()
                        ProgressView("Please wait...")
                        Spacer()
                    }
                }
                
                if let error = driverManager.installError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                        Spacer()
                        Button {
                            driverManager.installError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Uninstall Driver", isPresented: $showUninstallConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Uninstall", role: .destructive) {
                Task {
                    do {
                        try await driverManager.uninstallDriver()
                    } catch {
                        driverManager.installError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This will remove the Equaliser virtual audio driver from your system. You may need to restart coreaudiod.")
        }
        .alert("Permission Required", isPresented: $showHALPermissionDeniedAlert) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("HAL Input capture requires microphone permission.\n\nOpen System Settings to enable it.")
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch driverManager.status {
        case .notInstalled:
            notInstalledView
        case .installed(let version):
            installedView(version: version)
        case .needsUpdate(let current, let bundled):
            needsUpdateView(current: current, bundled: bundled)
        case .error(let message):
            errorView(message: message)
        }
    }
    
    private var notInstalledView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Driver not installed")
                    .fontWeight(.medium)
            }
            
            Text("Install the driver to route audio through the equaliser.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Install Driver") {
                Task {
                    do {
                        try await driverManager.installDriver()
                    } catch {
                        driverManager.installError = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(driverManager.isInstalling)
        }
    }
    
    private func installedView(version: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Driver installed")
                    .fontWeight(.medium)
                Spacer()
                Text("v\(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sampleRate = driverManager.driverSampleRate {
                HStack {
                    Text("Sample Rate")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(sampleRate).formatted()) Hz")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("SRC")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Off")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("The driver is ready to use.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Uninstall", role: .destructive) {
                showUninstallConfirm = true
            }
            .disabled(driverManager.isInstalling)
            .buttonStyle(.bordered)
        }
    }
    
    private func needsUpdateView(current: String, bundled: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.orange)
                Text("Update available")
                    .fontWeight(.medium)
            }
            
            HStack(spacing: 8) {
                Text("Current: v\(current)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("→")
                    .foregroundStyle(.secondary)
                Text("v\(bundled)")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            
            // Dynamic message based on version
            Text(updateMessage(for: current))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 16) {
                Button("Update Driver") {
                    Task {
                        do {
                            try await driverManager.installDriver()
                        } catch {
                            driverManager.installError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(driverManager.isInstalling)
                
                Button("Uninstall", role: .destructive) {
                    showUninstallConfirm = true
                }
                .disabled(driverManager.isInstalling)
            }
        }
    }
    
    /// Minimum driver version that supports shared memory capture.
    private static let sharedMemoryMinVersion = "1.1.0"
    
    /// Returns the appropriate update message based on the installed version.
    /// Versions below 1.1.0 don't support shared memory capture.
    private func updateMessage(for currentVersion: String) -> String {
        if currentVersion < Self.sharedMemoryMinVersion {
            return "The current installed version does not support the \"Shared Memory\" capture mode.\nUpdate for improved audio routing without requiring microphone permission."
        } else {
            return "A newer version is available. Update to get the latest features and fixes."
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title)
            
            Text("Error")
                .fontWeight(.medium)
                .foregroundStyle(.red)
            
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Retry") {
                driverManager.checkInstallationStatus()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - User Guide Tab

/// Scrollable user guide embedded inside the Settings window.
/// Uses an NSViewController + NSScrollView wrapper to allow rich attributed
/// text rendering with section headers, sub-headings, and body copy per spec.
struct UserGuideTab: View {
    var body: some View {
        UserGuideViewControllerRepresentable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Room Calibration Tab

/// Multi-seat room acoustic measurement and correction.
struct RoomCalibrationTab: View {
    @EnvironmentObject var store: EqualiserStore

    // Measurement state
    @State private var isMeasuring    = false
    @State private var calibPosition  = 0        // 0 = Centre, 1 = Left, 2 = Right
    @State private var acousticMode   = 0        // 0 = Single Point, 1 = Multi-Seat Avg
    @State private var measuredSeats: Set<Int> = []   // indices of measured positions
    @State private var statusMessage  = "Ambient shield active — monitoring room silence."
    @State private var selectedMeasurementTab = 0  // 0 = Magnitude, 1 = Phase, 2 = Group Delay, 3 = Impulse, 4 = Step, 5 = ETC/Waterfall

    // Loopback measurement state
    @State private var maxBands: Int = 16

    // Microphone selection
    @State private var selectedMicID: AudioDeviceID? = nil
    @State private var availableMics: [(id: AudioDeviceID, name: String)] = []

    // Dual-file calibration state (Part 2 Task AC)
    @State private var micCalibrationMode: MicCalibrationMode = .none
    @State private var freeFieldURL: URL? = nil
    @State private var diffuseFieldURL: URL? = nil
    @State private var schroederFrequency: Double = 300.0

    private let positionLabels = ["Centre", "Left", "Right"]

    var body: some View {
        Form {
            // ── About ────────────────────────────────────────────────────────
            Section {
                Text("Room calibration measures your listening environment's acoustic response and applies correction filters to compensate for room modes and reflections. Multi-seat averaging combines measurements from multiple listening positions into a single composite correction.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("About Room Calibration")
            }

            // ── Room Correction Enabled ─────────────────────────────────────
            Section {
                Toggle("Room Correction Enabled", isOn: Binding(
                    get: { store.dynamicsConfig.advanced.roomCorrectionEnabled },
                    set: { val in
                        var adv = store.dynamicsConfig.advanced
                        adv.roomCorrectionEnabled = val
                        store.updateAdvancedProcessing(adv)
                        store.routingCoordinator.eqStager.setRoomCorrectionLayerBypass(!val)
                        store.roomCorrectionPresetManager.markAsModified()
                    }
                ))
                Text("Turn off to temporarily bypass correction without losing your calibration. Use \"Discard All\" instead if you want to clear the measurement entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Room Correction")
            }

            // ── Room Profile ───────────────────────────────────────────────
            Section {
                RoomCorrectionPresetToolbar()
            } header: {
                Text("Room Profile")
            }

            // ── Target Curve ───────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select a target curve for room correction.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Target curve", selection: $store.selectedTargetCurveName) {
                        ForEach(TargetCurveLibrary.allCurves.filter { !$0.appliesToSubBandOnly }, id: \.name) { curve in
                            Text(curve.name).tag(curve.name)
                        }
                        Text("Custom…").tag("Custom…")
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .onChange(of: store.selectedTargetCurveName) { _, newValue in
                        if let curve = TargetCurveLibrary.allCurves.first(where: { $0.name == newValue }) {
                            store.targetCurve = curve.curve
                        }
                        store.roomCorrectionPresetManager.markAsModified()
                    }
                }
            } header: {
                Text("Target Curve")
            }

            // ── Microphone Calibration (Part 4.1 + Part 2 Task AC) ───────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Load a microphone calibration file to correct for the measurement mic's frequency response deviation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Calibration mode picker (Part 2 Task AC)
                    Picker("Calibration mode", selection: $micCalibrationMode) {
                        Text("None").tag(MicCalibrationMode.none)
                        Text("Single file").tag(MicCalibrationMode.single)
                        Text("Dual file (free-field + diffuse-field)").tag(MicCalibrationMode.dual)
                    }
                    .pickerStyle(.segmented)

                    switch micCalibrationMode {
                    case .none:
                        Text("No calibration applied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .single:
                        if let calibration = store.micCalibration {
                            HStack(spacing: 8) {
                                Text(calibration.filename ?? "Loaded calibration")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Button("Clear") {
                                    store.clearMicCalibration()
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                            }
                        } else {
                            Button("Load Mic Calibration File…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.plainText]
                                panel.allowsMultipleSelection = false
                                panel.title = "Select Microphone Calibration File"
                                if panel.runModal() == .OK, let url = panel.url {
                                    store.loadMicCalibration(url: url)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                    case .dual:
                        VStack(alignment: .leading, spacing: 8) {
                            // Free field file picker
                            HStack {
                                Text("Free field:")
                                    .font(.caption)
                                if let url = freeFieldURL {
                                    Text(url.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button("Clear") {
                                        freeFieldURL = nil
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10))
                                } else {
                                    Button("Load…") {
                                        let panel = NSOpenPanel()
                                        panel.allowedContentTypes = [.plainText]
                                        panel.allowsMultipleSelection = false
                                        panel.title = "Select Free-Field Calibration File"
                                        if panel.runModal() == .OK, let url = panel.url {
                                            freeFieldURL = url
                                            loadDualCalibration()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // Diffuse field file picker
                            HStack {
                                Text("Diffuse field:")
                                    .font(.caption)
                                if let url = diffuseFieldURL {
                                    Text(url.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Button("Clear") {
                                        diffuseFieldURL = nil
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 10))
                                } else {
                                    Button("Load…") {
                                        let panel = NSOpenPanel()
                                        panel.allowedContentTypes = [.plainText]
                                        panel.allowsMultipleSelection = false
                                        panel.title = "Select Diffuse-Field Calibration File"
                                        if panel.runModal() == .OK, let url = panel.url {
                                            diffuseFieldURL = url
                                            loadDualCalibration()
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            // Schroeder frequency slider
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Schroeder frequency: \(Int(schroederFrequency)) Hz")
                                    .font(.caption)
                                Slider(value: $schroederFrequency, in: 100...1000, step: 10)
                                    .onChange(of: schroederFrequency) { _ in
                                        loadDualCalibration()
                                    }
                                Text("ⓘ The Schroeder frequency is where your room transitions from reverberant to direct-sound dominated. Typical range: 200–500 Hz. Leave at 300 Hz if unsure.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let error = store.micCalibrationLoadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Microphone Calibration")
            }

            // ── Excess-Phase Correction (Part 5) ───────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    // Task 8 (Option B): The excess-phase correction feature requires a
                    // complex (magnitude + phase) frequency response from SweepAnalyser,
                    // which currently only produces magnitude data. The toggle is shown
                    // but disabled so it is not user-reachable in a broken state.
                    Toggle("Excess-Phase Correction (Not yet available)", isOn: .constant(false))
                        .disabled(true)
                        .foregroundStyle(.secondary)

                    Text("Excess-phase correction will be available in a future update once complex (magnitude + phase) measurement data is produced by the sweep analyser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Excess-Phase Correction")
            }

            // ── Microphone Selection ───────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select the microphone used to capture room reflections during the sweep.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if availableMics.isEmpty {
                        Text("No input devices found.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Picker("Input Microphone", selection: $selectedMicID) {
                            Text("None selected").tag(Optional<AudioDeviceID>.none)
                            ForEach(availableMics, id: \.id) { mic in
                                Text(mic.name).tag(Optional(mic.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Microphone")
            }

            // ── Configuration ─────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Acoustic Mapping")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("", selection: $acousticMode) {
                                Text("Single Point").tag(0)
                                Text("Multi-Seat Avg").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 200)
                        }

                        if acousticMode == 1 {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Calibration Position")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Picker("", selection: $calibPosition) {
                                    ForEach(positionLabels.indices, id: \.self) { i in
                                        Text(positionLabels[i]).tag(i)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(width: 200)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Configuration")
            }

            // ── Measurement ───────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Place a calibrated measurement microphone at the \(acousticMode == 1 ? positionLabels[calibPosition].lowercased() : "primary") listening position, then start the sweep tone and allow it to complete.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(isMeasuring ? "Stop Measurement" : "Start Sweep") {
                            if isMeasuring {
                                isMeasuring = false
                                store.stopSweepMeasurement(seatIndex: calibPosition)
                                measuredSeats.insert(calibPosition)
                                let pos = acousticMode == 1 ? positionLabels[calibPosition] : "primary"
                                statusMessage = "Measurement complete for \(pos) position."
                            } else {
                                Task {
                                    let granted = await store.switchToManualMode()
                                    if granted {
                                        await MainActor.run {
                                            isMeasuring = true
                                            statusMessage = "Sweep in progress — keep the room quiet…"
                                            // Use startLoopbackMeasurement so the physical mic
                                            // selected above is included in capture (B1: unified path)
                                            store.startLoopbackMeasurement(micDeviceID: selectedMicID)
                                        }
                                    } else {
                                        await MainActor.run {
                                            statusMessage = "Microphone permission required for room measurement."
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(acousticMode == 1 && measuredSeats.contains(calibPosition) && !isMeasuring)

                        if acousticMode == 1 && measuredSeats.contains(calibPosition) && !isMeasuring {
                            Button("Re-measure") {
                                measuredSeats.remove(calibPosition)
                                statusMessage = "Ambient shield active — monitoring room silence."
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Ambient status readout
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isMeasuring ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Measurement")
            }

            // ── Measurement Visualization ─────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("View", selection: $selectedMeasurementTab) {
                        Text("Magnitude").tag(0)
                        Text("Group Delay").tag(1)
                        Text("Impulse").tag(2)
                        Text("Step").tag(3)
                        Text("ETC/Waterfall").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    Group {
                        switch selectedMeasurementTab {
                        case 0:
                            if !store.measuredResponse.isEmpty {
                                Text("Measured response: \(store.measuredResponse.count) frequency points. Use the EQ curve display to visualise the correction result.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No measurement data available.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 1:
                            // Group delay from magnitude-only data — imag=0 so phase is flat.
                            // Marked unavailable until complex measurement data is supported.
                            Text("Group delay display requires phase measurement data, not yet available.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case 2:
                            if !store.lastMeasuredImpulseResponse.isEmpty {
                                ImpulseResponseView(impulseResponse: store.lastMeasuredImpulseResponse,
                                                    sampleRate: store.streamSampleRate)
                            } else {
                                Text("No measurement data available. Run a sweep to populate this view.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 3:
                            if !store.lastMeasuredImpulseResponse.isEmpty {
                                StepResponseView(impulseResponse: store.lastMeasuredImpulseResponse,
                                                 sampleRate: store.streamSampleRate)
                            } else {
                                Text("No measurement data available. Run a sweep to populate this view.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case 4:
                            if !store.lastMeasuredImpulseResponse.isEmpty {
                                EnergyDecayView(impulseResponse: store.lastMeasuredImpulseResponse,
                                                sampleRate: store.streamSampleRate)
                            } else {
                                Text("No measurement data available. Run a sweep to populate this view.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
            } header: {
                Text("Measurement Visualization")
            }

            // ── Correction Filters ────────────────────────────────────────
            // B1: Unified apply section — one IIR button, one FIR button.
            // Operates on pendingMeasuredCurve regardless of which sweep path produced it.
            Section {
                let hasMeasurement = !measuredSeats.isEmpty || store.pendingMeasuredCurve != nil
                let readyForMulti  = acousticMode == 1 && measuredSeats.count >= 2

                if hasMeasurement {
                    VStack(alignment: .leading, spacing: 10) {
                        // Sweep progress indicator
                        HStack(spacing: 8) {
                            switch store.measurementState {
                            case .idle:
                                Circle().fill(Color.gray).frame(width: 8, height: 8)
                                Text("Ready to measure").font(.caption).foregroundStyle(.secondary)
                            case .playing:
                                ProgressView().scaleEffect(0.7)
                                Text("Playing sweep…").font(.caption).foregroundStyle(.secondary)
                            case .capturing:
                                ProgressView().scaleEffect(0.7)
                                Text("Capturing reverb tail…").font(.caption).foregroundStyle(.secondary)
                            case .computing:
                                ProgressView().scaleEffect(0.7)
                                Text("Computing response…").font(.caption).foregroundStyle(.secondary)
                            case .done:
                                Circle().fill(Color.green).frame(width: 8, height: 8)
                                Text("Measurement complete").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if acousticMode == 1 && !readyForMulti {
                            Label("Measure at least 2 positions to build an averaged correction.",
                                  systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(acousticMode == 1
                                 ? "Averaged correction from \(measuredSeats.count) positions ready to apply."
                                 : "Measurement complete. Apply correction filters when ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Band count stepper — shared by both apply paths
                        HStack(spacing: 8) {
                            Text("Max bands:").font(.caption)
                            Stepper("", value: $maxBands, in: 8...20).frame(width: 80)
                            Text("\(maxBands)").font(.caption).foregroundStyle(.secondary).frame(width: 30)
                        }

                        HStack(spacing: 12) {
                            // IIR apply
                            Button("Apply IIR Correction (\(maxBands) bands)") {
                                store.applyRoomCalibration(maxBands: maxBands)
                                statusMessage = "IIR correction filters applied."
                            }
                            .buttonStyle(.bordered)
                            .disabled(acousticMode == 1 && !readyForMulti)

                            // Discard
                            Button("Discard All", role: .destructive) {
                                measuredSeats.removeAll()
                                store.discardAllMeasurements()
                                statusMessage = "Ambient shield active — monitoring room silence."
                            }
                            .buttonStyle(.bordered)
                        }

                        // FIR apply — alternate output mode, same pendingMeasuredCurve
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FIR Correction (alternate output mode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                Picker("IR length", selection: $store.firCorrectionTapCount) {
                                    ForEach([1024, 2048, 4096, 8192, 16384], id: \.self) { taps in
                                        let ms = Double(taps) * 1000.0 / store.streamSampleRate
                                        Text("\(taps) taps (\(Int(round(ms))) ms)").tag(taps)
                                    }
                                }
                                .pickerStyle(.menu)
                                .controlSize(.small)

                                Button("Apply FIR (\(store.firCorrectionTapCount) taps)") {
                                    store.applyFIRRoomCorrection(tapCount: store.firCorrectionTapCount)
                                    statusMessage = "FIR correction applied."
                                }
                                .buttonStyle(.bordered)
                                .disabled(acousticMode == 1 && !readyForMulti)
                            }

                            Text("FIR captures narrow room modes that parametric bands cannot address. Longer IRs correct lower frequencies at the cost of more latency.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = store.measurementError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("No measurement data yet. Run a sweep first.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Correction Filters")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            availableMics = Self.listInputDevices()
            // Task 5: Only install the trivial isMeasuring-reset handler when idle.
            // If a measurement is already in flight (started before the user navigated
            // away and back), the real completion handler installed by
            // startLoopbackMeasurement / startSweepMeasurement owns this callback for
            // its full lifecycle and must not be overwritten.
            if store.measurementState == .idle && !isMeasuring {
                store.routingCoordinator.pipelineManager.renderPipeline?.onSweepPlaybackComplete = {
                    isMeasuring = false
                }
            }
        }
    }

    // MARK: - Input Device Enumeration

    private static func listInputDevices() -> [(id: AudioDeviceID, name: String)] {
        var devices: [(id: AudioDeviceID, name: String)] = []
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDs: [AudioDeviceID] = []
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else {
            return devices
        }

        deviceIDs = Array(repeating: AudioDeviceID(), count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return devices
        }

        for deviceID in deviceIDs {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.stride)
            if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr {
                let nameStr = name as String
                guard !nameStr.isEmpty else { continue }

                // Check if this is an input device
                var streamConfigAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var bufferSize: UInt32 = 0
                if AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddress, 0, nil, &bufferSize) == noErr, bufferSize > 0 {
                    devices.append((id: deviceID, name: nameStr))
                }
            }
        }

        return devices
    }

    // MARK: - Dual-File Calibration (Part 2 Task AC)

    private func loadDualCalibration() {
        guard let freeFieldURL = freeFieldURL,
              let diffuseFieldURL = diffuseFieldURL else { return }

        do {
            var calibration = try MicCalibrationLoader.loadDual(
                freeFieldURL: freeFieldURL,
                diffuseFieldURL: diffuseFieldURL
            )
            calibration.schroederFrequencyHz = schroederFrequency
            store.micCalibration = calibration
            store.micCalibrationLoadError = nil
        } catch {
            store.micCalibrationLoadError = error.localizedDescription
        }
    }
}

/// NSViewControllerRepresentable wrapper for UserGuideSettingsViewController.
private struct UserGuideViewControllerRepresentable: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UserGuideSettingsViewController {
        UserGuideSettingsViewController()
    }
    func updateNSViewController(_ nsViewController: UserGuideSettingsViewController, context: Context) {}
}

/// AppKit view controller hosting a scrollable, styled manual text view.
final class UserGuideSettingsViewController: NSViewController {

    private let textScrollWrapper = NSScrollView()
    private let manualTextView    = NSTextView()

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 460))
        setupLayout()
    }

    private func setupLayout() {
        textScrollWrapper.hasVerticalScroller   = true
        textScrollWrapper.hasHorizontalScroller = false
        textScrollWrapper.autohidesScrollers     = true
        textScrollWrapper.translatesAutoresizingMaskIntoConstraints = false

        manualTextView.isEditable   = false
        manualTextView.isSelectable = true
        manualTextView.textColor    = .labelColor
        manualTextView.drawsBackground = false
        manualTextView.textContainer?.widthTracksTextView = true
        manualTextView.textContainerInset = NSSize(width: 4, height: 4)

        textScrollWrapper.documentView = manualTextView
        view.addSubview(textScrollWrapper)

        NSLayoutConstraint.activate([
            textScrollWrapper.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            textScrollWrapper.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            textScrollWrapper.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textScrollWrapper.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        manualTextView.textStorage?.setAttributedString(buildGuideContent())
    }

    // MARK: - Attributed Content Builder

    private func buildGuideContent() -> NSAttributedString {
        let result = NSMutableAttributedString()

        func h1(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 18),
                .foregroundColor: NSColor.labelColor
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }
        func h2(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 14),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            result.append(NSAttributedString(string: text + "\n", attributes: attrs))
        }
        func body(_ text: String) {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3.5
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }
        func code(_ text: String) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor
            ]
            result.append(NSAttributedString(string: text + "\n\n", attributes: attrs))
        }

        h1("Notch Sixty — User Guide")

        h2("Table of Contents")
        body("")

        h2("Part 1 — System Overview")
        body("This application inserts a real-time digital signal processing pipeline between macOS CoreAudio and your chosen output device. A virtual audio driver captures the system's audio stream, routes it through a chain of parametric EQ, dynamics, spatial, and correction stages, and delivers the processed signal to your speakers, headphones, or multi-amplifier system. Every stage operates in the digital domain at the stream's native sample rate, using double-precision coefficient design and single-precision (Float32) sample processing.")

        h2("1.2 Signal Path at a Glance")
        body("The full processing order, in the sequence audio actually passes through it is:")
        code("System audio (virtual driver capture)\n  → Stereo Fold-Down (Stereo / Wide Mono / True Mono)\n  → DC Offset Filter\n  → Infrasonic High-Pass Filter\n  → Stereo Widener (3-band M/S)\n  → LUFS Loudness Match\n  → Loudness Contour (equal-loudness compensation)\n  → De-Esser\n  → Multiband Compressor (Linkwitz-Riley split)\n  → Wideband Compressor\n  → Expander\n  → Soft Clipper\n  → De-Harsh Tilt Filter\n  → Brickwall Limiter (look-ahead, True-Peak Guard)\n  → Auto-Headroom Gain Rider (feeds back into Soft Clipper/Limiter drive)\n  → User Parametric EQ  (layer 0)\n  → Room Correction EQ  (layer 1, IIR or FIR)\n  → Bass Management / Active Crossover (band split for sub or multi-amp output)\n  → Symmetry Balance, Panning/Crossfeed Matrix, Crosstalk Cancellation, Speaker\n    IR Alignment, Sub-Bass Phase Alignment, Linear Denoiser  (LTI suite)\n  → Inter-Channel Time Delay\n  → Pause Gate\n  → Dither\n  → Output device(s)")
        body("Two details are easy to miss and important for troubleshooting:")
        body("• The EQ engine sits after the dynamics chain, not before it. Boosting a band with the EQ does not change what triggers the compressor or de-esser — those stages react to the un-equalised signal.")
        body("• Room correction is a second, independent EQ layer stacked on top of your manual bands, not a modification of them. You can bypass one without touching the other.")

        h2("1.3 Compare Modes")
        body("The Compare control (segmented picker on the main window) selects how the processed signal relates to what you hear:")
        code("EQ      Full biquad IIR processing. Minimum latency. (default)\nLinear  Zero-phase FIR convolution EQ. Eliminates phase distortion entirely,\n        at the cost of increased latency and pre-ringing artefacts.\nMixed   Biquad EQ with all-pass phase correction. Reduces phase distortion\n        without pre-ringing or added latency — a practical middle ground\n        between EQ and Linear modes.\nFlat    Bypasses EQ at matched volume to audition unprocessed audio.\n        Reverts to EQ automatically after 5 minutes.\nDelta   Solos the EQ difference signal so you hear only what the chain\n        is adding or removing.")
        body("Use Flat for level-matched A/B listening — it prevents the \"louder sounds better\" bias from confusing your judgement of the EQ itself. Use Delta to confirm a stage is actually doing something: if Delta is silent, nothing downstream is currently modifying the signal.")

        h2("Part 2 — The Parametric EQ Engine")
        body("Every EQ band, crossover point, and correction filter in the application is built from second-order IIR sections (\"biquads\"), designed using the standard formulas from the RBJ Audio EQ Cookbook. A biquad implements the difference equation:")
        code("y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]")
        body("with transfer function:")
        code("H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)")
        body("Coefficients are derived from three user-facing parameters — centre/cutoff frequency f0, quality factor Q, and gain (where applicable) — via the intermediate quantities:")
        code("ω0 = 2π·f0 / fs\nα  = sin(ω0) / (2Q)\nA  = 10^(gain_dB / 40)          (used only by parametric and shelf types)")
        body("All coefficients are computed in double precision, then normalised by dividing through by a0 before being converted to Float32 for the audio-thread run loop. Double precision matters most for narrow, low-frequency filters, where the pole pair sits close to the unit circle and single-precision rounding would visibly shift the response.")

        h2("2.2 Filter Types")
        body("Parametric (Bell) — Symmetric boost/cut around f0, width set by Q")
        body("Low Pass (LP) — 2nd-order low-pass; Q sets resonance at the corner")
        body("High Pass (HP) — 2nd-order high-pass; Q sets resonance at the corner")
        body("Low Shelf (LS) — Boost/cut below f0; Q sets the transition slope")
        body("High Shelf (HS) — Boost/cut above f0; Q sets the transition slope")
        body("Band Pass (BP) — Constant 0 dB peak gain band-pass")
        body("Notch — Narrow band-reject, unity gain outside the notch")
        body("All-Pass (AP) — Unity magnitude everywhere; rotates phase around f0")
        body("FIR — User-loaded impulse response, processed by the linear-phase engine")
        body("Linkwitz-Transform (LT) — Re-tunes a sealed-box driver's resonance from (f0, Q0) to (fp, Qp)")
        body("Tilt — Complementary low-shelf/high-shelf pivot for tonal \"warm ↔ bright\" tilting")

        h2("2.3 Q, Bandwidth, and Filter Slope")
        body("Q and bandwidth-in-octaves are two views of the same underlying selectivity and convert exactly:")
        code("Q → bandwidth (octaves):  BW = 2·asinh(1 / (2Q)) / ln(2)\nbandwidth → Q:            Q  = 1 / (2·sinh(ln(2)·BW / 2))")
        body("Toggle the display convention in Settings → Display → Bandwidth Display without changing the underlying filter. Valid ranges: Q 0.1 – 100, bandwidth 0.05 – 5.0 octaves.")
        body("For Low Pass, High Pass, Low Shelf, and High Shelf bands, an independent slope control selects the filter order, from 6 dB/octave up to 96 dB/octave in 6 dB/octave increments.")

        h2("2.4 Linked vs. Independent Stereo Bands")
        body("Each channel (L and R) carries its own EQ state. In Linked mode both channels read from a single shared band set, so every edit updates both channels identically. In Stereo mode the L and R band sets are independent, letting you correct channel-specific issues. Up to 64 bands per channel are supported (default 10); band count can be changed live and existing bands are preserved when possible.")

        h2("2.5 The EQ Layer System")
        body("Internally, each channel's EQ is a small stack of layers, evaluated in order and summed in the coefficient domain:")
        code("Layer 0 — User EQ            (bands you create and edit directly)\nLayer 1 — Room Correction    (bands generated by the room-correction engine)")
        body("This separation means bypassing Room Correction (Settings → Room Cal.) leaves your manual EQ fully intact, and vice versa — the two never overwrite each other's bands.")

        h2("2.6 Linear-Phase (FIR) EQ Mode")
        body("Selecting Linear in Compare mode (or loading an FIR band) switches EQ processing from IIR biquads to an overlap-save FFT convolution engine. A linear-phase filter has, by construction, zero phase distortion — every frequency is delayed by exactly the same amount of time, so transient shapes are preserved. The trade-off is added latency (roughly half the impulse-response length) and pre-ringing: a linear-phase filter's impulse response is symmetric, so energy appears in the output before a sharp transient as well as after it. Mixed mode is the practical middle ground: it keeps the low-latency biquad EQ but adds an all-pass phase-correction stage that flattens the worst of the phase distortion without pre-ringing or added latency.")

        h2("2.7 High-Resolution Coefficient Decoupling")
        body("Biquad coefficients derived directly at very high sample rates (> 96 kHz) suffer pole crowding: the poles bunch close together near z = 1 on the unit circle, and single-precision arithmetic loses the resolution needed to place them accurately, especially for low-frequency, high-Q bands. When this feature is enabled and the stream rate exceeds 96 kHz, filters are instead designed at a fixed 48 kHz reference rate and the target frequency is pre-warped before design:")
        code("f_prewarped = (designRate / π) · tan(π·f / actualRate)")
        body("The resulting coefficients are then used directly at the actual (higher) sample rate. This keeps every filter's −3 dB point exactly where you set it regardless of whether you are running at 48 kHz or 384 kHz.")

        h2("2.8 4× Oversampling")
        body("An optional 4× polyphase FIR oversampler (Kaiser-windowed sinc, β = 8.0, 96 taps per phase, normalised cutoff 0.45× Nyquist) wraps the nonlinear stages — the soft clipper and the brickwall limiter. Nonlinear processing at the base sample rate generates harmonics that can alias back into the audible band; running those two stages at 4× the sample rate pushes the alias products above the (upsampled) Nyquist frequency, where they are removed by the downsampling filter before the signal returns to the base rate.")

        h2("2.9 EQ Headroom Compensation")
        body("Because Room Correction, the target curve, User EQ, and Bass Management sub-trim can all add gain simultaneously, the engine continuously computes the worst-case combined boost across a log-spaced grid of 20 Hz – 96 kHz and applies a single static, attenuation-only preamp ahead of the whole chain to guarantee the combined boost cannot clip:")
        code("linearGain(f) = 10^(EQ(f)/20) · 10^(RoomCorrection(f)/20) · 10^(TargetCurve(f)/20)\n                 · [10^(subGain/20) if f < 300 Hz]\nstaticPreampDB = −min(max(20·log10(max linearGain(f)), 0), maxAttenuationDB)")
        body("maxAttenuationDB is itself adjustable (3–24 dB, default 12 dB) — raise it if your correction stack is aggressive enough that 12 dB of headroom isn't sufficient, or lower it to cap how much the compensator is allowed to pull the whole signal down.")

        h2("Part 3 — The Dynamics Processing Chain")
        body("Ten always-present stages plus several optional gates run in strict order, before the EQ and crossover stages described in Parts 2 and 7. Each stage can be enabled/disabled independently; disabling a stage makes it a true zero-cost passthrough.")

        h2("3.2 DC Offset Filter")
        body("A first-order high-pass tuned to an exact 0.5 Hz corner, implemented as the classic DC-blocking difference equation:")
        code("y[n] = x[n] − x[n−1] + R·y[n−1]           R = exp(−π / fs)")
        body("At 48 kHz, R ≈ 0.9999346; the pole radius is recomputed whenever the sample rate changes, keeping the −3 dB point pinned at 0.5 Hz regardless of rate. At 20 Hz the resulting attenuation is under 0.0001 dB — completely inaudible — while any sub-Hz DC bias inherited from a source file or ADC is fully removed before it can bias downstream dynamics detectors or force a power amplifier's output stage to dissipate energy at idle. Recommended: leave on.")

        h2("3.3 Infrasonic High-Pass Filter")
        body("A dedicated protection filter separate from the DC blocker, intended to remove content below the range that contributes to audible reproduction but that can still consume driver excursion and amplifier headroom (HVAC rumble, record warps, room pressurisation transients). Cutoff is adjustable 5–30 Hz (default 18 Hz), with slope options of 24, 48 (default), or 96 dB/octave built from cascaded Butterworth sections. It can be routed to the main stereo chain, to the subwoofer output path only, or to both independently — useful if the mains already roll off adequately on their own but the subwoofer channel needs separate protection.")

        h2("3.4 Stereo Widener (3-Band M/S)")
        body("Splits the stereo image into three frequency bands (crossovers adjustable, default 200 Hz and 4000 Hz) and applies an independent mid/side width factor to each:")
        code("M = (L + R) / √2                 (mid — mono content)\nS = (L − R) / √2                 (side — stereo difference)\nS' = S × width                   (per band)\nL' = (M + S') / √2      R' = (M − S') / √2")
        body("Width factors: 0.0 = mono, 1.0 = unmodified stereo, up to 2.0 = expanded. Defaults are low band 0.0 (forced mono — low frequencies are perceptually non-directional, and a mono low end is essential for clean subwoofer summation), mid band 1.4, high band 1.25. A \"mono low band\" toggle forces the low band to width 0 regardless of its slider, for a guaranteed solid centre image.")

        h2("3.5 LUFS Loudness Match")
        body("A real-time loudness normaliser approximating ITU-R BS.1770-4 short-term (3-second) integrated loudness. A measurement tap runs a two-stage K-weighting filter (a high-shelf pre-filter followed by a high-pass), accumulates block mean-square power into a 3-second circular FIFO, and excludes any block quieter than a −70 dBFS gate (raised to −60 dBFS when the Dialogue Gate option is enabled, so that silence between lines of dialogue doesn't skew the estimate). The gain correction is smoothed with a 2-second RC time constant to avoid audible pumping:")
        code("gain_dB = target_LUFS − measured_LUFS\nsmoothedGain[n] = α·smoothedGain[n−1] + (1−α)·10^(gain_dB/20)")
        body("Target range −24 to −10 LUFS (default −16 LUFS). This stage measures the widened, but not-yet-gain-corrected, signal — the gain is applied first, then the new measurement is taken, which avoids feedback oscillation between measurement and correction.")

        h2("3.6 Loudness Contour")
        body("An optional equal-loudness compensation curve based on the ISO 226:2003 contour family, which describes how the ear's frequency sensitivity changes with playback level (the modern replacement for the older Fletcher-Munson curves). At lower listening levels, bass and treble both need a relative boost to sound as full as they did at reference level; this stage applies that boost automatically and can be scaled from 0 % (bypassed but selectable) to 100 % of the full ISO-226 correction, and can optionally track your live system volume rather than applying a fixed amount.")

        h2("3.7 De-Esser")
        body("A frequency-selective compressor targeting the sibilance band (default centre 6 kHz, adjustable 2–10 kHz). A band-pass side-chain filter (adjustable Q, default 2.0) isolates the target band; when its level exceeds the threshold, gain reduction is applied at a configurable ratio (default 10:1) up to a maximum attenuation (rangeDB, default −12 dB), with its own attack/release envelope (defaults 1 ms / 50 ms). In Dynamic EQ Mode, the attenuation is confined to a dynamic notch centred on the sibilance band rather than the entire signal, leaving everything else — including adjacent high-frequency detail — untouched. This is the more transparent option and is recommended whenever the source has significant high-frequency content beyond the \"s\" and \"t\" sounds you're trying to tame.")

        h2("3.8 Multiband Compressor")
        body("Splits the signal into three bands using two Linkwitz-Riley crossovers (default 150 Hz and 3000 Hz, independently adjustable), each with its own independent threshold, ratio, attack, release, and knee. The crossover is built by cascading two Butterworth sections at the same corner frequency for each order-4 leg (LR4, \"gentle\", 24 dB/octave) or four for order-8 (LR8, \"steep\", 48 dB/octave). This cascaded-pair construction is what gives Linkwitz-Riley crossovers their signature property over plain Butterworth crossovers of the same order: the low-pass and high-pass legs sum back to a perfectly flat magnitude response with matched phase, rather than the +3 dB bump a same-order Butterworth crossover would leave at the crossover point.")
        body("Per-band gain computation uses the classical three-region soft-knee compressor:")
        code("x = level in dB, T = threshold, W = knee width, R = ratio\n\nx < T − W/2:            gainReduction_dB = 0\n|x − T| ≤ W/2:           gainReduction_dB = (1/R − 1)·(x − T + W/2)² / (2W)\nx > T + W/2:             gainReduction_dB = T + (x − T)/R − x")
        body("Each band's smoothed gain crosses attack or release time constants independently, so a fast transient in one band never triggers gain movement in another — the classic advantage of multiband over wideband compression. Optional per-band sidechain high-pass filters and independent makeup gain (±12 dB per band) round out the control set. Defaults: ratio 4:1 on all bands, 6 dB knee, attack 40/20/10 ms and release 200/100/50 ms for low/mid/high respectively (faster in the higher bands, matching the ear's transient sensitivity).")

        h2("3.9 Wideband Compressor")
        body("A standard feed-forward (or optionally feed-back) compressor operating on the full-range signal, using the identical soft-knee formula shown above. Peak level is tracked in dB and smoothed with independent attack/release one-pole filters:")
        code("level_dB[n] = 20·log10(|x[n]|)\nα_attack  = exp(−1 / (fs · attackTime))\nα_release = exp(−1 / (fs · releaseTime))")
        body("Defaults: threshold −16 dB, ratio 3.5:1, knee 6 dB, attack 25 ms, release 150 ms, makeup +2.5 dB. An optional sidechain high-pass filter prevents bass energy from driving gain reduction that dulls the rest of the mix, and Program-Dependent Release lets the release time adapt automatically to how quickly the input is changing.")

        h2("3.10 Expander")
        body("A downward expander — the inverse of a compressor — that increases attenuation on signal below its threshold, widening the effective dynamic range and gating low-level noise between programme material:")
        code("gainReduction_dB = ratio · max(0, threshold − level_dB)\ngainReduction_dB = min(gainReduction_dB, range)      (attenuation ceiling)")
        body("Defaults: threshold −35 dB, ratio 1.5:1, maximum range −12 dB, attack 5 ms, release 200 ms.")

        h2("3.11 Soft Clipper")
        body("An analogue-style wave-shaper that rounds off the loudest transients before they reach the limiter, reducing how hard the limiter has to work on sharp peaks. Four curve characters are available:")
        code("Quadratic       parabolic knee, flat top above the upper bound  (default)\nCubic           tanh-style odd-harmonic saturation — \"tape\" character\nSine            sin()-based saturation — smoother, fewer high harmonics\nTube            sign-dependent asymmetric shaping — even-harmonic \"tube\" character")
        body("The knee width is expressed as a fraction of the remaining headroom between the threshold and 0 dBFS (0.0–1.0), rather than an absolute dB span — this keeps the same knee setting producing proportionally similar shaping regardless of where the threshold itself is set. Defaults: threshold −1.5 dB, knee 0.5, drive 0 dB. An Auto-Compensate Gain option automatically trims output level to offset the perceptual loudness increase that drive introduces, so you can audition curve character without a loudness bias skewing the comparison. A separate asymmetry trim biases the positive and negative half-cycles independently, which can recover 1–2 dB of headroom on waveforms with inherent DC-like asymmetry (common in some acoustic and vintage-mastered material).")

        h2("3.12 De-Harsh Tilt Filter")
        body("A first-order high-shelf tilt applied after the soft clipper, gently attenuating the top end above a configurable centre (default 3500 Hz) by a configurable amount (default −1.5 dB) — a broad, musical way to tame digital harshness or an overly forward tweeter without dulling the whole mix.")

        h2("3.13 Brickwall Limiter and True-Peak Guard")
        body("The final safety stage: a look-ahead limiter that delays the signal by the look-ahead time so it can \"see\" upcoming peaks before they arrive, then applies just enough gain reduction to keep every sample at or below the ceiling:")
        code("y[n] = x[n − lookaheadSamples] × gain[n]\ngain_dB[n] = ceiling_dB − max(|x[n]|, |x[n−1]|, …, |x[n−lookaheadSamples]|)_dB\ngain[n]   = min(gain[n], gain[n−1] + releaseRate)      (release is rate-limited; attack is instantaneous)")
        body("Defaults: ceiling −0.2 dB, attack effectively instantaneous (0.1 ms), release 20 ms, look-ahead 2 ms. With True-Peak Guard enabled, the same 4× oversampler described in §2.8 detects inter-sample peaks — the analogue reconstruction filter in a DAC can produce a peak between two digital samples that is higher than either sample itself, and a limiter operating only on the discrete samples would miss it. True-Peak Guard measures peaks at 4× the sample rate so the ceiling is honoured in the analogue domain too, not just on paper. Recommendation: keep a small amount of headroom below full scale (e.g. −0.5 dB or lower) with True-Peak Guard engaged if your downstream DAC or streaming pipeline is sensitive to inter-sample overs.")

        h2("3.14 Auto-Headroom Gain Rider")
        body("An optional slow-acting control-rate process that watches the sustained gain reduction reported by the limiter and, if it stays persistently above a target amount, gradually turns down the drive into the clipper/limiter so the limiter can relax back toward transparent, occasional-peak-only operation rather than continuously working. Configurable target sustained gain reduction (0.5–6.0 dB, default 3.0 dB), a maximum reduction ceiling (3–12 dB, default 6.0 dB), and a response speed (Fast ≈ 3 s, Medium ≈ 10 s, Slow ≈ 30 s time constant).")

        h2("3.15 Pause Gate")
        body("Smoothly mutes the output during extended near-silence, preventing amplifier hiss and any click artefacts on resume. Level detection uses an RMS-power reference with hysteresis to avoid chatter at the threshold boundary:")
        body("Threshold: −80 to −40 dBFS (default −60 dBFS)")
        body("Hold time: 100–2000 ms (default 500 ms)")
        body("Attack (resume fade-in): 1–100 ms (default 10 ms)")
        body("Release (close fade-out): 10–500 ms (default 200 ms)")
        body("Hysteresis: 0–6 dB (default 3 dB)")
        body("Named presets (Amplifier Hiss, Sensitive, Relaxed, Broadcast) load a matched set of these five values in one step; a Custom state appears automatically once you diverge from a preset.")

        h2("3.16 Dither")
        body("The final stage before output, applied only when bit-depth reduction downstream could otherwise introduce quantisation distortion:")
        code("Off          No dither\nTPDF         Triangular probability density function — minimum-bias, flat noise floor\nShaped       Frequency-weighted noise shaping for 44.1/48 kHz\nHigh-Order   5th-order Wannamaker/Lipshitz psychoacoustic noise shaping (optimal for 44.1/48 kHz)")
        body("Use TPDF when your output path truncates to a lower bit depth than the processing chain; use one of the shaped modes to push residual noise into a frequency range the ear is least sensitive to.")

        h2("Part 4 — Spatial, Correction, and System Utilities")
        body("This suite of independently-toggled processes sits alongside the main dynamics chain and addresses stereo image, room, and multi-listener correction problems that a conventional EQ/dynamics chain cannot solve on its own.")

        h2("4.1 Symmetry Balance")
        body("A constant-power pan law that shifts the L/R balance to compensate for an off-centre listening position, without the loudness dip a simple linear balance control would introduce:")
        code("gain_L = cos(θ·π/4)      gain_R = sin(θ·π/4)          θ ∈ [−1, +1]")
        body("Because gain_L² + gain_R² = constant, total acoustic power stays fixed as the image shifts — unlike linear panning, which quietly reduces total level as you move off-centre. Calibrate by playing a mono test tone and adjusting until it images dead-centre between your speakers.")

        h2("4.2 Panning / Crossfeed Matrix")
        body("A 2×2 blend matrix that mixes a controlled amount of each channel into the other, simulating the natural acoustic crossfeed that occurs when listening to stereo speakers (each ear hears both speakers, with an inter-aural time and level difference):")
        code("[L']   [1−α    α ] [L]\n[R'] = [ α    1−α] [R]           α = crossfeed amount, default 0.3")
        body("Primarily useful on headphones, where the crossfeed doesn't naturally occur, to reduce the exaggerated hard-panned image and fatigue that can come with headphone listening.")

        h2("4.3 Linear Denoising Engine")
        body("Spectral-subtraction noise reduction: a running estimate of the noise power spectrum is built during quiet passages and subtracted from every analysis frame, with a Wiener-style floor to prevent musical/gurgling artefacts:")
        code("|Y(f)|² = |X(f)|² − α·|N(f)|²                    (α = over-subtraction factor)\n|Y(f)|² = max(|Y(f)|², β·|X(f)|²)                (β = spectral floor, prevents artefacts)\n|N(f)|²[n] = γ·|X(f)|²[n] + (1−γ)·|N(f)|²[n−1]   (noise estimate, updated only below threshold)")
        body("Three named presets bundle a matched noise-floor threshold and Wiener floor: Natural (−55 dB / 0.05, minimal processing), Standard (−60 dB / 0.01, balanced default), and Aggressive (−65 dB / 0.002, maximum suppression for heavily contaminated sources). Independent attack/release envelope times (defaults 11 ms / 21 ms) control how quickly the gain reduction responds.")

        h2("4.4 Speaker Impulse-Response (Driver) Alignment")
        body("Applies a fine, fractional-sample delay to time-align the acoustic centres of a multi-driver speaker (woofer and tweeter are almost never physically coincident). Adjustable 0–5 ms. Measure each driver's arrival time independently with an external acoustic measurement tool and enter the difference here to improve phase coherence through the crossover region.")

        h2("4.5 Crosstalk Cancellation Matrix")
        body("Reduces the acoustic crosstalk between stereo speakers and the opposite ear — the fundamental phenomenon that separates speaker listening from headphone listening and narrows the achievable stereo image. Models the acoustic path as a 2×2 matrix and applies a regularised inverse to cancel the cross terms, with an adjustable cancellation depth (0.0–1.0, default 0.5) and a head-shadow frequency parameter (default 700 Hz, corresponding to a roughly 60° speaker spread; use ≈500 Hz for 45° or ≈350 Hz for 30° placements) that models where the head's acoustic shadowing naturally begins to reduce crosstalk on its own.")

        h2("4.6 Multi-Seat Complex Averaging")
        body("When more than one listening position matters (a sofa seating two or three people), this feature combines multiple positional measurements into a single composite correction rather than optimising for one chair at the expense of the others. Configurable for 1–8 positions; see Part 6 for the room-correction measurement workflow this feeds into.")

        h2("4.7 Sub-Bass Phase Alignment")
        body("An all-pass filter network that rotates the phase of the sub-bass region to align with the main speakers at the crossover point, so the two sum constructively (+6 dB for a coherent doubling, rather than a phase-cancelling dip). Adjustable crossover target (40–120 Hz, default 80 Hz) and Q (default 0.7, roughly critically damped — increase for a steeper phase rotation if your subwoofer's inherent phase behaviour needs stronger correction).")

        h2("4.8 Inter-Channel Time Delay")
        body("A signed delay (±20 ms, corresponding to roughly ±6.8 m of path-length difference at the speed of sound) applied between channels, for correcting timing mismatches between speakers or drivers at different physical distances from the listening position.")

        h2("4.9 Bass Management")
        body("The unified subwoofer-integration module: a configurable crossover (default 80 Hz, 40–200 Hz range) built from Linkwitz-Riley, Butterworth, or Bessel alignment, with independent sub trim gain (±12 dB), polarity inversion, fractional-sample sub delay, an optional low-shelf for room-gain compensation, per-speaker/subwoofer distance entry for time-alignment calculations, and up to 8 dedicated parametric EQ bands that apply only to the low-band (subwoofer) signal — useful for taming room modes in the sub's bandwidth without touching the mains' EQ.")

        h2("4.10 Stereo Mode Fold-Down")
        body("The very first stage in the chain (§3.1): Stereo (default, unmodified), Wide Mono (mid-only signal sent to both channels, useful for checking mono compatibility), or True Mono (L+R summed and halved, identical output on both channels).")

        h2("Part 5 — Metering and Analysis")

        h2("5.1 Peak and RMS Level Meters")
        body("Both input (pre-chain) and output (post-chain) meters report peak and RMS level simultaneously:")
        code("peak = max(|x[0]|, |x[1]|, …, |x[N−1]|)                       (linear, over the block)\nRMS  = √( (1/N) · Σ x[i]² )                                   (linear, over the block)\ndBFS = 20·log10(max(linear, silenceFloor))")
        body("Displayed meters apply independent attack/release smoothing so peaks register instantly but decay gracefully rather than flickering.")

        h2("5.2 Crest Factor")
        body("The instantaneous difference between peak and RMS level, in dB — a measure of how \"spiky\" versus \"dense\" the programme material is:")
        code("crestFactor_dB = peak_dB − RMS_dB")
        body("Peak and RMS are each tracked with their own exponential envelope (peak decay time constant 400 ms, RMS decay time constant 300 ms) so the reading reflects sustained programme character rather than sample-to-sample noise. Higher values (10+ dB) indicate transient-rich material (acoustic recordings, well-mastered dynamic mixes); lower values (3–6 dB) indicate heavily limited or compressed material.")

        h2("5.3 Phase Correlation Meter")
        body("Reports the Pearson correlation coefficient between the left and right channels, using exponentially-decayed running accumulators (≈300 ms time constant on the raw estimate, a further ≈100 ms smoothing on the displayed value):")
        code("corr[n] = decay·corr[n−1] + L[n]·R[n]         (cross-power accumulator, and similarly for L·L, R·R)\ncorrelation = corr_LR / √(corr_LL · corr_RR)")
        body("+1.0 = perfectly in-phase / mono-compatible. 0.0 = fully uncorrelated (wide, decorrelated stereo). −1.0 = fully out-of-phase — content that will cancel to silence if summed to mono. Values that hover near −1 on bass-heavy content usually indicate a wiring or polarity fault and should be investigated before trusting the low end.")

        h2("5.4 Goniometer")
        body("A circular Lissajous vector-scope display. Raw stereo samples are rotated 45° into mid/side display coordinates:")
        code("X (horizontal) = (L − R) / √2        (side — width)\nY (vertical)   = (L + R) / √2        (mid — mono content)")
        body("A vertical line (all energy on the Y axis) indicates mono content; a circular or horizontally-spread pattern indicates wide, decorrelated stereo. The display uses a 512-sample analysis window refreshed at 30 Hz with a phosphor-style fading trail (points persist for roughly 1 second before fading out), giving a continuous sense of stereo motion rather than a single static snapshot.")

        h2("5.5 31-Band Real-Time Analyser (RTA)")
        body("Dual pre-EQ / post-chain spectrum analysers, each computed from an 8192-point FFT with a Hann analysis window, refreshed continuously from a lock-free ring buffer fed directly by the audio render thread:")
        code("X_windowed[n] = x[n] · hann[n]\nX(k) = FFT{X_windowed}\nmagnitude_dB(f_c) = 20·log10( |X(k)| · 4/N )     (Hann-window amplitude correction)")
        body("The 8192 raw FFT bins are grouped into the standard 31-band 1/3-octave ISO centre-frequency layout (20 Hz – 20 kHz) for display, with independent peak-hold per band. A Diagnostics overlay (available from the RTA toolbar) reports live display frame rate, active band count, and the current latency mode, useful for confirming the analyser itself isn't the source of an apparent performance problem.")

        h2("5.6 Clip Detection")
        body("A dedicated clip indicator latches red for 1.5 seconds on any sample that reaches or exceeds the configured ceiling, independent of the continuous bar meters — this catches single-sample transient overs that would otherwise flash past too quickly to see. Click the indicator to reset it manually.")

        h2("Part 6 — Room Correction")

        h2("6.1 Concept and Workflow")
        body("Room correction measures your listening environment's acoustic response with a microphone and computes an inverse filter set that pulls the measured response toward a chosen target curve. The overall workflow is: choose a target curve → (optionally) load a microphone calibration file → run a sweep measurement (single position, or multiple positions for multi-seat averaging) → apply either an IIR (parametric) or FIR (convolution) correction filter set.")
        body("Because room correction lives in its own EQ layer (§2.5), it can be toggled off independently of your manual EQ at any time, and \"Discard All\" clears the measurement data without touching the correction toggle state.")

        h2("6.2 Sweep Measurement")
        body("A logarithmic sine sweep is played through the system and captured by the selected input microphone; the recorded response is deconvolved against the known sweep signal to recover the room's impulse response, from which the frequency response, group delay, step response, and energy-time curve are all derived. For multi-seat averaging, repeat the sweep at each seating position (Centre / Left / Right, or as many as configured) before applying correction — averaging requires at least two measured positions.")

        h2("6.3 Microphone Calibration")
        body("Every low-cost measurement microphone deviates from a flat reference response, and that deviation will otherwise be \"corrected for\" as if it were a room problem. Loading a calibration file removes the microphone's own signature from the measurement before it's used.")
        body("Two calibration modes are available:")
        body("• Single file — one calibration curve applied uniformly across the spectrum. Correct for a free-field (on-axis, anechoic) or diffuse-field (random-incidence) calibrated microphone, whichever matches how you'll be measuring.")
        body("• Dual file (free-field + diffuse-field) — blends between a free-field calibration below the room's Schroeder frequency and a diffuse-field calibration above it, since a room genuinely behaves differently on either side of that transition (below it, the response is dominated by discrete modal resonances measured on-axis; above it, the reverberant field is statistically diffuse). The blend uses a smooth raised-cosine crossfade over a one-octave-wide transition centred on the Schroeder frequency:")
        code("lower = f_schroeder / √2        upper = f_schroeder · √2      (1-octave transition band)\nt = log2(f / lower) / 1.0                                     (normalised position in the transition)\nblend = 0.5 × (1 − cos(π·t))                                  (0 → 1 raised-cosine taper)\nhybridCorrection(f) = (1 − blend)·diffuseFieldCorrection(f) + blend·freeFieldCorrection(f)")
        body("Typical Schroeder frequencies fall in the 200–500 Hz range for a domestic room; 300 Hz is a reasonable default if you haven't calculated your room's specific value.")

        h2("6.4 Target Curves")
        body("Six built-in target curves are provided (all expressed as log-spaced frequency/gain pairs):")
        body("Flat — 0 dB everywhere — reference/no-preference target")
        body("Harman room — Harman International's loudspeaker-in-room research target (Olive et al., 2013): a broad, gentle bass rise below ~300 Hz (up to +6.5 dB at 20 Hz, tapering to 0 dB by 400 Hz), flat through the midrange, and a gentle high-frequency roll-off to about −6 dB at 20 kHz")
        body("B&K house — Classic professional studio calibration curve — roughly +3 dB/octave bass rise below 1 kHz, flat above")
        body("Home theater — Gentle bass warmth plus a small high-frequency air lift, tuned for film/video content")
        body("X-Curve — SMPTE/ISO 2969 cinema reference: flat from 20 Hz–2 kHz, then a controlled −3 dB/octave roll-off above 2 kHz")
        body("Sub-only — A curve meaningful only below ~300 Hz — a small room-gain-compensating rise toward 20 Hz — for use when correction is targeted at the subwoofer band specifically")

        h2("6.5 IIR Parametric Correction")
        body("The IIR path fits up to 20 parametric bands (adjustable) to the difference between the measured curve and the target curve, using a greedy peak-picking algorithm:")
        code("residual(f) = target(f) − measured(f)             (evaluated on a 1000-point log grid, 20 Hz–20 kHz)\n\nrepeat up to maxBands times:\n  find the frequency with the largest |residual|\n  stop if that peak is smaller than 0.5 dB (diminishing returns)\n  gain  = residual at that frequency, clamped to ±12 dB\n  Q     = estimated from the residual's half-power (−3 dB relative to peak) bandwidth\n  design a parametric band at (frequency, Q, gain) and subtract its modelled\n    response from the residual curve")
        body("Each band is designed and immediately subtracted from the running residual before the next iteration picks the next-largest remaining error, so later bands correct what earlier bands didn't fully address rather than fighting each other. Maximum per-band gain is clamped to ±12 dB and correction stops automatically once the residual error falls below 0.5 dB anywhere — a \"good enough\" convergence criterion that avoids chasing measurement noise with an ever-growing band count.")

        h2("6.6 FIR Minimum-Phase Correction")
        body("The FIR path computes a minimum-phase convolution kernel (selectable length: 1024/2048/4096/8192/16384 taps) rather than a small set of parametric bands, which lets it correct narrow room-mode dips and peaks that a handful of parametric bands cannot fully resolve:")
        body("1. Log-interpolate the measured response onto a uniform frequency grid.")
        body("2. Compute the raw correction magnitude, target(f) / measured(f), clamped to a maximum boost/cut (default 12 dB).")
        body("3. Apply octave-band smoothing above a configurable crossover (default 500 Hz) to avoid amplifying high-frequency measurement noise.")
        body("4. Apply a Tikhonov-style regularisation floor so bins near the measurement noise floor aren't boosted aggressively.")
        body("5. Derive the minimum-phase kernel via the real-cepstrum method: take log|H(f)|, transform to the cepstral domain, apply a causal window (keeping only the causal part of the cepstrum, which is the standard construction for the minimum-phase spectrum with a prescribed magnitude response), and inverse-transform back to a time-domain impulse response.")
        body("6. Window the result (Hann) and truncate to the requested tap count.")
        body("A minimum-phase filter, unlike a linear-phase one, introduces no pre-ringing — all of its energy arrives at or after time zero — at the cost of a frequency-dependent (rather than uniform) group delay. This makes it the more natural choice for room correction, where you are correcting a minimum-phase-like problem (most room-mode magnitude response deviations are well approximated as minimum-phase) without the pre-ringing artefacts a linear-phase correction filter of comparable length would introduce. Longer tap counts extend how low a frequency the filter can meaningfully correct, at the cost of added latency.")

        h2("6.7 Multi-Seat Averaging")
        body("When two or more seat positions have been measured, both the IIR and FIR paths can be computed against the position-averaged response rather than a single seat, trading a small amount of per-seat accuracy for a correction that behaves reasonably everywhere people actually sit.")

        h2("6.8 Excess-Phase Correction — Current Status")
        body("The engine includes a linear-phase FIR module designed to flatten excess group delay in the modal region (the phase behaviour left over after a minimum-phase equivalent has been subtracted from the measured response), with an adjustable cutoff (100–500 Hz) and tap count (4096/8192/16384). This feature is present in the processing engine but not yet exposed in the interface: it requires a complex (magnitude and phase) frequency-response measurement, and the current sweep analyser produces magnitude-only data. The control is visible in Room Correction settings but intentionally disabled until phase-resolved measurement is implemented, so it cannot be engaged in a partially-working state.")

        h2("Part 7 — Active Crossover and Multi-Amplifier Output Routing")

        h2("7.1 Concept: Bi-Amping and Tri-Amping")
        body("Where Bass Management (§4.9) splits off only a subwoofer band, Active Crossover splits the entire mains signal into up to three frequency bands and routes each band to a separate physical output channel, so each driver in a multi-way speaker system can be driven by its own dedicated amplifier without a passive crossover network in between. This is the electronic-crossover approach used in professional and high-end active loudspeaker systems: every driver receives only the band it needs, amplifiers never have to reproduce (and dissipate power into) frequencies outside their driver's passband, and the crossover itself can be far more sophisticated than what's practical to build from passive inductors and capacitors.")

        h2("7.2 Crossover Topology")
        body("The engine uses a cascaded topology rather than three independent band-pass filters, which guarantees the bands always sum correctly:")
        code("Full-range mains\n  → [Lower crossover, low-pass]  → Low band            (all modes)\n  → [Lower crossover, high-pass] → combined Mid+High\n       → [Upper crossover, low-pass]  → Mid band        (Tri-Amp only)\n       → [Upper crossover, high-pass] → High band       (Tri-Amp only; = combined Mid+High for Bi-Amp)")
        body("Three band-count modes are available: Full Range (1 way — crossover disabled), Bi-Amp (2 way — one crossover point), and Tri-Amp (3 way — two crossover points, upper frequency must exceed lower).")

        h2("7.3 Filter Types")
        body("Each crossover point can independently use:")
        code("Linkwitz-Riley   Cascaded-pair Butterworth construction (§3.8) — flat magnitude sum,\n                 matched phase between bands. The standard choice for active crossovers.\nButterworth      Maximally-flat passband, but a same-order Butterworth crossover sums\n                 with a +3 dB bump at the crossover frequency unless corrected elsewhere.\nFIR              Linear-phase Linkwitz-Riley-equivalent magnitude response built as a\n                 finite impulse response (configurable tap count, default 4096 — about\n                 85 ms at 48 kHz). Adds latency but achieves genuinely zero phase\n                 distortion through the crossover region, which the optimiser and\n                 group-delay tools (§7.6–7.7) can exploit fully.")
        body("Available slopes match the EQ engine's full range (6 through 96 dB/octave).")

        h2("7.4 Asymmetric Crossover Points")
        body("Each crossover point's low-pass side and high-pass side can be configured independently — different frequency, different slope, and even a different filter type on each side of the same crossover point. This is useful when a driver's usable bandwidth is not symmetric around the nominal crossover frequency: for example, giving a woofer a slightly lower low-pass corner than the tweeter's high-pass corner to build in some acoustic overlap margin, or using a steeper slope on the high-pass side of a tweeter crossover to protect it while keeping the woofer's roll-off gentler for a smoother upper-bass rolloff.")

        h2("7.5 Acoustic Summation Prediction")
        body("Rather than trusting the crossover design in isolation, the engine can compute the predicted acoustic sum of all output channels' complete signal paths — crossover filter, per-output EQ, and any all-pass phase correction — as if all drivers were co-located:")
        code("channelResponse(f) = crossoverFilter(f) × perOutputEQ(f) × e^(−j·ω·delaySamples)\nsummedResponse(f) = Σ channelResponse_i(f)     (complex sum across all output channels)")
        body("The unit-delay phasor e^(−jω·delaySamples) accounts for any configured inter-channel delay (from driver time alignment, §7.8) before summation, so the prediction reflects what you'd actually measure at the listening position if the drivers were physically coincident. This lets you see — and the optimiser (§7.7) to correct — peaks or dips in the combined response at the crossover point before you've connected a measurement microphone.")

        h2("7.6 Group-Delay Analysis and Phase Alignment")
        body("Every output channel's group delay — crossover filter plus per-output EQ — can be computed across frequency and displayed, and an all-pass filter network can be automatically fitted to minimise group-delay error at the crossover points between adjacent bands. Uncorrected phase mismatch at a crossover point is one of the most common causes of an audible dip or smear in the transition region even when the magnitude response measures flat in isolation.")

        h2("7.7 Crossover Optimiser")
        body("An iterative, gradient-free optimiser can jointly adjust crossover frequencies and per-output EQ to minimise the weighted RMS error between the predicted acoustic sum (§7.5) and a target curve (defaulting to the Harman room curve), subject to configurable limits:")
        code("Default parameters:\n  optimisation range        20 Hz – 20 kHz\n  max iterations             200\n  convergence threshold      0.05 dB RMS change between iterations\n  max crossover step         50 Hz per iteration\n  max per-band EQ step       1.0 dB per iteration\n  max total EQ correction    12 dB")
        body("Crossover-slope changes and delay optimisation are available but disabled by default, since they represent larger, more disruptive steps than frequency and EQ adjustment; enable them only once you're comfortable with what the optimiser is doing to the more conservative parameters.")

        h2("7.8 Driver Time Alignment")
        body("Given a set of per-driver impulse-response measurements (captured with an external measurement microphone at the listening position), this tool automatically computes the delay needed to time-align every driver's acoustic arrival:")
        body("1. For each measured channel, find the peak of the impulse response within a 0–50 ms direct-sound search window (using the absolute value, so an inverted-polarity driver's peak is still found).")
        body("2. Convert each peak sample index to an arrival time in milliseconds.")
        body("3. The channel with the latest arrival time (i.e., the greatest physical or acoustic distance from the microphone) is chosen as the time reference; every other channel receives a delay equal to the difference in arrival time.")
        body("The same measurement also reports each driver's absolute polarity (correct / inverted / uncertain, based on the sign of the impulse-response peak), catching a reversed connection before it causes a crossover-region cancellation that would otherwise be mistaken for a frequency-response problem.")

        h2("7.9 Baffle Step Compensation")
        body("Below a frequency determined by cabinet width, a driver mounted on a flat baffle transitions from radiating into full space (4π steradians) to radiating into half space (2π) as the wavelength grows larger than the baffle — commonly heard as a \"thin\" or bass-shy character in the upper bass/lower midrange from an otherwise well-measured driver. Given the baffle's physical width (and optionally the driver's offset from the nearest edge), the calculator derives the transition frequency and a recommended shelf gain/Q to compensate:")
        code("f_transition = speedOfSound / (2π × driverToEdgeDistance)")
        body("with a recommended shelf gain near +6 dB for a full baffle-step case (less for open-baffle or very wide baffle designs where the effect is inherently smaller).")

        h2("7.10 Excursion Protection Limiter")
        body("A frequency-dependent limiter that protects a driver from mechanical over-excursion at frequencies below its resonance, where a fixed voltage produces the largest cone displacement. Built from the driver's Thiele-Small parameters — free-air resonance Fs and total Q Qts — the protection ceiling is progressively tightened as frequency falls below a configurable cutoff:")
        code("protectionGain(f) = min(maxProtectionDB, maxProtectionDB × (Fs/f)² / (1 + (Fs/f)²·Qts²))   for f < cutoffHz\nprotectionGain(f) = 0                                                                       for f ≥ cutoffHz\neffectiveCeiling(f) = baseCeilingDB − protectionGain(f)")
        body("Implemented as a 4-band multiband limiter with a frequency-dependent ceiling curve rather than a single broadband threshold, so protection is concentrated exactly where excursion risk is highest and the rest of the passband is left untouched.")

        h2("7.11 Per-Band Loudness Compensation")
        body("An ISO 226:2003-based correction (the same equal-loudness contour family used by the main Loudness Contour feature in §3.6) applied independently to the bass and treble output bands of a bi-amp or tri-amp system, so the tonal balance between amplifier-driven bands stays correct as overall listening level changes — available once Active Crossover is running in Bi-Amp or Tri-Amp mode, with a choice of level source (system volume, or integrated programme LUFS) and configurable reference level and maximum boost/cut limits.")

        h2("7.12 Multi-Device Synchronisation")
        body("Driving separate amplifiers from separate physical output devices (rather than a single multi-channel interface) requires the devices' clocks to be kept in sync, or their sample streams will slowly drift apart. Two strategies are offered:")
        code("Aggregate Device   CoreAudio's built-in aggregate-device mechanism handles synchronisation.\n                    Adds roughly 12–24 ms of sample-rate-conversion latency on slave devices.\n                    The most broadly compatible option.\nSoftware PLL        A software phase-locked loop measures drift between each secondary\n                    device's clock and the primary device's clock directly, and applies a\n                    continuous fractional sample-rate correction — no aggregate device, no\n                    added SRC latency, but higher CPU use and it requires the PLL to be\n                    correctly tuned for your specific device pair.")
        body("The software PLL is a proportional-integral loop filter with configurable bandwidth (default 0.5 Hz — lower is more stable but locks more slowly) and damping (default 0.707, critically damped), a maximum correction range of ±200 ppm, and a lock-in period of 20 callback cycles before engaging, to avoid a false lock on the very first few, potentially noisy, timestamp measurements.")

        h2("7.13 Band-Level SPL Calibration")
        body("Once output channels are assigned, each channel's relative level can be calibrated using a pink-noise test signal and an external SPL meter, entering the measured level per channel (plus, optionally, a microphone calibration offset) so the crossover's per-channel trim brings every driver to the same acoustic output level at the listening position — correcting for differences in driver sensitivity, amplifier gain, and distance that a purely electrical measurement would miss.")

        h2("7.14 Speaker System Presets")
        body("A complete output-channel-matrix configuration — crossover topology, frequencies, slopes, per-channel EQ, delays, and level trims — can be saved, recalled, and deleted as a named preset, letting you switch between, for example, a tri-amped main system and a stereo headphone configuration without reconfiguring each output channel by hand.")

        h2("Appendix A — Parameter Quick Reference")
        code("EQ BANDS\n  Gain           −36 … +36 dB\n  Frequency      1 Hz … max(22 kHz, min(0.45×fs, 96 kHz))   (scales up at high sample rates)\n  Q              0.1 … 100          Bandwidth  0.05 … 5.0 octaves\n  Bands/channel  1 … 64 (default 10)\n  Slopes (LP/HP/shelf only)   6, 12, 18, 24, 36, 48, 60, 72, 84, 96 dB/oct\n\nDYNAMICS DEFAULTS\n  LUFS target            −16 LUFS   (range −24 … −10)\n  De-Esser               6000 Hz, threshold −20 dB, ratio 10:1, range −12 dB\n  Multiband compressor   crossovers 150 / 3000 Hz, ratio 4:1, knee 6 dB\n  Wideband compressor    threshold −16 dB, ratio 3.5:1, knee 6 dB, attack 25 ms, release 150 ms\n  Expander               threshold −35 dB, ratio 1.5:1, range −12 dB\n  Soft clipper           threshold −1.5 dB, knee 0.5 (fraction of headroom)\n  Limiter                ceiling −0.2 dB, attack 0.1 ms, release 20 ms, look-ahead 2 ms\n\nROOM CORRECTION\n  IIR bands       up to 20, ±12 dB max, stop at 0.5 dB residual\n  FIR taps        1024 / 2048 / 4096 / 8192 / 16384\n  Schroeder freq  200–500 Hz typical (default 300 Hz)\n\nACTIVE CROSSOVER\n  Bands            Full Range (1) / Bi-Amp (2) / Tri-Amp (3)\n  Filter types     Linkwitz-Riley, Butterworth, FIR linear-phase\n  FIR taps         default 4096 (≈85 ms @ 48 kHz)\n  PLL              bandwidth 0.5 Hz, damping 0.707, max correction ±200 ppm")

        h2("Appendix B — Glossary")
        code("Biquad            A second-order IIR filter section; the basic building block of every\n                  EQ band, crossover, and correction filter in this application.\nCrest factor      Peak-to-RMS ratio in dB; a measure of transient \"spikiness\".\nGroup delay       Frequency-dependent time delay through a filter; the derivative of\n                  phase with respect to frequency.\nLinkwitz-Riley    A crossover alignment built from cascaded same-frequency Butterworth\n                  sections, chosen because same-order low-pass/high-pass legs sum to a\n                  flat magnitude response with matched phase.\nLUFS              Loudness Units relative to Full Scale; the standard unit for\n                  K-weighted integrated loudness (ITU-R BS.1770).\nMinimum-phase     A filter whose phase response is the unique one implied by its\n                  magnitude response via the Hilbert-transform relationship; has no\n                  pre-ringing, unlike a linear-phase filter of the same magnitude shape.\nPearson           A correlation coefficient measuring how linearly related two signals\ncorrelation       are; used here for the L/R phase meter (+1 in-phase, −1 anti-phase).\nQ factor          A dimensionless measure of filter selectivity/narrowness.\nSchroeder freq.   The frequency above which a room's reverberant field becomes\n                  statistically diffuse rather than dominated by discrete modes.\nTrue peak         The reconstructed analogue peak level, which can exceed the highest\n                  individual digital sample value between two adjacent samples.")

        return result
    }
}

// #Preview("Settings") {
//     SettingsView()
//         .environmentObject(EqualiserStore())
// }

