import SwiftUI
import SyncForgeCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            Group {
                switch model.section {
                case .outputs: OutputsView()
                case .equalizer: EqualizerView()
                case .calibration: CalibrationView()
                case .syncTest: SyncTestView()
                case .settings: SettingsView()
                }
            }
            .frame(minWidth: 640, minHeight: 520)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: model.engine.enabledBinding) {
                    Label(model.engine.isEnabled ? "Active" : "Off", systemImage: "power")
                }
                .toggleStyle(.switch)
                .help("Start or stop SyncForge")
                .disabled(model.calibration.isRunning)
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            model.engine.refreshPermissions()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
        .showsLiveMeters(model.engine)
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.calibration.micInUse {
                Label("Microphone in use", systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 6) {
                Circle().fill(engineColor).frame(width: 7, height: 7)
                Text(engineText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var engineColor: Color {
        guard model.engine.isEnabled else { return .secondary }
        if case .failed = model.engine.captureStatus { return .red }
        return .green
    }

    private var engineText: String {
        guard model.engine.isEnabled else { return "Off" }
        switch model.engine.captureStatus {
        case .running(let sr): return String(format: "Capturing %.1f kHz", sr / 1000)
        case .failed: return "Capture failed"
        case .stopped: return "Idle"
        }
    }
}

// MARK: - Outputs

struct OutputsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Outputs", subtitle: "One audio source, every selected output in sync, independent processing per device.")
                banners
                Card {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Audio Source").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Image(systemName: "macwindow.on.rectangle")
                                Text("System Audio").font(.headline)
                            }
                            CaptureLevelMeter().frame(width: 160)
                        }
                        Divider().frame(height: 50)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Master Volume").font(.caption).foregroundStyle(.secondary)
                            VolumeSlider(value: engine.settingsBinding(\.masterVolume), muted: engine.settingsBinding(\.masterMuted), accessibilityName: "Master volume")
                                .disabled(model.calibration.isRunning)
                        }
                        Divider().frame(height: 50)
                        VStack(alignment: .trailing, spacing: 6) {
                            Button {
                                model.section = .calibration
                                model.calibrate()
                            } label: {
                                Label("Calibrate All", systemImage: "waveform.badge.mic")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!engine.isEnabled || engine.activeOutputUIDs.isEmpty || model.calibration.isRunning)
                            Text(String(format: "Base latency %.0f ms", engine.effectiveBaseLatencyMs))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(sortedOutputs) { output in
                    OutputCard(output: output)
                }
            }
            .padding(20)
        }
    }

    private var sortedOutputs: [OutputState] {
        model.engine.outputs.sorted {
            let lhs = ($0.profile.enabled ? 0 : 1, $0.name.localizedLowercase, $0.uid)
            let rhs = ($1.profile.enabled ? 0 : 1, $1.name.localizedLowercase, $1.uid)
            return lhs < rhs
        }
    }

    @ViewBuilder private var banners: some View {
        let engine = model.engine
        if !engine.isEnabled {
            Banner(kind: .info, text: "SyncForge is off. macOS plays audio normally. Select outputs and turn SyncForge on.",
                   actionTitle: "Turn On") { engine.setEnabled(true) }
        }
        if case .failed(let m) = engine.captureStatus {
            Banner(kind: .error, text: "SyncForge could not start: \(m)")
        }
        if engine.isEnabled && engine.systemAudioPermission == .denied {
            Banner(kind: .warning, text: "SyncForge does not have System Audio Recording permission, so outputs receive silence.",
                   actionTitle: "Open Settings") { NSWorkspace.shared.open(SystemAudioPermission.settingsURL) }
        }
        if engine.isEnabled && engine.outputs.filter({ $0.profile.enabled }).isEmpty {
            Banner(kind: .info, text: "Enable at least one output below. While SyncForge is on, audio plays only through the outputs you select.")
        }
        if let e = engine.store.loadError { Banner(kind: .warning, text: e) }
    }
}

struct OutputCard: View {
    @Environment(AppModel.self) private var model
    let output: OutputState

