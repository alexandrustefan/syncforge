import AppKit
import CoreAudio
import Foundation
import Observation
import SyncForgeRT

public enum OutputStatus: Equatable, Sendable {
    case disabled
    case unavailable
    case starting
    case playing
    case error(String)

    public var label: String {
        switch self {
        case .disabled: return "Off"
        case .unavailable: return "Not connected"
        case .starting: return "Starting"
        case .playing: return "Playing"
        case .error(let m): return m
        }
    }
}

public enum CaptureStatus: Equatable, Sendable {
    case stopped
    case running(sampleRate: Double)
    case failed(String)
}

/// Live meters for one output, refreshed ~10x per second.
public struct OutputMeters: Equatable, Sendable {
    public var peakDb: Float = -120
    public var clipping = false
    public var limiting = false
    public var underruns: UInt64 = 0
    public var resyncs: UInt64 = 0
    public var servoErrorMs: Double = 0
    public var correctionPPM: Double = 0
    public var locked = false
    public init() {}
}

/// UI-facing state of an output (connected device and/or saved profile).
public struct OutputState: Identifiable, Equatable, Sendable {
    public var id: String { uid }
    public var uid: String
    public var device: AudioDeviceInfo?
    public var profile: DeviceProfile
    public var status: OutputStatus
    public var timing: OutputTiming?
    public var isDefaultOutput: Bool

    public var name: String { device?.name ?? profile.name }
    public var transport: TransportKind { device?.transport ?? profile.transport }
    public var isConnected: Bool { device?.isAlive ?? false }
}

public struct EngineEvent: Identifiable, Sendable {
    public enum Level: Sendable { case info, warning, error }
    public let id = UUID()
    public let date = Date()
    public let level: Level
    public let message: String
}

/// Coordinates capture, per-device renderers, timing, DSP parameters, device lifecycle and
/// persistence. All methods run on the main actor; nothing here touches audio samples.
@MainActor
@Observable
public final class SyncEngine {
    public let devices: AudioDeviceManager
    public let store: ProfileStore

    public private(set) var outputs: [OutputState] = []
    public private(set) var meters: [String: OutputMeters] = [:]
    /// Full-precision samples from the last monitoring tick, independent of UI visibility.
    /// Headless diagnostics must use these rather than the quantized, visibility-gated meters.
    @ObservationIgnored public private(set) var diagnostics: [String: SFRendererStats] = [:]
    public private(set) var captureStatus: CaptureStatus = .stopped
    public private(set) var captureLevelDb: Float = -120
    public private(set) var events: [EngineEvent] = []
    public private(set) var programMuted = false
    public private(set) var syncClicksActive = false
    /// Extra base latency added automatically after underruns.
    public private(set) var autoBaseExtraMs: Double = 0
    public private(set) var systemAudioPermission: SystemAudioPermission.Status = .unknown

    /// Number of visible UI surfaces showing live meters. Meters are only published while > 0, so a
    /// hidden menu bar panel doesn't keep SwiftUI re-rendering.
    @ObservationIgnored public var meteringClients = 0 {
        didSet { if meteringClients == 0 { meters.removeAll(); captureLevelDb = -120 } }
    }

    /// Capture level (dBFS), updated every tick regardless of UI visibility (not observed).
    @ObservationIgnored public private(set) var captureLevelDbRaw: Float = -120
    /// When an output's audio clock last jumped (dropped/repeated IO cycles), e.g. a Bluetooth glitch.
    @ObservationIgnored public private(set) var lastClockJump: Date?
    @ObservationIgnored private var clockJumpCache: [String: UInt64] = [:]
    @ObservationIgnored private var lastClockJumpLog: [String: Date] = [:]

    /// The shared program buffer (for Live Sync analysis).
    public var sourceRing: SourceRing? { ring }

    /// Called after an enabled output reconnects and is playing again.
    @ObservationIgnored public var onOutputReconnected: ((String) -> Void)?

