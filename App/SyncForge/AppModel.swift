import AppKit
import Observation
import ServiceManagement
import SwiftUI
import SyncForgeCore

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case outputs, equalizer, calibration, syncTest, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .outputs: return "Outputs"
        case .equalizer: return "Equalizer"
        case .calibration: return "Calibration"
        case .syncTest: return "Sync Test"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .outputs: return "hifispeaker.2"
        case .equalizer: return "slider.vertical.3"
        case .calibration: return "waveform.badge.mic"
        case .syncTest: return "metronome"
        case .settings: return "gearshape"
        }
    }
}

/// Application-level state shared by the menu bar extra and the main window.
@MainActor
@Observable
final class AppModel {
    let engine: SyncEngine
    let calibration: CalibrationEngine
    let liveSync: LiveSync
    var section: AppSection = .outputs
    var equalizerUID: String?
    var loginItemError: String?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?

    init() {
        engine = SyncEngine()
        calibration = CalibrationEngine(engine: engine)
        liveSync = LiveSync(engine: engine)
        // Always start when switched on: Live Sync asks for microphone permission itself and reports
        // any problem in its status instead of silently staying off.
        if engine.store.settings.liveSyncEnabled {
            liveSync.start(microphoneUID: engine.store.settings.calibrationMicrophoneUID)
        }
        engine.onOutputReconnected = { [weak self] uid in self?.outputReconnected(uid) }
        syncLoginItemState()
    }

    var settings: AppSettings { engine.store.settings }

    // MARK: Actions

    /// The single measurement microphone, used by calibration and Live Sync.
    var microphoneUID: String? { settings.calibrationMicrophoneUID ?? engine.devices.recommendedMicrophone?.uid }

    func setMicrophone(_ uid: String) {
        engine.updateSettings { $0.calibrationMicrophoneUID = uid }
        if settings.liveSyncEnabled { liveSync.start(microphoneUID: uid) }
    }

    func calibrate(outputs: [String]? = nil) {
        guard !calibration.isRunning else { return }
        let s = settings
        calibration.options.levelDb = s.calibrationLevelDb
        calibration.options.maxLatency = s.calibrationMaxLatencyMs / 1000
        calibration.options.repetitions = s.calibrationRepetitions
        calibration.options.verify = s.verifyAfterCalibration
        calibration.options.matchLevels = s.matchLevelsAfterCalibration
        calibration.options.autoEQ = s.autoEQAfterCalibration
        let mic = microphoneUID
        if s.calibrationMicrophoneUID == nil, let mic { engine.updateSettings { $0.calibrationMicrophoneUID = mic } }
        liveSync.stop()
        calibrationTask = Task {
            let ok = (try? await calibration.run(outputs: outputs, microphoneUID: mic)) != nil
            // After a good calibration Live Sync starts fresh (it keeps a wireless output in sync).
            let hasPair = engine.outputs.contains { $0.status == .playing && $0.transport.isWireless }
                && engine.outputs.contains { $0.status == .playing && !$0.transport.isWireless }
            if ok && hasPair && settings.liveSyncAfterCalibration {
                setLiveSync(true)
            } else if settings.liveSyncEnabled {
                liveSync.start(microphoneUID: mic)
            }
        }
    }

    func cancelCalibration() { calibrationTask?.cancel() }

    func startOver() {
        liveSync.stop()
        engine.resetCalibration()
        if settings.liveSyncEnabled { liveSync.start(microphoneUID: microphoneUID) }
    }

    func setLiveSync(_ on: Bool) {
        engine.updateSettings { $0.liveSyncEnabled = on }
        if on { liveSync.start(microphoneUID: microphoneUID) } else { liveSync.stop() }
    }

    var liveSyncBinding: Binding<Bool> {
        Binding(get: { self.settings.liveSyncEnabled }, set: { self.setLiveSync($0) })
    }

    var liveSyncStatus: String {
        switch liveSync.state {
        case .off: return "Off"
        case .waiting(let why): return why
        case .failed(let why): return why
        case .monitoring:
            var text = "Listening"
            if let o = liveSync.lastOffsetMs { text += String(format: " · drift %+.1f ms", o) }
            if let c = liveSync.lastCorrection {
                text += " · corrected " + RelativeDateTimeFormatter().localizedString(for: c.date, relativeTo: Date())
            }
            return text
        }
    }

    func nudgeMasterVolume(_ delta: Double) {
        engine.updateSettings { $0.masterVolume = min(1, max(0, $0.masterVolume + delta)) }
    }

    func toggleMasterMute() {
        engine.updateSettings { $0.masterMuted.toggle() }
    }

    func openEqualizer(for uid: String) {
        equalizerUID = uid
        section = .equalizer
    }

    /// Bluetooth latency can change after reconnecting. If the user opted in (and microphone access
    /// was granted earlier), re-measure only that output; otherwise the UI shows a recommendation.
    private func outputReconnected(_ uid: String) {
        guard settings.autoRecalibrateOnReconnect, !calibration.isRunning,
              MicrophonePermission.status() == .authorized,
              engine.store.profile(uid: uid)?.calibration?.needsRecalibration == true else { return }
        engine.log("Recalibrating \(engine.store.profile(uid: uid)?.name ?? uid) after reconnection")
        calibrate(outputs: [uid])
    }

    // MARK: Login item

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "Could not change the login item: \(error.localizedDescription). Move SyncForge to the Applications folder and try again."
        }
        syncLoginItemState()
    }

    private func syncLoginItemState() {
        let enabled = SMAppService.mainApp.status == .enabled
        if settings.launchAtLogin != enabled { engine.updateSettings { $0.launchAtLogin = enabled } }
    }
}

// MARK: - Bindings into the engine

extension SyncEngine {
    func profileBinding<T>(_ uid: String, _ keyPath: WritableKeyPath<DeviceProfile, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { self.store.profile(uid: uid)?[keyPath: keyPath] ?? fallback },
            set: { value in self.updateProfile(uid) { $0[keyPath: keyPath] = value } }
        )
    }

    func settingsBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store.settings[keyPath: keyPath] },
            set: { value in self.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.setEnabled($0) })
    }
}
