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
                Banner(kind: .warning, text: warning)
            }
            master
            liveSyncRow
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
        if case .failed(let m) = engine.captureStatus { return m }
        if engine.isEnabled && engine.systemAudioPermission == .denied {
            return "System Audio Recording permission is off. Enable SyncForge in System Settings › Privacy & Security."
        }
        return nil
    }

    private var master: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Master Volume").font(.caption).foregroundStyle(.secondary)
            VolumeSlider(value: engine.settingsBinding(\.masterVolume), muted: engine.settingsBinding(\.masterMuted))
            HStack {
                Text("System EQ").font(.caption).foregroundStyle(.secondary)
                Menu(engine.store.settings.systemDSP.enabled ? engine.store.settings.systemDSP.presetName : "Off") {
                    Button("Off") { engine.updateSettings { $0.systemDSP.enabled = false } }
                    Divider()
                    ForEach(engine.store.allPresets) { preset in
                        Button(preset.name) {
                            engine.updateSettings { s in
                                var d = preset.settings
                                d.enabled = true
                                s.systemDSP = d
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

    private var liveSyncRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: model.liveSyncBinding) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("Live Sync")
                        if model.liveSync.micInUse { Image(systemName: "mic.fill").foregroundStyle(.orange).font(.caption) }
                    }
                    Text(model.settings.liveSyncEnabled ? model.liveSyncStatus : "Keeps Bluetooth in sync while music plays (uses the mic)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
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
                    .disabled(!output.isConnected && !output.profile.enabled)
                Image(systemName: output.transport.symbol).frame(width: 16).foregroundStyle(.secondary)
                Text(output.name).lineLimit(1)
                Spacer()
                Circle().fill(output.statusColor).frame(width: 7, height: 7)
                    .help(output.status.label)
            }
            if output.profile.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    VolumeSlider(value: engine.profileBinding(output.uid, \.volume, fallback: 1),
                                 muted: engine.profileBinding(output.uid, \.muted, fallback: false))
                    HStack(spacing: 10) {
                        Text("Delay \(output.timing.map { "+" + formatMs($0.appliedDelayMs, decimals: 0) } ?? "—")")
                        Text("EQ \(output.profile.dsp.enabled ? output.profile.dsp.presetName : "Off")")
                        Text(output.status == .playing ? output.syncSummary : output.status.label).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    OutputLevelMeter(uid: output.uid, height: 3)
                }
                .padding(.leading, 24)
            }
        }
    }
}
