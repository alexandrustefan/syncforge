import SwiftUI
import SyncForgeCore

struct CalibrationView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: Set<String> = []
    @State private var micPermission = MicrophonePermission.status()
    @State private var confirmReset = false
    @State private var progressAnchorDate: Date?
    @State private var progressAnchorValue = 0.0

    private var engine: SyncEngine { model.engine }
    private var cal: CalibrationEngine { model.calibration }

    private var playing: [OutputState] { engine.outputs.filter { $0.status == .playing } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Calibration",
                              subtitle: "Measure the real acoustic delay of every output with a microphone, then delay the faster ones so everything arrives together.")
                steps
                setup
                liveSyncCard
                progressCard
                if !cal.measurements.isEmpty { results }
                howItWorks
            }
            .padding(20)
        }
        .onAppear {
            micPermission = MicrophonePermission.status()
            if selected.isEmpty { selected = Set(playing.map(\.uid)) }
            if cal.isRunning { beginProgressEstimate() }
        }
        .onChange(of: cal.isRunning) { _, running in
            if running { beginProgressEstimate() }
            else { progressAnchorDate = nil }
        }
        .onChange(of: playing.map(\.uid)) { _, uids in selected.formIntersection(uids); if selected.isEmpty { selected = Set(uids) } }
    }

    // MARK: Setup

    private var micBinding: Binding<String> {
        Binding(get: { model.microphoneUID ?? "" }, set: { model.setMicrophone($0) })
    }

    private var selectedMic: AudioDeviceInfo? { engine.devices.inputDevice(uid: micBinding.wrappedValue) }

    private var setup: some View {
        Card {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Microphone").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: micBinding) {
                            ForEach(engine.devices.inputDevices.filter { $0.transport != .virtual }) { d in
                                Text(d.name + (d.transport.isBluetooth ? " — Bluetooth (not recommended)" : "")).tag(d.uid)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        if let mic = selectedMic {
                            if mic.transport.isBluetooth {
                                Text("Bluetooth microphones switch audio to the hands-free profile, which changes the speaker's codec and latency. Use the built-in or a USB microphone.")
                                    .font(.caption).foregroundStyle(.red)
                            } else if mic.transport == .continuity {
                                Text("Good choice for accuracy: put the iPhone exactly where your head is (screen up, not in a pocket). Its wireless delay is the same for every speaker and is cancelled by interleaved measurement.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if mic.transport == .builtIn {
                                Text("Tip: an iPhone (Continuity Camera microphone) can be placed exactly at your listening position.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if micPermission == .denied {
                            HStack {
                                Text("Microphone access is denied.").font(.caption).foregroundStyle(.red)
                                Button("Open Privacy Settings") { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }.controlSize(.small)
                            }
                        } else if micPermission == .notDetermined {
                            Text("macOS will ask for microphone access when calibration or Live Sync starts. Audio is analysed in memory; nothing is recorded to disk or sent anywhere.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                GridRow {
                    Text("Outputs").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        if playing.isEmpty {
                            Text("Turn SyncForge on and enable the outputs you want to align.").foregroundStyle(.secondary)
                        }
                        ForEach(playing) { o in
                            Toggle(isOn: Binding(get: { selected.contains(o.uid) },
                                                 set: { if $0 { selected.insert(o.uid) } else { selected.remove(o.uid) } })) {
                                Label(o.name, systemImage: o.transport.symbol)
                            }
                        }
                    }
                }
                GridRow {
                    Text("Test level").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: engine.settingsBinding(\.calibrationLevelDb), in: -36 ... -6).frame(width: 200)
                        Text(String(format: "%.0f dBFS", engine.store.settings.calibrationLevelDb)).monospacedDigit()
                        Text("Raised automatically if a speaker is not heard.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Levels").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Correct tone automatically (auto-EQ)", isOn: engine.settingsBinding(\.autoEQAfterCalibration))
                        Text("Matches the speakers' tone to each other and cuts room bass resonances, with gentle corrections you can switch off in Equalizer. Treble above ~5 kHz can't be judged with the MacBook mic; an iPhone covers more.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Match speaker levels at the microphone", isOn: engine.settingsBinding(\.matchLevelsAfterCalibration))
                        Text("Makes every speaker equally loud at your seat: quieter ones get up to +6 dB (the limiter prevents clipping), louder ones are turned down.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Search range").foregroundStyle(.secondary)
                    HStack {
                        Slider(value: engine.settingsBinding(\.calibrationMaxLatencyMs), in: 500...4000, step: 100).frame(width: 200)
                        Text(String(format: "up to %.0f ms", engine.store.settings.calibrationMaxLatencyMs)).monospacedDigit()
                    }
                }
            }
            .disabled(cal.isRunning)
            Divider()
            HStack {
                Text("Place the microphone at your listening position and keep the room quiet. Each speaker plays a few short sweeps in turn.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if cal.isRunning {
                    Button("Cancel", role: .cancel) { model.cancelCalibration() }
                } else {
                    Button {
                        micPermission = MicrophonePermission.status()
                        model.calibrate(outputs: Array(selected))
                    } label: {
                        Label("Start Calibration", systemImage: "waveform.badge.mic")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || !engine.isEnabled || selectedMic == nil || selectedMic?.transport.isBluetooth == true)
                }
            }
        }
    }

    // MARK: Steps

    private var steps: some View {
        let mic = selectedMic
        let wireless = playing.first { $0.transport.isWireless }
        let cal = (wireless ?? playing.first)?.profile.calibration
        let calibratedWithThisMic = cal != nil && cal?.microphoneUID == mic?.uid
        return Card {
            HStack(alignment: .top, spacing: 18) {
                step(1, "Microphone", mic.map { "\($0.name) — place it where you sit" } ?? "Choose one below", done: mic != nil)
                step(2, "Calibrate", cal.map { "Done " + RelativeDateTimeFormatter().localizedString(for: $0.date, relativeTo: Date())
                    + (calibratedWithThisMic ? "" : " (with another mic)") } ?? "Not yet", done: calibratedWithThisMic)
                step(3, "Live Sync", model.settings.liveSyncEnabled ? model.liveSyncStatus : "Off — turns on after calibrating",
                     done: model.liveSync.state == .monitoring)
                Spacer(minLength: 0)
                Button("Start Over…") { confirmReset = true }
                    .disabled(model.calibration.isRunning)
                    .help("Forget all measurements, delays, corrections and level trims")
            }
            if model.canRestorePreviousCalibration {
                Divider()
                HStack {
                    Text("Return to the calibration settings from before the last change.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Previous Calibration") { model.restorePreviousCalibration() }
                        .help("Restore timing, speaker corrections, level trims and room correction")
                }
            } else if model.previousCalibrationRestored {
                Text("Previous calibration restored.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Start over?", isPresented: $confirmReset) {
            Button("Forget All Calibrations", role: .destructive) { model.startOver() }
        } message: {
            Text("All measured latencies, compensation, tone corrections, room corrections and level trims are cleared. Volumes, EQ presets and selected outputs are kept.")
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, done: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(width: 22, height: 22)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                else { Text("\(n)").font(.caption.bold()) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 230, alignment: .leading)
    }

    // MARK: Live Sync

    private var liveSyncCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Live Sync").font(.headline)
                        if model.liveSync.micInUse { Label("Microphone in use", systemImage: "mic.fill").font(.caption).foregroundStyle(.orange) }
                    }
                    Text("Bluetooth speakers change their own delay over time (yours moved by up to 170 ms within minutes). Live Sync listens to the music with the calibration microphone every few seconds and follows those changes. No test sounds, no muting.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Needs: one calibration with this microphone, at least one wired output and one wireless output, music playing. The microphone stays open while it runs; audio is analysed in memory and never stored.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Turn on automatically after calibrating", isOn: engine.settingsBinding(\.liveSyncAfterCalibration))
                        .font(.callout)
                        .disabled(cal.isRunning)
                    if model.settings.liveSyncEnabled {
                        Text("Listening with: \(selectedMic?.name ?? "—") (the calibration microphone)").font(.caption).foregroundStyle(.secondary)
                        Text("Status: \(model.liveSyncStatus)\(model.liveSync.corrections > 0 ? " · \(model.liveSync.corrections) correction(s) this session" : "")")
                            .font(.callout)
                    }
                }
                Spacer()
                Toggle("", isOn: model.liveSyncBinding).toggleStyle(.switch).labelsHidden()
                    .disabled(cal.isRunning)
            }
        }
    }

    // MARK: Progress

    @ViewBuilder private var progressCard: some View {
        if cal.phase != .idle {
            Card {
                HStack(spacing: 12) {
                    if cal.micInUse {
                        Label("Microphone in use", systemImage: "mic.fill").foregroundStyle(.orange)
                        LevelMeter(db: cal.micLevelDb).frame(width: 120)
                    }
                    Text(phaseText).font(.callout)
                    Spacer()
                }
                if cal.isRunning {
                    ProgressView(value: cal.progress)
                    HStack {
                        if let index = cal.currentSpeakerIndex, cal.speakerCount > 0 {
                            Text("Speaker \(index) of \(cal.speakerCount)")
                        } else if cal.speakerCount > 0 {
                            Text("\(cal.speakerCount) speaker\(cal.speakerCount == 1 ? "" : "s") in this calibration")
                        }
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(remainingTimeText(at: context.date))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !cal.log.isEmpty {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(cal.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
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
        if rounded >= 60 {
            return "About \(Int(ceil(Double(rounded) / 60))) min left · varies with retries"
        }
        return "About \(rounded) sec left · varies with retries"
    }

    private var phaseText: String {
        switch cal.phase {
        case .idle: return ""
        case .preparing: return "Preparing…"
        case .listening: return "Measuring background noise…"
        case .measuring(let n): return "Measuring \(n)…"
        case .applying: return "Applying compensation…"
        case .verifying(let n): return "Verifying \(n) with compensation applied…"
        case .finished: return "Calibration complete."
        case .failed(let m): return m
        case .cancelled: return "Calibration cancelled."
        }
    }

    // MARK: Results

    private var results: some View {
        Card {
            HStack {
                Text("Results").font(.headline)
                Spacer()
            }
            Text(resultSummary).font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Device").bold()
                        Text("Measured arrival").bold()
                        Text("Compensation").bold()
                        Text("Repeatability").bold()
                        Text("Level").bold()
                        Text("Tone").bold()
                        Text("Signal confidence").bold()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ForEach(cal.measurements) { m in
                        GridRow {
                            Text(m.name)
                            if let l = m.latencyMs {
                                Text(formatMs(l)).monospacedDigit()
                                Text(m.compensationMs.map { "+" + formatMs($0) } ?? "—").monospacedDigit()
                                Text(String(format: "±%.2f ms (%d/%d)", m.spreadMs / 2, m.accepted, m.samplesMs.count)).monospacedDigit()
                                Text(m.relativeLevelDb.map { String(format: "%+.1f dB", $0) } ?? "—").monospacedDigit()
                                    .help("Loudness at the microphone relative to the loudest output (same input level)")
                                Text(m.correction.isEmpty ? "—" : "\(m.correction.count) band\(m.correction.count == 1 ? "" : "s")")
                                    .help(m.correction.map { String(format: "%@ %.0f Hz %+.1f dB", $0.type.displayName, $0.frequency, $0.gainDb) }.joined(separator: "\n"))
                                confidence(m.confidence)
                            } else {
                                Text(m.failure ?? "Failed").foregroundStyle(.red).gridCellColumns(6)
                            }
                        }
                    }
                }
            }
            if let room = cal.lastReport?.roomCorrection, !room.isEmpty {
                Text("Room resonances cut in the system EQ: " + room.map { String(format: "%.0f Hz %+.1f dB", $0.frequency, $0.gainDb) }.joined(separator: ", "))
                    .font(.callout)
            }
            if let v = cal.verification {
                Divider()
                HStack(spacing: 24) {
                    if let before = cal.lastReport?.differenceBeforeMs {
                        VStack(alignment: .leading) {
                            Text("Before").font(.caption).foregroundStyle(.secondary)
                            Text(formatMs(before)).font(.title3.monospacedDigit())
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Estimated remaining difference").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f ms", v.remainingDifferenceMs)).font(.title3.monospacedDigit())
                            .foregroundStyle(v.remainingDifferenceMs <= 2 ? .green : v.remainingDifferenceMs <= 5 ? .orange : .red)
                    }
                    VStack(alignment: .leading) {
                        Text("Measurement repeatability").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f ms", v.repeatabilityMs)).font(.title3.monospacedDigit())
                    }
                }
                Text("Verification re-measures every output with the new compensation in place, using the same microphone. It reflects the timing at the microphone position.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var resultSummary: String {
        if model.previousCalibrationRestored {
            return "Previous calibration restored. Results below are from the latest measurement."
        }
        let measured = cal.measurements.filter { $0.latencyMs != nil }.count
        let total = cal.measurements.count
        if cal.isRunning { return "Measured \(measured) of \(total) speakers so far. Results are still being collected." }
        if cal.phase == .finished {
            if measured == total {
                return cal.verification == nil
                    ? "Measured \(measured) of \(total) speakers. Timing was not verified in a second pass."
                    : "Measured \(measured) of \(total) speakers. Verification below shows the remaining timing difference at the microphone."
            }
            return "Measured \(measured) of \(total) speakers. Review the failed measurements below before relying on this calibration."
        }
        return "Calibration did not finish. Measured \(measured) of \(total) speakers; review the details before using these results."
    }

    private func confidence(_ c: MeasurementConfidence) -> some View {
        let color: Color = c == .high ? .green : c == .medium ? .yellow : c == .low ? .orange : .red
        return StatusPill(text: c.rawValue.capitalized, color: color)
    }

    private var howItWorks: some View {
        DisclosureGroup("How calibration works") {
            Text("""
            SyncForge first finds each output with one sweep, then plays sweeps on all outputs in turn (interleaved), timed so that they arrive at the microphone evenly spaced. Each output is measured relative to a reference output at the same moment, which cancels slow changes in the microphone's own delay (important for wireless microphones such as an iPhone). The sweep goes through the same delay line, resampler and EQ as your music. The microphone recording is matched against the sweep with a phase-transform cross-correlation, which is robust to room noise and to differences between speakers; the earliest strong arrival is used so desk and wall reflections are ignored. Several repetitions are combined with outlier rejection, and the spread between them is shown as repeatability.

            Both the scheduled playback time and the microphone samples are measured on the Mac's host clock, so the result is the real acoustic delay of each output (including Bluetooth buffering), not what its driver reports. The slowest output gets no extra delay; every other output waits for it.

            Recordings stay in memory only during calibration and are discarded afterwards.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
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
