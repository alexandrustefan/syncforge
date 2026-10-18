import SwiftUI
import SyncForgeCore

struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var selectionInitialized = false
    @State private var micPermission = MicrophonePermission.status()

    private var candidates: [OutputState] {
        model.engine.outputs.filter { $0.profile.enabled && $0.isConnected }
            .sorted { ($0.name.localizedLowercase, $0.uid) < ($1.name.localizedLowercase, $1.uid) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Calibration", subtitle: "Use your Mac or iPhone microphone to align Bluetooth and wired speakers.")
                if model.calibration.isRunning { CalibrationProgressCard() }
                CalibrationSetupCard(outputs: candidates, selected: $selected, micPermission: $micPermission)
                if !model.calibration.isRunning {
                    if !model.calibration.measurements.isEmpty { CalibrationResultsCard() }
                    else if model.calibration.phase != .idle { CalibrationProgressCard() }
                }
                CalibrationLiveSyncCard()
                CalibrationHistoryCard()
                DisclosureGroup("How calibration works") {
                    Text("Each speaker plays short sweeps while the microphone listens. SyncForge compares repeated measurements and adds delay to the faster outputs. Verification, when enabled, measures the remaining timing difference at the microphone. Room reflections and background noise can affect the result. Audio is analysed in memory and is not saved.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .font(.body)
            .controlSize(.regular)
            .frame(maxWidth: 820, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            micPermission = MicrophonePermission.status()
            if !selectionInitialized {
                selected = Set(candidates.map(\.uid))
                selectionInitialized = true
            }
        }
        .onChange(of: candidates.map(\.uid)) { _, uids in
            selected.formIntersection(uids)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            micPermission = MicrophonePermission.status()
        }
    }
}

private struct CalibrationSetupCard: View {
    @Environment(AppModel.self) private var model
    let outputs: [OutputState]
    @Binding var selected: Set<String>
    @Binding var micPermission: MicrophonePermission.Status

    private var engine: SyncEngine { model.engine }
    private var mic: AudioDeviceInfo? { engine.devices.inputDevice(uid: model.microphoneUID ?? "") }
    private var microphones: [AudioDeviceInfo] { engine.devices.inputDevices.filter { $0.transport != .virtual } }
    private var canStart: Bool {
        engine.isEnabled && !model.calibration.isRunning && mic != nil && mic?.transport.isBluetooth != true
            && micPermission != .denied && !selected.isEmpty
            && selected.allSatisfy { uid in outputs.contains { $0.uid == uid && $0.status == .playing } }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Microphone").font(.headline)
                    Picker("Microphone", selection: Binding(get: { mic?.uid ?? "" }, set: { model.setMicrophone($0) })) {
                        if mic == nil { Text("Choose a microphone").tag("") }
                        ForEach(microphones) { device in
                            Text(device.name + (device.transport.isBluetooth ? " (Bluetooth)" : "")).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420, alignment: .leading)
                    Text("Place the microphone where you listen and keep the room quiet.")
                        .foregroundStyle(.secondary)
                    if mic?.transport.isBluetooth == true {
                        Label("Use a built-in, USB or Continuity microphone. Bluetooth microphones change the speaker's audio mode and latency.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if micPermission == .denied {
                        HStack(spacing: 12) {
                            Label("Microphone access is off.", systemImage: "mic.slash")
                            Button("Open Privacy Settings") { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }
                        }
                    } else if micPermission == .notDetermined {
                        Text("macOS will ask for microphone access when you start.").foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Speakers").font(.headline)
                        Spacer()
                        Button("Choose Outputs…") { model.section = .outputs }
                    }
                    if outputs.isEmpty {
                        Text("Enable the speakers you want to calibrate in Outputs.").foregroundStyle(.secondary)
                    } else {
                        ForEach(outputs) { output in
                            Toggle(isOn: Binding(get: { selected.contains(output.uid) }, set: { on in
                                if on { selected.insert(output.uid) } else { selected.remove(output.uid) }
                            })) {
                                HStack {
                                    Label(output.name, systemImage: output.transport.symbol)
                                    Spacer()
                                    if engine.isEnabled && output.status != .playing {
                                        Text(output.status.label).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                Divider()
                CalibrationAdvancedOptions()
            }
            .disabled(model.calibration.isRunning)
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 12) {
                Text(readiness).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.calibration.isRunning {
                    HStack(spacing: 12) {
                        Button("Start Calibration") {
                            micPermission = MicrophonePermission.status()
                            guard canStart else { return }
                            model.calibrate(outputs: outputs.filter { selected.contains($0.uid) }.map(\.uid))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStart)
                        if !engine.isEnabled {
                            Button("Turn On SyncForge") { engine.setEnabled(true) }
                                .disabled(selected.isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var readiness: String {
        if model.calibration.isRunning { return "Keep the microphone in place until calibration finishes." }
        if selected.isEmpty { return "Select at least one speaker to continue." }
        if !engine.isEnabled { return "Turn on SyncForge, then start calibration when you are ready." }
        if mic == nil { return "Choose a microphone to continue." }
        if micPermission == .denied { return "Allow microphone access in System Settings to continue." }
        if mic?.transport.isBluetooth == true { return "Choose a microphone that does not use Bluetooth to continue." }
        if !selected.allSatisfy({ uid in outputs.contains { $0.uid == uid && $0.status == .playing } }) {
            return "Wait for the selected speakers to start, or check their status in Outputs."
        }
        return "Ready. Music pauses while the selected speakers play short test sweeps."
    }
}

private struct CalibrationAdvancedOptions: View {
    @Environment(AppModel.self) private var model
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Calibration options") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("Adjust speaker tone and room bass (auto-EQ)", isOn: model.engine.settingsBinding(\.autoEQAfterCalibration))
                    Toggle("Match speaker levels at the microphone", isOn: model.engine.settingsBinding(\.matchLevelsAfterCalibration))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Test level")
                            Spacer()
                            Text(String(format: "%.0f dBFS", model.settings.calibrationLevelDb)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: model.engine.settingsBinding(\.calibrationLevelDb), in: -36 ... -6, onEditingChanged: editingChanged)
                            .accessibilityLabel("Calibration test level")
                        Text("The test may repeat louder if a speaker is hard to hear.").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Latency search range")
                            Spacer()
                            Text(String(format: "Up to %.0f ms", model.settings.calibrationMaxLatencyMs)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: model.engine.settingsBinding(\.calibrationMaxLatencyMs), in: 500...4000, step: 100, onEditingChanged: editingChanged)
                            .accessibilityLabel("Calibration latency search range")
                    }
                }
                .padding(.top, 12)
            }
        }
        .onDisappear { editingChanged(false) }
    }

    private var summary: String {
        let tone = model.settings.autoEQAfterCalibration ? "Tone correction on" : "Tone correction off"
        let level = model.settings.matchLevelsAfterCalibration ? "Level matching on" : "Level matching off"
        return tone + " · " + level
    }

    private func editingChanged(_ editing: Bool) {
        guard editing != isEditing else { return }
        isEditing = editing
        if editing { model.engine.beginUndoableChange(named: "Change Calibration Options") }
        else { model.engine.endUndoableChange() }
    }
}

private struct CalibrationLiveSyncCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Sync").font(.headline)
                    Text("Optional monitoring for Bluetooth timing changes. Uses the microphone while music plays.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Live Sync", isOn: model.liveSyncBinding).toggleStyle(.switch).labelsHidden()
                    .disabled(model.calibration.isRunning)
            }
            HStack(spacing: 8) {
                Text(model.settings.liveSyncEnabled ? model.liveSyncStatus : "Off").foregroundStyle(.secondary)
                if model.liveSync.micInUse { Label("Microphone in use", systemImage: "mic.fill").foregroundStyle(.secondary) }
            }
            if model.settings.liveSyncAfterCalibration {
                Text("Set to turn on after calibration when wired and wireless outputs are available.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Requirements & options") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Needs a calibration with the selected microphone, a wired output and one wireless output, with music playing. Live Sync keeps the microphone open and analyses audio in memory.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Turn on after calibration", isOn: model.engine.settingsBinding(\.liveSyncAfterCalibration))
                        .disabled(model.calibration.isRunning)
                }
                .padding(.top, 10)
            }
        }
    }
}

private struct CalibrationHistoryCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Card {
            DisclosureGroup("Calibration history") {
                VStack(alignment: .leading, spacing: 14) {
                    if model.previousCalibrationRestored {
                        Text("Previous calibration restored.").foregroundStyle(.secondary)
                    }
                    if model.canRestorePreviousCalibration {
                        Text("Return to the timing, tone and level settings from before the last calibration change.")
                            .foregroundStyle(.secondary)
                        Button("Restore Previous Calibration") { model.restorePreviousCalibration() }
                    }
                    Text("Reset removes measured timing, calibration corrections and level trims. Your volumes, EQ presets and selected outputs are kept.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reset Calibration…") { confirmReset = true }
                        .disabled(model.calibration.isRunning)
                }
                .padding(.top, 12)
            }
        }
        .confirmationDialog("Reset calibration?", isPresented: $confirmReset) {
            Button("Reset Calibration", role: .destructive) { model.startOver() }
        } message: {
            Text("Measured timing, tone corrections, room correction and level trims will be cleared. Volumes, EQ presets and selected outputs are kept.")
        }
    }
}

private struct CalibrationProgressCard: View {
    @Environment(AppModel.self) private var model
    @State private var progressAnchorDate: Date?
    @State private var progressAnchorValue = 0.0

    private var cal: CalibrationEngine { model.calibration }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(cal.isRunning ? "Calibration in progress" : phaseText).font(.headline)
                Spacer()
                if cal.isRunning { Button("Cancel Calibration", role: .cancel) { model.cancelCalibration() } }
            }
            if cal.isRunning {
                Text(phaseText).foregroundStyle(.secondary)
                ProgressView(value: cal.progress)
                HStack {
                    if let index = cal.currentSpeakerIndex, cal.speakerCount > 0 {
                        Text("Speaker \(index) of \(cal.speakerCount)")
                    } else if cal.speakerCount > 0 {
                        Text("\(cal.speakerCount) speaker\(cal.speakerCount == 1 ? "" : "s")")
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(remainingTimeText(at: context.date))
                    }
                }
                .foregroundStyle(.secondary)
            }
            if cal.micInUse {
                HStack(spacing: 12) {
                    Label("Microphone in use", systemImage: "mic.fill").foregroundStyle(.secondary)
                    LevelMeter(db: cal.micLevelDb).frame(width: 140)
                }
            }
            if !cal.log.isEmpty {
                DisclosureGroup("Measurement log") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(cal.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
            }
        }
        .onAppear { if cal.isRunning { beginProgressEstimate() } }
        .onChange(of: cal.isRunning) { _, running in
            if running { beginProgressEstimate() }
            else { progressAnchorDate = nil }
        }
    }

    private func beginProgressEstimate() {
        progressAnchorDate = Date()
        progressAnchorValue = cal.progress
    }

    private func remainingTimeText(at date: Date) -> String {
        guard let started = progressAnchorDate else { return "Estimating time…" }
        let elapsed = date.timeIntervalSince(started)
        let completed = cal.progress - progressAnchorValue
        guard elapsed >= 10, completed >= 0.15 else { return "Estimating time…" }
        let seconds = elapsed / completed * max(0, 1 - cal.progress)
        guard seconds.isFinite else { return "Time varies with retries" }
        let rounded = max(10, Int((seconds / 10).rounded(.up)) * 10)
        if rounded >= 60 { return "About \(Int(ceil(Double(rounded) / 60))) min left · varies with retries" }
        return "About \(rounded) sec left · varies with retries"
    }

    private var phaseText: String {
        switch cal.phase {
        case .idle: return ""
        case .preparing: return "Preparing…"
        case .listening: return "Measuring background noise…"
        case .measuring(let name): return "Measuring \(name)…"
        case .applying: return "Applying compensation…"
        case .verifying(let name): return "Verifying \(name)…"
        case .finished: return "Calibration complete"
        case .failed(let message): return message
        case .cancelled: return "Calibration cancelled"
        }
    }
}