    @ObservationIgnored private var capture: (any SystemAudioCapturing)?
    @ObservationIgnored private var ring: SourceRing?
    @ObservationIgnored private var renderers: [String: any AudioOutputRendering] = [:]
    @ObservationIgnored private let makeCapture: () -> any SystemAudioCapturing
    @ObservationIgnored private let makeRenderer: (AudioDeviceInfo, SourceRing) throws -> any AudioOutputRendering
    @ObservationIgnored private var callbackWatch: [String: (callbacks: UInt64, since: Date)] = [:]
    @ObservationIgnored private var lastUnderruns: [String: UInt64] = [:]
    @ObservationIgnored private var captureWatch: (callbacks: UInt64, since: Date) = (0, Date())
    @ObservationIgnored private var captureStartedAt = Date.distantPast
    @ObservationIgnored private var lastBaseBump = Date.distantPast
    @ObservationIgnored private var connected: Set<String> = []
    @ObservationIgnored private var pendingReconnects: Set<String> = []
    @ObservationIgnored private var reconcileWork: DispatchWorkItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var clickTargets: Set<String>?

    public convenience init() {
        self.init(devices: AudioDeviceManager(), store: ProfileStore())
    }

    public convenience init(devices: AudioDeviceManager, store: ProfileStore) {
        self.init(devices: devices, store: store, makeCapture: { SystemAudioCapture() },
                  makeRenderer: { try OutputRenderer(device: $0, ring: $1) })
    }

    init(devices: AudioDeviceManager, store: ProfileStore,
         makeCapture: @escaping () -> any SystemAudioCapturing,
         makeRenderer: @escaping (AudioDeviceInfo, SourceRing) throws -> any AudioOutputRendering) {
        self.devices = devices
        self.store = store
        self.makeCapture = makeCapture
        self.makeRenderer = makeRenderer
        devices.onEvent = { [weak self] event in self?.handle(event) }
        connected = Set(devices.outputDevices.filter(\.isAlive).map(\.uid))
        for d in devices.outputDevices { store.register(d) }
        systemAudioPermission = SystemAudioPermission.status()
        observeWorkspace()
        rebuildOutputs()
        if store.settings.engineEnabled { reconcile() }
    }

    // MARK: - Public control

    public var isEnabled: Bool { store.settings.engineEnabled }
    public var effectiveBaseLatencyMs: Double { store.settings.baseLatencyMs + autoBaseExtraMs }

    public func setEnabled(_ on: Bool) {
        guard on != store.settings.engineEnabled else { return }
        store.settings.engineEnabled = on
        log(on ? "Engine started" : "Engine stopped — normal macOS audio restored")
        reconcile()
    }

