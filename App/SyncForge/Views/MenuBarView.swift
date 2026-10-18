import SwiftUI
import SyncForgeCore

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var engine: SyncEngine { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let warning = globalWarning {
                Banner(kind: .warning, text: warning,
                       actionTitle: permissionBlocked ? "Open Permission Settings" : "Retry Audio",
                       action: {
                           if permissionBlocked { NSWorkspace.shared.open(SystemAudioPermission.settingsURL) }
                           else { model.retryAudio() }
                       }, stacksAction: true)
                    .disabled(model.calibration.isRunning && !permissionBlocked)
            }
            MenuSetupPicker(engine: engine, openSettings: {
                model.section = .settings
                showMainWindow()
            })
            .disabled(model.calibration.isRunning)
            master
                .disabled(model.calibration.isRunning)
            MenuLiveSyncView()
            Divider()
            outputs
            if model.calibration.isRunning { calibrationStatus }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .showsLiveMeters(engine)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "hifispeaker.2.fill")
                .font(.title2)
                .foregroundStyle(engine.isEnabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("SyncForge").font(.headline)
                Text(sourceLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: engine.enabledBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(engine.isEnabled ? "Stop SyncForge and restore normal macOS audio" : "Start SyncForge")
                .disabled(model.calibration.isRunning)
        }
    }

    private var sourceLine: String {
        guard engine.isEnabled else { return "Off — macOS plays audio normally" }
        let active = engine.outputs.filter { $0.status == .playing }.count
        switch engine.captureStatus {
        case .running: return "System Audio → \(active) output\(active == 1 ? "" : "s")"
        case .failed: return "System audio capture failed"
        case .stopped: return active == 0 ? "Select outputs below" : "Starting…"
        }
    }

    private var globalWarning: String? {
        if permissionBlocked {
            return "System Audio Recording permission is off. Enable SyncForge in System Settings › Privacy & Security."
        }
        if case .failed(let m) = engine.captureStatus { return m }
        return nil
    }

    private var permissionBlocked: Bool { engine.isEnabled && engine.systemAudioPermission == .denied }

    private var master: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Master Volume").font(.caption).foregroundStyle(.secondary)
            VolumeSlider(value: engine.settingsBinding(\.masterVolume), muted: engine.settingsBinding(\.masterMuted), accessibilityName: "Master volume")
            HStack {
                Text("System EQ").font(.caption).foregroundStyle(.secondary)
                Menu(engine.store.settings.systemDSP.enabled ? engine.store.settings.systemDSP.presetName : "Off") {
                    Button("Off") {
                        engine.performUndoableChange(named: "Turn Off System EQ") {
                            engine.updateSettings { $0.systemDSP.enabled = false }
                        }
                    }
                    Divider()
                    ForEach(engine.store.allPresets) { preset in
                        Button(preset.name) {
                            engine.performUndoableChange(named: "Apply System EQ Preset") {
                                engine.updateSettings { s in
                                    var d = preset.settings
                                    d.enabled = true
                                    s.systemDSP = d
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Edit…") {
                        model.equalizerUID = systemEQTag
                        model.section = .equalizer
                        showMainWindow()
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        }
    }

    private var outputs: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OUTPUT DEVICES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(engine.outputs) { output in
                MenuOutputRow(output: output)
            }
            if engine.outputs.isEmpty {
                Text("No output devices found.").foregroundStyle(.secondary)
            }
        }
    }

    private var calibrationStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mic.fill").foregroundStyle(.orange)
                Text("Calibrating — microphone in use").font(.callout)
                Spacer()
                Button("Cancel") { model.cancelCalibration() }.controlSize(.small)
            }
            ProgressView(value: model.calibration.progress)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.section = .calibration
                showMainWindow()
                model.calibrate()
            } label: {
                Label("Calibrate All", systemImage: "waveform.badge.mic")
            }
            .disabled(!engine.isEnabled || model.calibration.isRunning || engine.activeOutputUIDs.isEmpty)
            Spacer()
            Button("Open SyncForge…") { showMainWindow() }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit SyncForge")
            .keyboardShortcut("q")
        }
        .controlSize(.regular)
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuSetupPicker: View {
    let engine: SyncEngine
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Setup").font(.caption).foregroundStyle(.secondary)
            Menu {
                ForEach(engine.store.setups) { setup in
                    Button {
                        engine.performUndoableChange(named: "Restore Setup") { engine.applySetup(setup) }
                    } label: {
                        if engine.selectedSetupID == setup.id { Label(setup.name, systemImage: "checkmark") }
                        else { Text(setup.name) }
                    }
                }
                if !engine.store.setups.isEmpty { Divider() }
                if let setup = engine.selectedSetup {
                    Button("Update Current Setup") {
                        engine.performUndoableChange(named: "Update Setup") { _ = engine.updateSetup(setup.id) }
                    }
                    .disabled(!engine.isSelectedSetupModified)
                }
                Button("Manage Setups…", action: openSettings)
            } label: {
                Text(engine.selectedSetup?.name ?? "Custom")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Current setup")
            .accessibilityValue(currentLabel)
            if engine.isSelectedSetupModified {
                Text("Modified").font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    private var currentLabel: String {
        engine.selectedSetup.map { $0.name + (engine.isSelectedSetupModified ? " · Modified" : "") } ?? "Custom"
    }
}

private struct MenuLiveSyncView: View {
    @Environment(AppModel.self) private var model
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: model.liveSyncBinding) {
                HStack(spacing: 4) {
                    Text("Live Sync")
                    if model.liveSync.micInUse {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.orange).font(.caption)
                            .accessibilityLabel("Microphone in use")
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.calibration.isRunning)
            DisclosureGroup(isExpanded: $detailsExpanded) {
                Text(model.settings.liveSyncEnabled ? model.liveSyncStatus : "Keeps Bluetooth in sync while music plays (uses the mic).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if model.settings.liveSyncEnabled && MicrophonePermission.status() == .denied {
                    Button("Open Permission Settings") { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }
                        .controlSize(.small)
                }
            } label: {
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        guard model.settings.liveSyncEnabled else { return "About Live Sync" }
        switch model.liveSync.state {
        case .off: return "Off · Details"
        case .waiting: return "Waiting · Details"
        case .failed: return "Needs attention · Details"
        case .monitoring: return "Listening · Details"
        }
    }
}

private struct MenuOutputRow: View {
    @Environment(AppModel.self) private var model
    let output: OutputState

    var body: some View {
        let engine = model.engine
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: engine.profileBinding(output.uid, \.enabled, fallback: false))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Enable \(output.name)")
                    .disabled(model.calibration.isRunning || (!output.isConnected && !output.profile.enabled))
                Image(systemName: output.transport.symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(output.name).lineLimit(1)
                Spacer()
                if output.profile.enabled {
                    Button(engine.soloOutputUID == output.uid ? "Unsolo" : "Solo") { engine.toggleSolo(output.uid) }
                        .controlSize(.small)
                        .disabled(output.status != .playing || model.calibration.isRunning)
                        .help(engine.soloOutputUID == output.uid ? "Play all enabled outputs" : "Listen to only \(output.name)")
                        .accessibilityLabel(engine.soloOutputUID == output.uid ? "End solo for \(output.name)" : "Solo \(output.name)")
                }
                Circle().fill(output.statusColor).frame(width: 7, height: 7)
                    .help(output.status.label)
            }
            if output.profile.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    VolumeSlider(value: engine.profileBinding(output.uid, \.volume, fallback: 1),
                                 muted: engine.profileBinding(output.uid, \.muted, fallback: false),
                                 accessibilityName: "\(output.name) volume")
                    HStack(spacing: 10) {
                        Text("Delay \(output.timing.map { "+" + formatMs($0.appliedDelayMs, decimals: 0) } ?? "—")")
                        Text("EQ \(output.profile.dsp.enabled ? output.profile.dsp.presetName : "Off")")
                        Text(playbackSummary).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    OutputLevelMeter(uid: output.uid, height: 3)
                    if output.profile.calibration?.needsRecalibration == true {
                        Button("Recalibrate \(output.name)") { model.calibrate(outputs: [output.uid]) }
                            .buttonStyle(.link)
                            .font(.caption)
                            .disabled(!engine.isEnabled || !output.isConnected || model.calibration.isRunning)
                    }
                    if case .error(let message) = output.status {
                        Banner(kind: .error, text: message, actionTitle: "Retry Audio", action: { model.retryAudio() }, stacksAction: true)
                    }
                }
                .padding(.leading, 24)
                .disabled(model.calibration.isRunning)
            }
        }
    }

    private var playbackSummary: String {
        if let solo = model.engine.soloOutputUID {
            return solo == output.uid ? "Solo playback" : "Silenced by solo"
        }
        return output.status == .playing ? output.syncSummary : output.status.label
    }
}
