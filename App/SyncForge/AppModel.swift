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
    private var restoredCalibration: CalibrationSnapshot?
    private(set) var textEditingRevision = 0
    private var previousCalibration: CalibrationSnapshot?
    @ObservationIgnored private var calibrationTask: Task<Void, Never>?
    @ObservationIgnored private var editingObservers: [NSObjectProtocol] = []

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
        observeTextEditing()
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
        guard calibrationTask == nil, !calibration.isRunning else { return }
        restoredCalibration = nil
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
        let previous = engine.captureCalibrationSnapshot()
        calibrationTask = Task {
            defer { calibrationTask = nil }
            let ok = (try? await calibration.run(outputs: outputs, microphoneUID: mic)) != nil
            // Verification can fail after measurements have been applied. Keep a way back whenever
            // calibration changed the sound, including a cancelled or partially successful run.
            if engine.captureCalibrationSnapshot() != previous { previousCalibration = previous }
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

    var canRestorePreviousCalibration: Bool {
        previousCalibration != nil && calibrationTask == nil && !calibration.isRunning
    }

    var previousCalibrationRestored: Bool {
        restoredCalibration.map { $0 == engine.captureCalibrationSnapshot() } ?? false
    }

    func restorePreviousCalibration() {
        guard canRestorePreviousCalibration, let previousCalibration else { return }
        liveSync.stop()
        engine.performUndoableChange(named: "Restore Previous Calibration") {
            engine.restoreCalibrationSnapshot(previousCalibration)
        }
        self.previousCalibration = nil
        restoredCalibration = engine.captureCalibrationSnapshot()
        if settings.liveSyncEnabled { liveSync.start(microphoneUID: microphoneUID) }
    }

    func startOver() {
        guard calibrationTask == nil, !calibration.isRunning else { return }
        restoredCalibration = nil
        liveSync.stop()
        let previous = engine.captureCalibrationSnapshot()
        engine.performUndoableChange(named: "Reset Calibration") { engine.resetCalibration() }
        calibration.clearResults()
        if engine.captureCalibrationSnapshot() != previous { previousCalibration = previous }
        if settings.liveSyncEnabled { liveSync.start(microphoneUID: microphoneUID) }
    }

    func retryAudio() {
        guard calibrationTask == nil, !calibration.isRunning else { return }
        liveSync.stop()
        engine.refreshPermissions()
        engine.setEnabled(false)
        engine.setEnabled(true)
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
        engine.performUndoableChange(named: "Change Master Volume") {
            engine.updateSettings { $0.masterVolume = min(1, max(0, $0.masterVolume + delta)) }
        }
    }

    func toggleMasterMute() {
        engine.performUndoableChange(named: "Change Master Mute") {
            engine.updateSettings { $0.masterMuted.toggle() }
        }
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

    /// AppKit field editors own text undo independently of the audio model. Refresh command
    /// validation when their focus or history changes, even when no audio setting changed.
    private func observeTextEditing() {
        let notifications: [Notification.Name] = [
            NSControl.textDidBeginEditingNotification, NSControl.textDidChangeNotification,
            NSControl.textDidEndEditingNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, .NSUndoManagerDidCloseUndoGroup,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange
        ]
        for name in notifications {
            editingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Focus and undo-group notifications can precede the final responder update.
                DispatchQueue.main.async { self?.textEditingRevision &+= 1 }
            })
        }
    }
}

// MARK: - Bindings into the engine

extension SyncEngine {
    func profileBinding<T>(_ uid: String, _ keyPath: WritableKeyPath<DeviceProfile, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { self.store.profile(uid: uid)?[keyPath: keyPath] ?? fallback },
            set: { value in
                self.performUndoableChange(named: Self.profileEditName(keyPath)) {
                    self.updateProfile(uid) { $0[keyPath: keyPath] = value }
                }
            }
        )
    }

    func settingsBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store.settings[keyPath: keyPath] },
            set: { value in
                self.performUndoableChange(named: Self.settingsEditName(keyPath)) {
                    self.updateSettings { $0[keyPath: keyPath] = value }
                }
            }
        )
    }

    var enabledBinding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.setEnabled($0) })
    }

    private static func profileEditName<T>(_ keyPath: WritableKeyPath<DeviceProfile, T>) -> String {
        switch keyPath as PartialKeyPath<DeviceProfile> {
        case \DeviceProfile.volume: return "Change Speaker Volume"
        case \DeviceProfile.muted: return "Change Speaker Mute"
        case \DeviceProfile.enabled: return "Change Output Selection"
        case \DeviceProfile.delayMode, \DeviceProfile.manualDelayMs, \DeviceProfile.trimMs: return "Adjust Delay"
        case \DeviceProfile.channelMode: return "Change Channels"
        case \DeviceProfile.useSystemEQ, \DeviceProfile.correctionEnabled: return "Change Speaker EQ"
        default: return "Change Speaker Settings"
        }
    }

    private static func settingsEditName<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> String {
        switch keyPath as PartialKeyPath<AppSettings> {
        case \AppSettings.masterVolume: return "Change Master Volume"
        case \AppSettings.masterMuted: return "Change Master Mute"
        case \AppSettings.baseLatencyMs, \AppSettings.maxDelayMs: return "Change Buffer Latency"
        case \AppSettings.roomCorrectionEnabled: return "Change Room Correction"
        default: return "Change Settings"
        }
    }
}