    public func updateProfile(_ uid: String, _ mutate: (inout DeviceProfile) -> Void) {
        let before = store.profile(uid: uid)
        store.update(uid, mutate)
        let after = store.profile(uid: uid)
        if before?.enabled != after?.enabled || before?.leftChannel != after?.leftChannel || before?.rightChannel != after?.rightChannel {
            reconcile()
        } else {
            applyAllParams()
            rebuildOutputs()
        }
    }

    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let before = store.settings
        mutate(&store.settings)
        let after = store.settings
        if before.maxDelayMs != after.maxDelayMs, ring != nil {
            // The ring must hold the longest delay: rebuild the audio graph.
            teardownAudio()
        }
        if before.baseLatencyMs != after.baseLatencyMs { autoBaseExtraMs = 0 }
        if before.engineEnabled != after.engineEnabled || before.maxDelayMs != after.maxDelayMs
            || before.showVirtualDevices != after.showVirtualDevices || before.showAggregateDevices != after.showAggregateDevices {
            reconcile()
        } else {
            applyAllParams()
            rebuildOutputs()
        }
    }

    /// Resets an output to automatic compensation with no trim.
    public func resetDelay(_ uid: String) {
        updateProfile(uid) {
            $0.delayMode = .automatic
            $0.trimMs = 0
        }
    }

    /// Forgets every measurement and everything derived from it (delays, corrections, level trims),
    /// keeping volumes, EQ choices and enabled outputs.
    public func resetCalibration() {
        for uid in store.profiles.keys {
            store.update(uid) {
                $0.calibration = nil
                $0.correction = []
                $0.levelTrimDb = 0
                $0.delayMode = .automatic
                $0.trimMs = 0
            }
        }
        store.settings.roomCorrection = []
        log("Calibration reset — all measurements, corrections and level trims cleared")
        applyAllParams()
        rebuildOutputs()
    }

    public func saveSetup(named name: String) {
        let profiles = store.profiles.values.sorted { $0.name < $1.name }
        store.setups.append(SavedSetup(name: name, masterVolume: store.settings.masterVolume, profiles: profiles))
        log("Saved setup “\(name)”")
    }

    public func applySetup(_ setup: SavedSetup) {
        for uid in store.profiles.keys { store.update(uid) { $0.enabled = false } }
        for p in setup.profiles { store.replace(p) }
        store.settings.masterVolume = setup.masterVolume
        log("Restored setup “\(setup.name)”")
        reconcile()
    }

    /// Stops all audio activity; normal macOS playback resumes. Call on app termination.
    public func shutdown() {
        teardownAudio()
        store.saveNow()
    }

    // MARK: - Calibration / sync-test support

    /// Suppresses program audio on every output (used while test signals play).
    public func setProgramMuted(_ muted: Bool) {
        guard muted != programMuted else { return }
        programMuted = muted
        applyAllParams()
    }

    public func renderer(for uid: String) -> (any AudioOutputRendering)? { renderers[uid] }
    public var activeOutputUIDs: [String] { Array(renderers.keys) }

    /// Total delay currently programmed into an output's renderer.
    public func totalDelaySeconds(_ uid: String) -> Double? {
        currentTimings()[uid].map { $0.totalDelayMs / 1000 }
    }

    /// Plays a repeating click through every active output (or the given subset), aligned on the
    /// program timeline, so delays can be compared and adjusted by ear.
    public func startSyncClicks(only uids: Set<String>? = nil, interval: Double = 1.0, muteProgram: Bool = true) {
        clickTargets = uids
        let start = UInt64(HostTime.now()) + UInt64(HostTime.ticks(0.2))
        for (uid, r) in renderers {
            if let only = uids, !only.contains(uid) {
                r.stopTestSignal()
                continue
            }
            r.playTestSignal(TestSignals.click(sampleRate: r.sampleRate), timelineStart: start, period: interval,
                             repeats: 0, gain: TestSignals.dbToGain(-14))
        }
        syncClicksActive = true
        if muteProgram { setProgramMuted(true) }
    }

    public func stopSyncClicks() {
        for r in renderers.values { r.stopTestSignal() }
        syncClicksActive = false
        clickTargets = nil
        setProgramMuted(false)
    }

    public func log(_ message: String, level: EngineEvent.Level = .info) {
        events.append(EngineEvent(level: level, message: message))
        if events.count > 200 { events.removeFirst(events.count - 200) }
        guard store.fileURL != nil else { return }  // in-memory stores (CLI, tests) don't write logs
        let tag = level == .info ? "INFO" : level == .warning ? "WARN" : "ERROR"
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(tag) \(message)\n"
        let url = SyncEngine.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }

    nonisolated public static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SyncForge/activity.log")
    }

    public func refreshPermissions() { systemAudioPermission = SystemAudioPermission.status() }

    // MARK: - Device events

    private func handle(_ event: DeviceEvent) {
        switch event {
        case .listChanged, .deviceChanged:
            detectReconnects()
            scheduleReconcile()
        case .deviceLatencyChanged(let uid):
            checkLatencyChange(uid)
            applyAllParams()
            rebuildOutputs()
        case .defaultOutputChanged:
            // The tap follows the system output; rebuild capture so its clock matches.
            if capture != nil {
                log("Default output changed — restarting capture")
                restartCapture()
            }
            applyAllParams()
            rebuildOutputs()
        case .defaultInputChanged:
            break
        case .defaultOutputVolumeChanged:
            applyAllParams()
        case .serviceRestarted:
            log("Core Audio service restarted — rebuilding", level: .warning)
            teardownAudio()
            scheduleReconcile(after: 1.0)
        }
    }

    private func detectReconnects() {
        let now = Set(devices.outputDevices.filter(\.isAlive).map(\.uid))
        let appeared = now.subtracting(connected)
        let vanished = connected.subtracting(now)
        connected = now
        for uid in vanished where store.profile(uid: uid)?.enabled == true {
            log("\(store.profile(uid: uid)?.name ?? uid) disconnected", level: .warning)
        }
        for uid in appeared {
            if let d = devices.outputDevice(uid: uid) { store.register(d) }
            guard let p = store.profile(uid: uid), p.enabled else { continue }
            pendingReconnects.insert(uid)
            log("\(p.name) reconnected — restoring its profile")
            if p.transport.isBluetooth, p.calibration != nil {
                store.update(uid) {
                    $0.calibration?.needsRecalibration = true
                    $0.calibration?.recalibrationReason = "Reconnected: Bluetooth latency can change between connections"
                }
            }
            checkLatencyChange(uid)
        }
    }

    private func checkLatencyChange(_ uid: String) {
        guard let d = devices.outputDevice(uid: uid), let cal = store.profile(uid: uid)?.calibration else { return }
        let delta = d.reportedOutputLatencyMs - cal.reportedLatencyMs
        if abs(delta) > 5 {
            store.update(uid) {
                $0.calibration?.needsRecalibration = true
                $0.calibration?.recalibrationReason = String(format: "Driver latency changed by %+.0f ms since calibration", delta)
            }
            log(String(format: "%@: reported latency changed by %+.0f ms — recalibration recommended", d.name, delta), level: .warning)
        }
    }

    private func scheduleReconcile(after delay: Double = 0.35) {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reconcile() } }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Graph management

    /// Brings capture and renderers in line with the desired configuration.
    public func reconcile() {
        reconcileWork?.cancel()
        reconcileWork = nil
        for d in devices.outputDevices { store.register(d) }

        let wanted: [AudioDeviceInfo] = (isEnabled && !suspended)
            ? store.profiles.values.filter(\.enabled).compactMap { p in devices.outputDevice(uid: p.uid).flatMap { $0.isAlive ? $0 : nil } }
            : []

        if wanted.isEmpty {
            teardownAudio()
            rebuildOutputs()
            return
        }

        do {
            try ensureCapture()
        } catch {
            captureStatus = .failed(String(describing: error))
            log("System audio capture failed: \(error)", level: .error)
            teardownAudio(keepStatus: true)
            rebuildOutputs()
            return
        }
        guard let ring else { return }

        let wantedByUID = Dictionary(uniqueKeysWithValues: wanted.map { ($0.uid, $0) })
        for (uid, r) in renderers {
            let d = wantedByUID[uid]
            if d == nil || d!.id != r.device.id || d!.nominalSampleRate != r.sampleRate
                || d!.outputChannels != r.device.outputChannels || r.ring !== ring {
                r.stop()
                renderers[uid] = nil
                callbackWatch[uid] = nil
            }
        }
        for d in wanted where renderers[d.uid] == nil {
            do {
                let r = try makeRenderer(d, ring)
                let reconnect = pendingReconnects.contains(d.uid)
                r.setParams(params(for: d.uid, renderer: r, fadeIn: reconnect ? store.settings.reconnectFadeInSeconds : 0.3))
                try r.start()
                renderers[d.uid] = r
                callbackWatch[d.uid] = (0, Date())
                lastUnderruns[d.uid] = 0
                if reconnect {
                    pendingReconnects.remove(d.uid)
                    let uid = d.uid
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        MainActor.assumeIsolated { self?.onOutputReconnected?(uid) }
                    }
                }
            } catch {
                log("Could not start \(d.name): \(error)", level: .error)
            }
        }
        guard !renderers.isEmpty else {
            // A tap mutes normal playback. Never retain it when every selected output failed.
            teardownAudio()
            captureStatus = .failed("No selected output could start. Normal macOS audio has been restored.")
            log("No outputs could start — capture stopped and normal macOS audio restored", level: .error)
            rebuildOutputs()
            return
        }
        if syncClicksActive { startSyncClicks(only: clickTargets, muteProgram: programMuted) }
        applyAllParams()
        rebuildOutputs()
        startTimer()
    }

    private func ensureCapture() throws {
        if capture?.isRunning == true, ring != nil { return }
        let cap = makeCapture()
        let format = try cap.prepareTap()
        let neededSeconds = (store.settings.maxDelayMs + 400) / 1000 + 2.0
        if ring == nil || ring!.sampleRate != format.mSampleRate || ring!.capacitySeconds < neededSeconds {
            // Renderers reference the ring; drop them before replacing it.
            for r in renderers.values { r.stop() }
            renderers.removeAll()
            guard let newRing = SourceRing(sampleRate: format.mSampleRate, seconds: neededSeconds) else {
                cap.stop()
                throw CoreAudioError(kAudioHardwareUnspecifiedError, "Allocate source buffer")
            }
            ring = newRing
        }
        try cap.start(ring: ring!)
        capture = cap
        captureStartedAt = Date()
        captureWatch = (0, Date())
        captureStatus = .running(sampleRate: format.mSampleRate)
        systemAudioPermission = SystemAudioPermission.status()
    }

    private func restartCapture() {
        capture?.stop()
        capture = nil
        scheduleReconcile(after: 0.1)
    }

    private func teardownAudio(keepStatus: Bool = false) {
        for r in renderers.values { r.stop() }
        renderers.removeAll()
        callbackWatch.removeAll()
        capture?.stop()
        capture = nil
        ring = nil
        if !keepStatus { captureStatus = .stopped }
        meters.removeAll()
        diagnostics.removeAll()
        stopTimer()
    }

    // MARK: - Parameters

    private func latency(for p: DeviceProfile, device: AudioDeviceInfo?, micOffsetMs: Double) -> (Double, LatencySource) {
        if let c = p.calibration, c.confidence != .failed { return (c.latencyMs, .measured) }
        // Measured latencies include the calibration microphone's own delay. Put driver estimates on
        // the same scale, or uncalibrated outputs would be off by that delay.
        return ((device?.reportedOutputLatencyMs ?? 0) + micOffsetMs, .driverEstimate)
    }

    /// The calibration microphone's own delay, estimated from calibrated *wired* outputs (whose
    /// driver-reported latency is trustworthy): median of (measured - reported). 0 if unknown.
    public var estimatedMicrophoneOffsetMs: Double {
        let latestMic = store.profiles.values.compactMap(\.calibration).max { $0.date < $1.date }?.microphoneUID
        let samples = store.profiles.values.compactMap { p -> Double? in
            guard let c = p.calibration, c.confidence != .failed, !p.transport.isWireless, c.microphoneUID == latestMic,
                  p.transport != .virtual, p.transport != .aggregate else { return nil }
            return c.latencyMs - c.reportedLatencyMs
        }
        return samples.isEmpty ? 0 : RobustStats.median(samples)
    }

    /// Timing for every enabled, connected output.
    public func currentTimings() -> [String: OutputTiming] {
        let micOffset = estimatedMicrophoneOffsetMs
        let inputs: [SyncMath.Input] = store.profiles.values.filter(\.enabled).compactMap { p in
            guard let d = devices.outputDevice(uid: p.uid), d.isAlive else { return nil }
            let (l, src) = latency(for: p, device: d, micOffsetMs: micOffset)
            return SyncMath.Input(uid: p.uid, latencyMs: l, source: src, mode: p.delayMode,
                                  manualDelayMs: p.manualDelayMs, trimMs: p.trimMs)
        }
        return SyncMath.timings(inputs, baseLatencyMs: effectiveBaseLatencyMs, maxDelayMs: store.settings.maxDelayMs)
    }

    private func gain(for p: DeviceProfile) -> Float {
        let s = store.settings
        if p.muted || s.masterMuted { return 0 }
        var g = SyncMath.sliderGain(p.volume) * SyncMath.sliderGain(s.masterVolume) * SyncMath.dbToLinear(p.levelTrimDb)
        if s.linkSystemVolume, p.uid != devices.defaultOutputUID, let sys = devices.defaultOutputGain {
            g *= devices.defaultOutputMuted ? 0 : sys
        }
        return Float(g)
    }

    func processingChain(for uid: String, sampleRate: Double) -> BiquadDesign.Chain {
        guard let profile = store.profile(uid: uid) else {
            return BiquadDesign.chain(system: nil, device: .flat, sampleRate: sampleRate)
        }
        let settings = store.settings
        return BiquadDesign.chain(system: profile.useSystemEQ ? settings.systemDSP : nil,
                                  device: profile.dsp, sampleRate: sampleRate,
                                  roomCorrection: profile.useSystemEQ && settings.roomCorrectionEnabled ? settings.roomCorrection : [],
                                  deviceCorrection: profile.correctionEnabled ? profile.correction : [])
    }

    func params(for uid: String, renderer r: any AudioOutputRendering, fadeIn: Double = 0.3, timings: [String: OutputTiming]? = nil) -> SFRendererParams {
        var p = SFRendererParams()
        sf_params_init(&p)
        let profile = store.profile(uid: uid) ?? DeviceProfile(uid: uid, name: r.device.name, transport: r.device.transport)
        let t = (timings ?? currentTimings())[uid]
        p.delaySeconds = (t?.totalDelayMs ?? effectiveBaseLatencyMs) / 1000
        p.gain = gain(for: profile)
        p.programMuted = programMuted ? 1 : 0
        p.fadeInSeconds = Float(fadeIn)

        // Channel routing.
        let channels = r.device.outputChannels
        if channels <= 1 {
            p.channelMode = Int32(SFChannelModeMono)
            p.outLeft = 0
            p.outRight = -1
        } else {
            let l = (profile.leftChannel ?? r.device.preferredStereo.0) - 1
            let rr = (profile.rightChannel ?? r.device.preferredStereo.1) - 1
            p.outLeft = Int32(min(max(l, 0), channels - 1))
            p.outRight = Int32(min(max(rr, 0), channels - 1))
            switch profile.channelMode {
            case .stereo: p.channelMode = Int32(SFChannelModeStereo)
            case .mono: p.channelMode = Int32(SFChannelModeMono)
            case .leftOnly: p.channelMode = Int32(SFChannelModeLeft)
            case .rightOnly: p.channelMode = Int32(SFChannelModeRight)
            case .swapped: p.channelMode = Int32(SFChannelModeSwap)
            }
        }

        // DSP.
        let dsp = profile.dsp
        let chain = processingChain(for: uid, sampleRate: r.sampleRate)
        p.dspEnabled = chain.isActive ? 1 : 0
        p.preampGain = Float(SyncMath.dbToLinear(chain.preampDb))
        p.numBiquads = Int32(chain.cascade.count)
        for (i, bq) in chain.cascade.enumerated() {
            sf_params_set_biquad(&p, Int32(i), bq.b0, bq.b1, bq.b2, bq.a1, bq.a2)
        }
        p.limiterEnabled = dsp.limiterEnabled ? 1 : 0
        p.limiterCeiling = Float(SyncMath.dbToLinear(min(0, dsp.limiterCeilingDb)))
        return p
    }

    private func applyAllParams() {
        let timings = currentTimings()
        for (uid, r) in renderers {
            r.setParams(params(for: uid, renderer: r, timings: timings))
        }
    }

    // MARK: - UI state

    private func rebuildOutputs() {
        let timings = currentTimings()
        let s = store.settings
        var list: [OutputState] = []
        var seen = Set<String>()
        for d in devices.outputDevices {
            let p = store.profile(for: d)
            let hidden = (d.transport == .virtual && !s.showVirtualDevices) || (d.transport == .aggregate && !s.showAggregateDevices)
            if hidden && !p.enabled { continue }
            seen.insert(d.uid)
            let status: OutputStatus
            if !p.enabled { status = .disabled }
            else if !isEnabled { status = .disabled }
            else if !d.isAlive { status = .unavailable }
            else if let r = renderers[d.uid] { status = r.isRunning ? .playing : .starting }
            else if case .failed(let m) = captureStatus { status = .error(m) }
            else { status = .error("Could not start") }
            list.append(OutputState(uid: d.uid, device: d, profile: p, status: status, timing: timings[d.uid],
                                    isDefaultOutput: d.uid == devices.defaultOutputUID))
        }
        for p in store.profiles.values.sorted(by: { $0.name < $1.name }) where p.enabled && !seen.contains(p.uid) {
            list.append(OutputState(uid: p.uid, device: nil, profile: p, status: .unavailable, timing: nil, isDefaultOutput: false))
        }
        if list != outputs { outputs = list }
    }

    // MARK: - Monitoring

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let now = Date()
        let capturePeak = ring?.stats(resetPeak: false).peak ?? 0
        let timings = currentTimings()
        var newMeters: [String: OutputMeters] = [:]
        var newDiagnostics: [String: SFRendererStats] = [:]
        var underrunSeen = false
        var restart: [String] = []
        for (uid, r) in renderers {
            r.collectRetiredSignals()
            let s = r.stats(resetPeaks: true)
            newDiagnostics[uid] = s
            var m = OutputMeters()
            // Quantized so that unchanged readings don't trigger UI updates.
            m.peakDb = max(-60, (20 * log10(max(max(s.peakLeft, s.peakRight), 1e-6))).rounded())
            if s.clippedFrames > (clippedCache[uid] ?? s.clippedFrames) { clipHold[uid] = now.addingTimeInterval(1) }
            if s.limitedFrames > (limitedCache[uid] ?? s.limitedFrames) { limitHold[uid] = now.addingTimeInterval(1) }
            clippedCache[uid] = s.clippedFrames
            limitedCache[uid] = s.limitedFrames
            m.clipping = (clipHold[uid] ?? .distantPast) > now
            m.limiting = (limitHold[uid] ?? .distantPast) > now
            m.underruns = s.underruns
            m.resyncs = s.resyncs
            m.servoErrorMs = (s.servoErrorSeconds * 1e5).rounded() / 100
            m.correctionPPM = s.correctionPPM.rounded()
            m.locked = s.locked != 0
            newMeters[uid] = m
            // Watchdog: program audio is playing, this output is unmuted, yet it has been silent.
            if !programMuted, !syncClicksActive, capturePeak > 0.003, let p = store.profile(uid: uid), gain(for: p) > 0.001,
               max(s.peakLeft, s.peakRight) < 1e-5 {
                let since = silentSince[uid] ?? now
                silentSince[uid] = since
                // Allow for the output's own delay: it plays audio captured that long ago.
                if now.timeIntervalSince(since) > 4 + (timings[uid]?.totalDelayMs ?? 0) / 1000 {
                    log("\(r.device.name) stayed silent while audio was playing (underruns \(s.underruns), overruns \(s.overruns), resyncs \(s.resyncs)) — rebuilding it", level: .warning)
                    silentSince[uid] = nil
                    restart.append(uid)
                }
            } else {
                silentSince[uid] = nil
            }
            if let prevJumps = clockJumpCache[uid], s.clockJumps > prevJumps {
                lastClockJump = now
                if now.timeIntervalSince(lastClockJumpLog[uid] ?? .distantPast) > 5 {
                    lastClockJumpLog[uid] = now
                    log(String(format: "%@ audio clock jumped by %+.1f ms (%llu so far)", r.device.name, s.lastClockJumpSeconds * 1000, s.clockJumps),
                        level: .warning)
                }
            }
            clockJumpCache[uid] = s.clockJumps
            if s.underruns > (lastUnderruns[uid] ?? 0) { underrunSeen = true }
            lastUnderruns[uid] = s.underruns

            // Stall detection: a running device whose IOProc stopped being called.
            if let w = callbackWatch[uid] {
                if s.callbacks != w.callbacks { callbackWatch[uid] = (s.callbacks, now) }
                else if now.timeIntervalSince(w.since) > 3, !restart.contains(uid) {
                    log("\(r.device.name) stopped responding — restarting it", level: .warning)
                    restart.append(uid)
                }
            }
        }
        diagnostics = newDiagnostics
        if meteringClients > 0, newMeters != meters { meters = newMeters }

        if let ring {
            let cs = ring.stats(resetPeak: true)
            let level = max(-60, (20 * log10(max(cs.peak, 1e-6))).rounded())
            captureLevelDbRaw = max(captureLevelDbRaw - 3, level)   // ~1 s peak hold
            if meteringClients > 0, level != captureLevelDb { captureLevelDb = level }
            if cs.callbacks != captureWatch.callbacks { captureWatch = (cs.callbacks, now) }
            else if now.timeIntervalSince(captureWatch.since) > 3, capture != nil {
                log("System audio capture stalled — restarting", level: .warning)
                captureWatch = (cs.callbacks, now)
                restartCapture()
            }
        }

        // Automatic base latency: underruns mean the shared buffer is too small for these devices.
        if underrunSeen, store.settings.autoBaseLatency, now.timeIntervalSince(captureStartedAt) > 2,
           now.timeIntervalSince(lastBaseBump) > 2, autoBaseExtraMs < 150 {
            autoBaseExtraMs += 10
            lastBaseBump = now
            log(String(format: "Buffer underrun — base latency raised to %.0f ms", effectiveBaseLatencyMs), level: .warning)
            applyAllParams()
            rebuildOutputs()
        }

        for uid in restart {
            renderers[uid]?.stop()
            renderers[uid] = nil
            callbackWatch[uid] = nil
        }
        if !restart.isEmpty { scheduleReconcile(after: 0.2) }
    }

    @ObservationIgnored private var clippedCache: [String: UInt64] = [:]
    @ObservationIgnored private var limitedCache: [String: UInt64] = [:]
    @ObservationIgnored private var clipHold: [String: Date] = [:]
    @ObservationIgnored private var silentSince: [String: Date] = [:]
    @ObservationIgnored private var limitHold: [String: Date] = [:]

    // MARK: - Sleep / wake

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspended = true
                if self.ring != nil { self.log("System going to sleep — audio engine paused") }
                self.teardownAudio()
                self.rebuildOutputs()
            }
        })
        workspaceObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.suspended = false
                self.devices.refresh()
                self.connected = Set(self.devices.outputDevices.filter(\.isAlive).map(\.uid))
                self.scheduleReconcile(after: 1.5)
            }
        })
    }
}
