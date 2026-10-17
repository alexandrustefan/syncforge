import SwiftUI
import SyncForgeCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var setupName = ""

    private var engine: SyncEngine { model.engine }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Start SyncForge at login", isOn: Binding(get: { engine.store.settings.launchAtLogin },
                                                                  set: { model.setLaunchAtLogin($0) }))
                if let e = model.loginItemError { Text(e).font(.caption).foregroundStyle(.red) }
                Toggle("macOS volume controls all outputs", isOn: engine.settingsBinding(\.linkSystemVolume))
                Text("The volume keys change the macOS default output's volume. With this on, SyncForge applies the same volume to every other output, so all speakers follow the keys together.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show virtual devices", isOn: engine.settingsBinding(\.showVirtualDevices))
                Toggle("Show aggregate / Multi-Output devices", isOn: engine.settingsBinding(\.showAggregateDevices))
                Text("Multi-Output devices duplicate audio themselves; select the physical outputs in SyncForge instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Synchronization") {
                LabeledContent("Base latency") {
                    HStack {
                        Slider(value: engine.settingsBinding(\.baseLatencyMs), in: 20...200, step: 5).frame(width: 200)
                        Text(String(format: "%.0f ms", engine.store.settings.baseLatencyMs)).monospacedDigit().frame(width: 56)
                    }
                }
                Toggle("Raise automatically after buffer underruns", isOn: engine.settingsBinding(\.autoBaseLatency))
                if engine.autoBaseExtraMs > 0 {
                    Text(String(format: "Currently raised by %.0f ms this session.", engine.autoBaseExtraMs)).font(.caption).foregroundStyle(.orange)
                }
                Text("A small common buffer that every output shares. It absorbs differences in device IO cycles and never affects synchronization between outputs.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Maximum delay") {
                    Picker("", selection: engine.settingsBinding(\.maxDelayMs)) {
                        Text("1 s").tag(1000.0)
                        Text("3 s").tag(3000.0)
                        Text("5 s").tag(5000.0)
                        Text("10 s").tag(10000.0)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                LabeledContent("Reconnect fade-in") {
                    HStack {
                        Slider(value: engine.settingsBinding(\.reconnectFadeInSeconds), in: 0.2...5).frame(width: 200)
                        Text(String(format: "%.1f s", engine.store.settings.reconnectFadeInSeconds)).monospacedDigit()
                    }
                }
            }

            Section("Calibration") {
                Toggle("Verify after calibrating", isOn: engine.settingsBinding(\.verifyAfterCalibration))
                Stepper("Repetitions per output: \(engine.store.settings.calibrationRepetitions)",
                        value: engine.settingsBinding(\.calibrationRepetitions), in: 3...9)
                Toggle("Recalibrate automatically when a Bluetooth output reconnects", isOn: engine.settingsBinding(\.autoRecalibrateOnReconnect))
                Text("Uses the selected calibration microphone for a few seconds after the device reconnects (only if microphone access was granted). The menu bar icon shows a microphone while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Setups") {
                HStack {
                    TextField("Name for the current setup", text: $setupName)
                    Button("Save Current Setup") {
                        engine.saveSetup(named: setupName.isEmpty ? "Setup \(engine.store.setups.count + 1)" : setupName)
                        setupName = ""
                    }
                }
                ForEach(engine.store.setups) { setup in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(setup.name)
                            Text("\(setup.profiles.filter(\.enabled).map(\.name).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") { engine.applySetup(setup) }
                        Button(role: .destructive) {
                            engine.store.setups.removeAll { $0.id == setup.id }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Permissions & Privacy") {
                LabeledContent("System Audio Recording") {
                    HStack {
                        Text(permissionText(engine.systemAudioPermission))
                        Button("Open Settings") { NSWorkspace.shared.open(SystemAudioPermission.settingsURL) }.controlSize(.small)
                    }
                }
                LabeledContent("Microphone") {
                    HStack {
                        Text(micText)
                        Button("Open Settings") { NSWorkspace.shared.open(MicrophonePermission.settingsURL) }.controlSize(.small)
                    }
                }
                Text("SyncForge processes audio locally and never sends anything over the network. It has no telemetry. The microphone is used during calibration and while optional Live Sync is active. Its audio is analysed in memory and never saved. If SyncForge quits or crashes, macOS removes its audio tap and normal playback resumes on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Activity") {
                if engine.events.isEmpty { Text("No events yet.").foregroundStyle(.secondary) }
                ForEach(engine.events.suffix(40).reversed()) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: e.level == .info ? "info.circle" : "exclamationmark.triangle")
                            .foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .secondary)
                        Text(e.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(e.message).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { engine.refreshPermissions() }
    }

    private func permissionText(_ s: SystemAudioPermission.Status) -> String {
        switch s {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .unknown: return "Asked when SyncForge first starts"
        }
    }

    private var micText: String {
        switch MicrophonePermission.status() {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Asked before the first calibration"
        }
    }
}