private struct CalibrationResultsCard: View {
    @Environment(AppModel.self) private var model
    private var cal: CalibrationEngine { model.calibration }

    var body: some View {
        Card {
            Text(cal.phase == .finished ? "Calibration results" : "Calibration incomplete").font(.headline)
            Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = cal.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            } else if cal.phase == .cancelled {
                Text("Calibration was cancelled.").foregroundStyle(.secondary)
            }
            if let verification = cal.verification {
                HStack(alignment: .top, spacing: 28) {
                    if verification.arrivalMs.count >= 2 {
                        if verification.arrivalMs.count == cal.measurements.filter({ $0.latencyMs != nil }).count,
                           let before = cal.lastReport?.differenceBeforeMs {
                            CalibrationResultValue(title: "Before", value: formatMs(before))
                        }
                        CalibrationResultValue(title: "Remaining difference", value: formatMs(verification.remainingDifferenceMs, decimals: 2))
                    }
                    CalibrationResultValue(title: "Repeatability", value: formatMs(verification.repeatabilityMs, decimals: 2))
                }
                .padding(.vertical, 8)
                Text(verification.arrivalMs.count >= 2
                     ? "Measured at the microphone position during verification."
                     : "One speaker verified. A timing comparison needs at least two speakers.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Speaker measurements") {
                CalibrationMeasurementTable(measurements: cal.measurements)
                    .padding(.top, 12)
                if let room = cal.lastReport?.roomCorrection, !room.isEmpty {
                    Text("Room correction: " + room.map { String(format: "%.0f Hz %+.1f dB", $0.frequency, $0.gainDb) }.joined(separator: ", "))
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            if !cal.log.isEmpty {
                DisclosureGroup("Measurement log") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(cal.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
            }
        }
    }

    private var summary: String {
        if model.previousCalibrationRestored { return "Previous calibration restored. These results describe the latest measurement." }
        let measured = cal.measurements.filter { $0.latencyMs != nil }.count
        let total = cal.measurements.count
        if cal.phase != .finished { return "Calibration did not finish. \(measured) of \(total) speakers were measured. Check the measurement log before using these results." }
        if measured != total { return "Measured \(measured) of \(total) speakers. Open speaker measurements to review the outputs that could not be measured." }
        guard let verification = cal.verification else {
            return "Measured \(measured) of \(total) speakers. A second verification pass was not completed."
        }
        if verification.arrivalMs.count < 2 {
            return "Measured \(measured) of \(total) speakers. One speaker was verified."
        }
        return "Measured \(measured) of \(total) speakers. Verification compared \(verification.arrivalMs.count) speakers."
    }
}

private struct CalibrationResultValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CalibrationMeasurementTable: View {
    let measurements: [DeviceMeasurement]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    Text("Speaker")
                    Text("Arrival")
                    Text("Compensation")
                    Text("Repeatability")
                    Text("Level")
                    Text("Tone")
                    Text("Signal confidence")
                }
                .foregroundStyle(.secondary)
                ForEach(measurements) { measurement in
                    GridRow {
                        Text(measurement.name)
                        if let latency = measurement.latencyMs {
                            Text(formatMs(latency)).monospacedDigit()
                            Text(measurement.compensationMs.map { "+" + formatMs($0) } ?? "—").monospacedDigit()
                            Text(String(format: "±%.2f ms (%d/%d)", measurement.spreadMs / 2, measurement.accepted, measurement.samplesMs.count)).monospacedDigit()
                            Text(measurement.relativeLevelDb.map { String(format: "%+.1f dB", $0) } ?? "—").monospacedDigit()
                                .help("Loudness at the microphone relative to the loudest output, using the same test level")
                            Text(measurement.correction.isEmpty ? "—" : "\(measurement.correction.count) band\(measurement.correction.count == 1 ? "" : "s")")
                                .help(measurement.correction.map { String(format: "%@ %.0f Hz %+.1f dB", $0.type.displayName, $0.frequency, $0.gainDb) }.joined(separator: "\n"))
                            Text(measurement.confidence.rawValue.capitalized)
                        } else {
                            Text(measurement.failure ?? "Could not measure").gridCellColumns(6)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

// MARK: - Manual sync test

struct SyncTestView: View {
    @Environment(AppModel.self) private var model
    @State private var included: Set<String> = []
    @State private var muteMusic = true
    @State private var interval = 1.0

    private var engine: SyncEngine { model.engine }
    private var playing: [OutputState] { engine.outputs.filter { $0.status == .playing } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Sync Test",
                              subtitle: "Align outputs by ear. Every output plays the same click on the shared timeline; when the delays are right you hear a single, sharp click.")
                Card {
                    HStack(spacing: 14) {
                        if engine.syncClicksActive {
                            Button {
                                engine.stopSyncClicks()
                            } label: { Label("Stop Clicks", systemImage: "stop.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button {
                                engine.startSyncClicks(only: included.isEmpty ? nil : included, interval: interval, muteProgram: muteMusic)
                            } label: { Label("Play Clicks", systemImage: "metronome.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(playing.isEmpty)
                        }
                        Toggle("Mute music during test", isOn: $muteMusic)
                        Picker("Interval", selection: $interval) {
                            Text("0.5 s").tag(0.5)
                            Text("1 s").tag(1.0)
                            Text("2 s").tag(2.0)
                        }
                        .frame(width: 150)
                        Spacer()
                    }
                    Text("Tip: start with coarse steps (±10 ms) until the echo turns into a flam, then use ±1 and ±0.1 ms. Solo a device to hear it on its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(playing) { o in
                    Card {
                        HStack {
                            Toggle(isOn: Binding(get: { included.isEmpty || included.contains(o.uid) }, set: { on in
                                if included.isEmpty { included = Set(playing.map(\.uid)) }
                                if on { included.insert(o.uid) } else { included.remove(o.uid) }
                                if engine.syncClicksActive { engine.startSyncClicks(only: included, interval: interval, muteProgram: muteMusic) }
                            })) {
                                Label(o.name, systemImage: o.transport.symbol).font(.headline)
                            }
                            Spacer()
                            Button("Solo") {
                                included = [o.uid]
                                engine.startSyncClicks(only: included, interval: interval, muteProgram: muteMusic)
                            }
                            .controlSize(.small)
                        }
                        DelayControls(output: o)
                    }
                }
                if playing.isEmpty {
                    Text("Turn SyncForge on and enable at least two outputs.").foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .disabled(model.calibration.isRunning)
        }
        .onDisappear { if engine.syncClicksActive { engine.stopSyncClicks() } }
    }
}
