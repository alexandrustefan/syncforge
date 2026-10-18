import CoreAudio
import XCTest
@testable import SyncForgeCore
import SyncForgeRT

@MainActor
final class ConfigurationQoLTests: XCTestCase {
    func testLegacySetupDecodesWithoutDiscardingSavedMix() throws {
        let data = Data("""
        {"id":"6482D230-1ED4-4872-B124-3D0FC7F5DFB9","name":"Desk","created":"2025-01-02T03:04:05Z",
         "masterVolume":0.65,"profiles":[{"uid":"wired","enabled":true}]}
        """.utf8)
        let saved = try JSONDecoder.syncForge.decode(SavedSetup.self, from: data)
        XCTAssertNil(saved.settings)
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.updateSettings { $0.systemDSP.preampDb = -7; $0.masterMuted = true }
        engine.applySetup(saved)
        XCTAssertEqual(engine.store.settings.masterVolume, 0.65)
        XCTAssertEqual(engine.store.settings.systemDSP.preampDb, -7)
        XCTAssertTrue(engine.store.settings.masterMuted)
        XCTAssertTrue(engine.store.profile(uid: "wired")?.enabled == true)
    }

    func testSetupRecallsSoundTimingAndCorrectionsWithoutLifecycleOrPrivacyChanges() throws {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.updateSettings {
            $0.masterVolume = 0.45; $0.masterMuted = true; $0.linkSystemVolume = false
            $0.baseLatencyMs = 77; $0.autoBaseLatency = false; $0.maxDelayMs = 1900
            $0.reconnectFadeInSeconds = 4; $0.systemDSP.preampDb = -9
            $0.roomCorrection = [.init(frequency: 150, gainDb: -4)]
            $0.roomCorrectionEnabled = false
            $0.liveSyncEnabled = true; $0.calibrationMicrophoneUID = "old-mic"; $0.launchAtLogin = true
        }
        engine.updateProfile("wired") { $0.trimMs = 8; $0.muted = true; $0.correction = [.init(frequency: 500, gainDb: -2)] }
        let saved = engine.saveSetup(named: "Desk")
        engine.updateSettings { $0 = AppSettings() }
        engine.updateProfile("wired") { $0.trimMs = 0; $0.muted = false; $0.correction = [] }
        XCTAssertTrue(engine.isSelectedSetupModified)
        engine.applySetup(saved)
        XCTAssertEqual(engine.selectedSetupID, saved.id)
        XCTAssertFalse(engine.isSelectedSetupModified)
        let restored = engine.store.settings
        XCTAssertEqual(restored.playbackSettings, try XCTUnwrap(saved.settings).playbackSettings)
        XCTAssertFalse(restored.engineEnabled)
        XCTAssertFalse(restored.liveSyncEnabled)
        XCTAssertFalse(restored.launchAtLogin)
        XCTAssertNil(restored.calibrationMicrophoneUID)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.trimMs, 8)
        XCTAssertTrue(engine.store.profile(uid: "wired")?.muted == true)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.correction.count, 1)
        engine.updateSettings { $0.masterVolume = 0.8 }
        XCTAssertTrue(engine.updateSetup(saved.id))
        XCTAssertEqual(engine.store.setups.count, 1)
        XCTAssertEqual(engine.selectedSetup?.id, saved.id)
        XCTAssertEqual(engine.selectedSetup?.created, saved.created)
        XCTAssertEqual(engine.selectedSetup?.masterVolume, 0.8)
        XCTAssertFalse(engine.isSelectedSetupModified)
    }

    func testSelectedSetupPersistsAndOldStateStillDecodes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProfileStore(fileURL: file)
        let setup = SavedSetup(name: "Desk", created: Date(timeIntervalSince1970: 1700000000), masterVolume: 0.7, profiles: [], settings: AppSettings())
        store.setups = [setup]
        store.selectedSetupID = setup.id
        store.saveNow()
        let restored = ProfileStore(fileURL: file)
        XCTAssertEqual(restored.selectedSetupID, setup.id)
        XCTAssertEqual(restored.setups, [setup])
        let old = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertNil(old.selectedSetupID)
    }

    func testSoloOnlyMutesOtherProgramPathsAndPreservesMix() throws {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.updateProfile("other") { $0.muted = true }
        let original = engine.store.profiles
        engine.setEnabled(true)
        let wired = try XCTUnwrap(engine.renderer(for: "wired"))
        let other = try XCTUnwrap(engine.renderer(for: "other"))
        engine.toggleSolo("wired")
        XCTAssertEqual(engine.soloOutputUID, "wired")
        XCTAssertEqual(engine.params(for: "wired", renderer: wired).programMuted, 0)
        XCTAssertEqual(engine.params(for: "other", renderer: other).programMuted, 1)
        XCTAssertEqual(engine.store.profiles, original)
        engine.startSyncClicks()
        XCTAssertEqual(engine.params(for: "wired", renderer: wired).programMuted, 1)
        XCTAssertTrue((other as? QoLOutput)?.testSignals == 1, "Solo must not suppress calibration/test signals")
        engine.stopSyncClicks()
        XCTAssertEqual(engine.params(for: "wired", renderer: wired).programMuted, 0)
        engine.toggleSolo("wired")
        XCTAssertNil(engine.soloOutputUID)
        XCTAssertEqual(engine.params(for: "other", renderer: other).programMuted, 0)
        XCTAssertEqual(engine.params(for: "other", renderer: other).gain, 0, "Stored mute stays honored")
        XCTAssertEqual(engine.store.profiles, original)
        engine.toggleSolo("wired")
        engine.updateProfile("wired") { $0.enabled = false }
        XCTAssertNil(engine.soloOutputUID)
        XCTAssertEqual(engine.params(for: "other", renderer: other).programMuted, 0)
        engine.toggleSolo("other")
        engine.setEnabled(false)
        XCTAssertNil(engine.soloOutputUID)
        engine.setSoloOutput("other")
        XCTAssertNil(engine.soloOutputUID, "Solo cannot latch while engine is off")
    }

    func testSoloFailureRestoresOtherOutputsAndShutdownClearsSolo() {
        let engine = makeEngine(failingUID: "wired")
        defer { engine.shutdown() }
        engine.setEnabled(true)
        engine.setSoloOutput("wired")
        XCTAssertNil(engine.soloOutputUID, "A failed output cannot temporarily silence the working mix")
        engine.reconcile()
        XCTAssertNil(engine.soloOutputUID)
        XCTAssertEqual(Set(engine.activeOutputUIDs), ["other"])
        engine.setSoloOutput("other")
        engine.shutdown()
        XCTAssertNil(engine.soloOutputUID)
    }

    func testUndoGroupsSliderAndPreservesLaterAutomaticChangesAndNewDevices() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.beginUndoableChange(named: "Output Volume")
        engine.performUndoableChange(named: "Output Volume") { engine.updateProfile("wired") { $0.volume = 0.7 } }
        engine.performUndoableChange(named: "Output Volume") { engine.updateProfile("wired") { $0.volume = 0.4 } }
        engine.endUndoableChange()
        XCTAssertTrue(engine.canUndo)
        XCTAssertEqual(engine.undoActionName, "Output Volume")
        engine.updateProfile("wired") { $0.trimMs = 11; $0.calibration = record(latency: 22) }
        engine.updateSettings { $0.baseLatencyMs = 99; $0.liveSyncEnabled = true; $0.launchAtLogin = true; $0.calibrationMicrophoneUID = "new-mic" }
        engine.store.replace(DeviceProfile(uid: "newly-discovered", name: "New", transport: .usb))
        engine.undo()
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 1)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.trimMs, 11)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.calibration?.latencyMs, 22)
        XCTAssertNotNil(engine.store.profile(uid: "newly-discovered"))
        XCTAssertEqual(engine.store.settings.baseLatencyMs, 99)
        XCTAssertTrue(engine.store.settings.liveSyncEnabled)
        XCTAssertTrue(engine.store.settings.launchAtLogin)
        XCTAssertEqual(engine.store.settings.calibrationMicrophoneUID, "new-mic")
        XCTAssertFalse(engine.canUndo)
        XCTAssertTrue(engine.canRedo)
        XCTAssertEqual(engine.redoActionName, "Output Volume")
        engine.redo()
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 0.4)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.calibration?.latencyMs, 22)
        XCTAssertNotNil(engine.store.profile(uid: "newly-discovered"))
    }

    func testGroupedUndoExcludesBackgroundChangesBetweenSliderUpdates() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.beginUndoableChange(named: "Output Volume")
        engine.performUndoableChange(named: "Output Volume") { engine.updateProfile("wired") { $0.volume = 0.7 } }
        // Simulate automatic main-actor work after a run-loop yield during the drag.
        engine.updateProfile("wired") { $0.trimMs = 13; $0.calibration = record(latency: 24) }
        engine.updateSettings { $0.baseLatencyMs = 103; $0.roomCorrectionEnabled = false }
        engine.store.replace(DeviceProfile(uid: "discovered-during-drag", name: "New", transport: .usb))
        engine.performUndoableChange(named: "Output Volume") { engine.updateProfile("wired") { $0.volume = 0.4 } }
        engine.endUndoableChange()

        engine.undo()
        XCTAssertFalse(engine.canUndo, "The entire drag should be one undo action")
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 1)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.trimMs, 13)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.calibration?.latencyMs, 24)
        XCTAssertNotNil(engine.store.profile(uid: "discovered-during-drag"))
        XCTAssertEqual(engine.store.settings.baseLatencyMs, 103)
        XCTAssertFalse(engine.store.settings.roomCorrectionEnabled)
        engine.redo()
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 0.4)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.trimMs, 13)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.calibration?.latencyMs, 24)
        XCTAssertNotNil(engine.store.profile(uid: "discovered-during-drag"))
    }

    func testEmptyEditGroupAndNestedWrappersDoNotCreateExtraUndoActions() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.beginUndoableChange(named: "No Edit")
        engine.updateProfile("wired") { $0.trimMs = 17 }
        engine.endUndoableChange()
        XCTAssertFalse(engine.canUndo, "An automatic update during an empty edit is not a user action")
        engine.performUndoableChange(named: "Volume") {
            engine.performUndoableChange(named: "Nested") { engine.updateProfile("wired") { $0.volume = 0.6 } }
        }
        engine.undo()
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 1)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.trimMs, 17)
        XCTAssertFalse(engine.canUndo)
    }

    func testSettingsUndoOnlyRestoresChangedFieldAndNoOpHasNoHistory() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.performUndoableChange(named: "No-op") { engine.updateSettings { $0.masterVolume = 1 } }
        XCTAssertFalse(engine.canUndo)
        engine.performUndoableChange(named: "Master Volume") { engine.updateSettings { $0.masterVolume = 0.5 } }
        engine.updateSettings { $0.roomCorrectionEnabled = false; $0.systemDSP.preampDb = -8 }
        engine.undo()
        XCTAssertEqual(engine.store.settings.masterVolume, 1)
        XCTAssertFalse(engine.store.settings.roomCorrectionEnabled)
        XCTAssertEqual(engine.store.settings.systemDSP.preampDb, -8)
        engine.redo()
        XCTAssertEqual(engine.store.settings.masterVolume, 0.5)
    }

    func testCalibrationBackupRestoresDerivedFieldsButPreservesVolumeAndUserEQ() {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.updateProfile("wired") { $0.calibration = record(latency: 30); $0.trimMs = 4; $0.levelTrimDb = -3 }
        engine.updateSettings { $0.roomCorrection = [.init(frequency: 100, gainDb: -5)] }
        let original = engine.captureCalibrationSnapshot()
        engine.resetCalibration()
        engine.updateProfile("wired") { $0.volume = 0.3; $0.dsp.preampDb = -6 }
        XCTAssertNotEqual(engine.captureCalibrationSnapshot(), original)
        engine.performUndoableChange(named: "Restore Previous Calibration") { engine.restoreCalibrationSnapshot(original) }
        XCTAssertEqual(engine.captureCalibrationSnapshot(), original)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 0.3)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.dsp.preampDb, -6)
        engine.undo()
        XCTAssertNil(engine.store.profile(uid: "wired")?.calibration)
        XCTAssertEqual(engine.store.profile(uid: "wired")?.volume, 0.3)
    }

    func testCalibrationStopsExistingSyncClicksBeforePreflightFailure() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        engine.setEnabled(true)
        engine.startSyncClicks()
        XCTAssertTrue(engine.syncClicksActive)
        let calibration = CalibrationEngine(engine: engine)
        do {
            _ = try await calibration.run()
            XCTFail("Mock catalog has no microphone")
        } catch {
            guard case CalibrationError.noMicrophone = error else { return XCTFail("Unexpected failure: \(error)") }
        }
        XCTAssertFalse(engine.syncClicksActive)
        XCTAssertFalse(engine.programMuted)
    }

    func testFailedCalibrationAndStartOverClearSessionPresentation() async {
        let engine = makeEngine()
        defer { engine.shutdown() }
        let calibration = CalibrationEngine(engine: engine)
        do {
            _ = try await calibration.run()
            XCTFail("Engine-off run should fail before opening hardware")
        } catch {
            XCTAssertTrue(error is CalibrationError)
        }
        guard case .failed = calibration.phase else { return XCTFail("Failure should remain visible") }
        XCTAssertFalse(calibration.log.isEmpty)
        XCTAssertNil(calibration.lastReport)
        calibration.clearResults()
        XCTAssertEqual(calibration.phase, .idle)
        XCTAssertEqual(calibration.progress, 0)
        XCTAssertTrue(calibration.measurements.isEmpty)
        XCTAssertNil(calibration.verification)
        XCTAssertNil(calibration.lastReport)
        XCTAssertTrue(calibration.log.isEmpty)
        XCTAssertEqual(calibration.speakerCount, 0)
        XCTAssertNil(calibration.currentSpeakerIndex)
    }

    private func record(latency: Double) -> CalibrationRecord {
        CalibrationRecord(latencyMs: latency, spreadMs: 1, peakToNoiseDb: 30, confidence: .high,
                          repetitions: 5, date: Date(), microphoneUID: "mic", reportedLatencyMs: 10)
    }

    private func makeEngine(failingUID: String? = nil) -> SyncEngine {
        let devices = [device("wired", id: 1), device("other", id: 2)]
        let store = ProfileStore(fileURL: nil)
        for device in devices { store.register(device); store.update(device.uid) { $0.enabled = true } }
        return SyncEngine(devices: AudioDeviceManager(snapshot: devices), store: store,
                          makeCapture: { QoLCapture() }, makeRenderer: { device, ring in
            if device.uid == failingUID { throw QoLFault.output }
            return QoLOutput(device: device, ring: ring)
        })
    }

    private func device(_ uid: String, id: UInt32) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, uid: uid, name: uid, manufacturer: "Test", transport: .builtIn,
                        outputChannels: 2, inputChannels: 0, nominalSampleRate: 48000,
                        reportedOutputLatency: 0.01, reportedInputLatency: 0, outputSafetyOffset: 0,
                        bufferFrameSize: 512, maxBufferFrameSize: 8192, isAlive: true,
                        preferredStereo: (1, 2), outputFormatIsFloat: true, dataSourceName: nil)
    }
}

private enum QoLFault: Error { case output }
private final class QoLCapture: SystemAudioCapturing {
    var isRunning = false
    func prepareTap() throws -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8,
                                    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 32, mReserved: 0)
    }
    func start(ring: SourceRing) throws { isRunning = true }
    func stop() { isRunning = false }
}
private final class QoLOutput: AudioOutputRendering {
    let device: AudioDeviceInfo
    let ring: SourceRing
    var sampleRate: Double { device.nominalSampleRate }
    var isRunning = false
    var testSignals = 0
    init(device: AudioDeviceInfo, ring: SourceRing) { self.device = device; self.ring = ring }
    func start() throws { isRunning = true }
    func stop() { isRunning = false }
    func setParams(_ params: SFRendererParams) {}
    func playTestSignal(_ samples: [Float], timelineStart: UInt64, period: Double, repeats: UInt32, gain: Float) -> UInt32 { testSignals += 1; return 1 }
    func stopTestSignal() {}
    func collectRetiredSignals() {}
    func stats(resetPeaks: Bool) -> SFRendererStats { SFRendererStats() }
}