    var body: some View {
        let engine = model.engine
        let uid = output.uid
        Card {
            HStack(spacing: 10) {
                Toggle("", isOn: engine.profileBinding(uid, \.enabled, fallback: false))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Enable \(output.name)")
                Image(systemName: output.transport.symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.name).font(.headline)
                    Text(deviceLine).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(text: output.status.label, color: output.statusColor)
            }

            if output.profile.enabled {
                HStack(spacing: 14) {
                    VolumeSlider(value: engine.profileBinding(uid, \.volume, fallback: 1),
                                 muted: engine.profileBinding(uid, \.muted, fallback: false), accessibilityName: "\(output.name) volume")
                        .frame(maxWidth: 340)
                    Spacer(minLength: 0)
                    Button(engine.soloOutputUID == uid ? "Unsolo" : "Solo") { engine.toggleSolo(uid) }
                        .controlSize(.small)
                        .tint(engine.soloOutputUID == uid ? .accentColor : nil)
                        .disabled(output.status != .playing || model.calibration.isRunning)
                        .help("Listen to this output alone without changing other outputs' volume or mute settings")
                    Button("Edit EQ…") { model.openEqualizer(for: uid) }.controlSize(.small)
                }
                HStack(spacing: 10) {
                    OutputLevelMeter(uid: uid).frame(width: 140)
                    Text(engine.soloOutputUID.map { $0 == uid ? "Solo playback" : "Silenced by solo" }
                         ?? equalizerSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(equalizerSummary)
                    Spacer()
                    Text(output.syncSummary)
                        .font(.caption)
                        .foregroundStyle(output.profile.calibration?.needsRecalibration == true ? .orange : .secondary)
                }
                DisclosureGroup("Channels, timing & diagnostics") {
                    OutputDetails(output: output)
                        .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .disabled(model.calibration.isRunning)
    }

    private var equalizerSummary: String {
        var summary = output.profile.dsp.enabled ? output.profile.dsp.presetName : "EQ bypassed"
        let systemDSP = model.engine.store.settings.systemDSP
        if output.profile.useSystemEQ && systemDSP.enabled && !systemDSP.isNeutral {
            summary += " + System “\(systemDSP.presetName)”"
        }
        return summary
    }

    private var deviceLine: String {
        var parts = [output.transport.displayName]
        if let d = output.device {
            parts.append(String(format: "%.1f kHz", d.nominalSampleRate / 1000))
            parts.append("\(d.outputChannels) ch")
            if let src = d.dataSourceName, src != d.name { parts.append(src) }
        } else {
            parts.append("not connected")
        }
        if output.isDefaultOutput { parts.append("macOS default output") }
        return parts.joined(separator: " · ")
    }
}

private struct OutputDetails: View {
    @Environment(AppModel.self) private var model
    let output: OutputState

    var body: some View {
        let engine = model.engine
        let uid = output.uid
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Channels").foregroundStyle(.secondary)
                    HStack {
                        Picker("Channel mode", selection: engine.profileBinding(uid, \.channelMode, fallback: .stereo)) {
                            ForEach(ChannelMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .disabled((output.device?.outputChannels ?? 2) < 2)
                        if let d = output.device, d.outputChannels > 2 { channelPairPicker(d) }
                    }
                }
                GridRow {
                    Text("Delay").foregroundStyle(.secondary)
                    DelayControls(output: output)
                }
                GridRow {
                    Text("Sync").foregroundStyle(.secondary)
                    syncInfo
                }
                if abs(output.profile.levelTrimDb) > 0.05 {
                    GridRow {
                        Text("Level trim").foregroundStyle(.secondary)
                        HStack {
                            Text(String(format: "%+.1f dB from calibration", output.profile.levelTrimDb))
                            Button("Reset") {
                                engine.performUndoableChange(named: "Reset Level Trim") {
                                    engine.updateProfile(uid) { $0.levelTrimDb = 0 }
                                }
                            }.controlSize(.small)
                        }
                    }
                }
            }
            OutputMeterRow(uid: uid)
        }
    }

    private func channelPairPicker(_ d: AudioDeviceInfo) -> some View {
        let engine = model.engine
        let pairs = stride(from: 1, to: d.outputChannels, by: 2).map { ($0, $0 + 1) }
        return Picker("Pair", selection: Binding(
            get: { output.profile.leftChannel ?? d.preferredStereo.0 },
            set: { l in
                engine.performUndoableChange(named: "Change Output Channels") {
                    engine.updateProfile(output.uid) { $0.leftChannel = l; $0.rightChannel = l + 1 }
                }
            })) {
            ForEach(pairs, id: \.0) { p in Text("Ch \(p.0)–\(p.1)").tag(p.0) }
        }
        .frame(width: 140)
    }

    @ViewBuilder private var syncInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let t = output.timing {
                HStack(spacing: 16) {
                    Label(String(format: "%@ latency %.1f ms", t.latencySource == .measured ? "Measured" : "Driver-estimated", t.latencyMs),
                          systemImage: t.latencySource == .measured ? "checkmark.seal" : "questionmark.circle")
                    Label(String(format: "Compensation +%.1f ms", t.appliedDelayMs), systemImage: "timer")
                }
                .font(.callout)
            }
            Text(output.syncSummary).font(.caption).foregroundStyle(output.profile.calibration?.needsRecalibration == true ? .orange : .secondary)
            if let reason = output.profile.calibration?.recalibrationReason, output.profile.calibration?.needsRecalibration == true {
                HStack {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    Button("Recalibrate") { model.section = .calibration; model.calibrate(outputs: [output.uid]) }
                        .controlSize(.small)
                        .disabled(model.calibration.isRunning)
                }
            }
            if output.timing?.latencySource == .driverEstimate {
                Text("Driver latency figures are often wrong for Bluetooth. Calibrate with a microphone or adjust by ear in Sync Test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OutputMeterRow: View {
    @Environment(AppModel.self) private var model
    let uid: String

    var body: some View {
        let m = model.engine.meters[uid] ?? OutputMeters()
        HStack(spacing: 14) {
            LevelMeter(db: m.peakDb, clipping: m.clipping).frame(maxWidth: 220)
            if m.clipping { Text("CLIP").font(.caption2.bold()).foregroundStyle(.red) }
            else if m.limiting { Text("LIMIT").font(.caption2.bold()).foregroundStyle(.orange) }
            Spacer()
            Group {
                Text(String(format: "clock %+.0f ppm", m.correctionPPM))
                Text(String(format: "lock %.2f ms", m.servoErrorMs))
                if m.underruns > 0 { Text("\(m.underruns) underruns").foregroundStyle(.orange) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .help("Clock: resampling correction against this device's clock. Lock: deviation from the programmed delay.")
    }
}

/// Automatic / manual delay with coarse and fine controls.
struct DelayControls: View {
    @Environment(AppModel.self) private var model
    @State private var isEditingDelay = false
    let output: OutputState

    var body: some View {
        let engine = model.engine
        let uid = output.uid
        let maxDelay = engine.store.settings.maxDelayMs
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: engine.profileBinding(uid, \.delayMode, fallback: .automatic)) {
                    Text("Automatic").tag(DelayMode.automatic)
                    Text("Manual").tag(DelayMode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Text(String(format: "+%.1f ms applied", output.timing?.appliedDelayMs ?? 0))
                    .font(.callout.monospacedDigit())
                if output.timing?.clamped == true {
                    Text("(limited to \(Int(maxDelay)) ms)").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Reset") {
                    engine.performUndoableChange(named: "Reset Delay") { engine.resetDelay(uid) }
                }
                    .controlSize(.small)
                    .help("Back to the measured compensation without fine trim")
            }
            if output.profile.delayMode == .automatic {
                HStack {
                    Text("Fine trim").font(.caption).foregroundStyle(.secondary)
                    DelayAdjuster(value: engine.profileBinding(uid, \.trimMs, fallback: 0), range: -200...200,
                                  steps: [-1, -0.1, 0.1, 1])
                }
            } else {
                HStack {
                    Slider(value: engine.profileBinding(uid, \.manualDelayMs, fallback: 0), in: 0...maxDelay, onEditingChanged: delayEditingChanged)
                        .frame(maxWidth: 260)
                    DelayAdjuster(value: engine.profileBinding(uid, \.manualDelayMs, fallback: 0), range: 0...maxDelay)
                }
            }
        }
        .onDisappear { delayEditingChanged(false) }
    }

    private func delayEditingChanged(_ editing: Bool) {
        guard editing != isEditingDelay else { return }
        isEditingDelay = editing
        if editing { model.engine.beginUndoableChange(named: "Adjust Delay") }
        else { model.engine.endUndoableChange() }
    }
}
