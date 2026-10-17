import Foundation
import Observation

/// Finds candidate acoustic arrival offsets using the music itself.
///
/// The microphone hears every output playing the same program, each delayed by its total delay plus
/// its acoustic latency. Separate correlation peaks can reveal drift, but room reflections and
/// correlated program material can produce similar peaks. A missing second peak does not prove alignment.
public enum LiveSyncAnalyzer {
    public struct Offset: Sendable, Equatable {
        public var seconds: Double        // arrival offset relative to the expected arrival (+ = late)
        public var relativeDb: Double
        public var peakToNoiseDb: Double
    }

    /// - Parameters:
    ///   - mic: microphone recording.
    ///   - program: program audio starting `search` seconds before the expected arrival of `mic[0]`
    ///     and `mic.count / fs + 2 * search` seconds long.
    public static func offsets(mic: [Float], program: [Float], sampleRate fs: Double, search: Double) -> [Offset] {
        var options = LatencyEstimator.Options()
        options.bandLow = 150
        options.bandHigh = 5000
        options.phatBeta = 1.0   // full whitening: music is far from white
        guard let env = LatencyEstimator.envelope(recording: program, reference: mic, sampleRate: fs, options: options) else { return [] }
        return LatencyEstimator.peaks(env, separation: Int(0.003 * fs), floorDb: -12, maxCount: 4).map {
            Offset(seconds: search - $0.lag / fs, relativeDb: $0.relativeDb, peakToNoiseDb: $0.peakToNoiseDb)
        }
    }

    /// How strongly the program resembles itself shifted by each lag in `lags` (dB relative to lag 0,
    /// whitened). Rhythmic music correlates with itself at beat subdivisions, which could otherwise be
    /// mistaken for a second, drifted output.
    public static func selfSimilarityDb(program: [Float], sampleRate fs: Double, lags: [Double]) -> [Double] {
        let shift = Int(0.4 * fs)
        guard program.count > 2 * shift + Int(fs) else { return lags.map { _ in -100 } }
        let centre = Array(program[shift..<(program.count - shift)])
        var options = LatencyEstimator.Options()
        options.bandLow = 150
        options.bandHigh = 5000
        options.phatBeta = 0.3   // mild whitening: a repeating signal's energy sits on spectral lines
        guard let env = LatencyEstimator.envelope(recording: program, reference: centre, sampleRate: fs, options: options),
              shift < env.count else { return lags.map { _ in -100 } }
        let zero = Double(env[shift])
        return lags.map { lag in
            let k = shift - Int((lag * fs).rounded())
            let lo = max(0, k - Int(0.001 * fs)), hi = min(env.count - 1, k + Int(0.001 * fs))
            guard lo <= hi, zero > 0 else { return -100 }
            return 20 * log10(Double(env[lo...hi].max()!) / zero)
        }
    }

    public struct Assessment: Sendable, Equatable {
        /// Offset of the wired group (should be ~0).
        public var referenceOffset: Double
        /// Candidate wireless offset relative to the wired group (nil: no separate path resolved).
        public var wirelessOffset: Double?
    }

    /// Interprets the peaks for one group of stable (wired) outputs plus one wireless output.
    /// Returns nil if the wired group can't be identified.
    /// Offsets in `ignored` (relative to the wired group, seconds) are known reflections and skipped.
    public static func assess(_ peaks: [Offset], ignored: [Double] = [], referenceTolerance: Double = 0.008,
                              minPeakToNoiseDb: Double = 9) -> Assessment? {
        let strong = peaks.filter { $0.peakToNoiseDb >= minPeakToNoiseDb }
        guard let ref = strong.min(by: { abs($0.seconds) < abs($1.seconds) }), abs(ref.seconds) <= referenceTolerance else { return nil }
        let other = strong.filter { p in
            let rel = p.seconds - ref.seconds
            return p != ref && abs(rel) >= 0.0025 && !ignored.contains { abs($0 - rel) < 0.0012 }
        }
            .max { $0.relativeDb < $1.relativeDb }
        return Assessment(referenceOffset: ref.seconds, wirelessOffset: other.map { $0.seconds - ref.seconds })
    }
}

/// Opt-in continuous synchronisation. While music plays, records a few seconds from the
/// microphone every few seconds, and corrects the latency of a wireless output that drifted.
///
/// Privacy: the microphone stays open while Live Sync is on (macOS shows its indicator and so does
/// SyncForge). Audio is analysed in memory and discarded; nothing is stored or sent.
@MainActor
@Observable
public final class LiveSync {
    public enum State: Equatable, Sendable {
        case off
        case waiting(String)
        case monitoring
        case failed(String)
    }

    public private(set) var state: State = .off {
        didSet {
            guard state != lastLoggedState else { return }
            lastLoggedState = state
            switch state {
            case .waiting(let why): engine.log("Live Sync waiting: \(why)")
            case .failed(let why): engine.log("Live Sync stopped: \(why)", level: .warning)
            case .monitoring: engine.log("Live Sync monitoring")
            case .off: break
            }
        }
    }
    public private(set) var lastCheck: Date?
    public private(set) var lastOffsetMs: Double?
    public private(set) var corrections = 0
    public private(set) var lastCorrection: (date: Date, ms: Double)?

    /// Idle time between complete, nonoverlapping recording windows. Analysis adds no playback delay.
    public var interval: Double = 0.5
    public var window: Double = 3
    public var search: Double = 0.35

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recorder: MicrophoneRecorder?
    @ObservationIgnored private let analysisWorker = LiveSyncAnalysisWorker()
    @ObservationIgnored private var confirmation = LiveSyncConfirmation()
    @ObservationIgnored private var evidenceContext: LiveSyncPlaybackContext?
    @ObservationIgnored private var unconfirmed: LiveSyncPendingCorrection?
    /// Secondary peaks proven not to be the wireless output (reflections), relative offsets in s.
    @ObservationIgnored private var ignored: [Double] = []
    @ObservationIgnored private var stats = (checks: 0, unclear: 0, rhythmic: 0, offsets: [Double](), since: Date())
    /// Wired-group peak tolerance: wider for wireless microphones, whose own delay wobbles.
    @ObservationIgnored private var referenceTolerance = 0.008
    @ObservationIgnored private var lastLoggedState: State = .off

    public init(engine: SyncEngine) {
        self.engine = engine
    }

    public var isOn: Bool { state != .off }
    /// True while the microphone is open (observed, for the UI indicator).
    public private(set) var micInUse = false

    public func start(microphoneUID: String?) {
        stop()
        stats = (0, 0, 0, [], Date())
        state = .waiting("Starting…")
        task = Task { [weak self] in await self?.run(microphoneUID: microphoneUID) }
    }

    public func stop() {
        task?.cancel()
        task = nil
        recorder?.stop()
        recorder = nil
        micInUse = false
        confirmation.reset()
        evidenceContext = nil
        unconfirmed = nil
        ignored = []
        state = .off
    }

    private func run(microphoneUID: String?) async {
        let permitted = await MicrophonePermission.request()
        guard !Task.isCancelled else { return }
        guard permitted else {
            state = .failed("Microphone access is denied.")
            return
        }
        let uid = microphoneUID ?? engine.store.settings.calibrationMicrophoneUID
        guard let mic = uid.flatMap({ engine.devices.inputDevice(uid: $0) }) ?? engine.devices.recommendedMicrophone,
              !mic.transport.isBluetooth else {
            state = .failed("No suitable microphone (Bluetooth microphones are not used).")
            return
        }
        referenceTolerance = mic.transport == .continuity || mic.transport.isWireless ? 0.02 : 0.008
        engine.log("Live Sync started with “\(mic.name)”")
        var lastJumpCheck = Date.distantPast
        while !Task.isCancelled {
            // Only keep the microphone open while SyncForge is actually playing.
            if !engine.isEnabled || engine.activeOutputUIDs.isEmpty {
                if recorder != nil {
                    recorder?.stop()
                    recorder = nil
                    micInUse = false
                }
                state = .waiting("SyncForge is off")
                confirmation.reset()
            } else if recorder == nil {
                do {
                    let capacity = (window.isFinite ? max(3, min(window, 10)) : 3) + 2
                    let r = try MicrophoneRecorder(device: mic, capacitySeconds: capacity)
                    try r.start()
                    recorder = r
                    micInUse = true
                } catch {
                    state = .failed("Could not open \(mic.name): \(error)")
                    return
                }
            }
            // Check sooner after a Bluetooth clock jump (that's when latency tends to change).
            let jumped = engine.lastClockJump.map { $0 > lastJumpCheck } ?? false
            // Bound the cadence even if a caller supplies zero/invalid timing values.
            let pause = interval.isFinite ? max(0.5, min(interval, 60)) : 0.5
            try? await Task.sleep(nanoseconds: UInt64((jumped ? min(1.5, pause) : pause) * 1e9))
            if Task.isCancelled { break }
            if jumped { lastJumpCheck = Date() }
            if recorder != nil { await check(micUID: mic.uid) }
        }
    }

    private func check(micUID: String) async {
        var keptEvidence = false
        defer { if !keptEvidence && !Task.isCancelled { confirmation.reset() } }
        guard let recorder else { return }
        guard engine.isEnabled, !engine.programMuted, !engine.syncClicksActive else {
            state = .waiting("Paused while test signals play")
            return
        }
        let active = engine.activeOutputUIDs.compactMap { uid in engine.renderer(for: uid).map { (uid, $0.device) } }
        let wired = active.filter { !$0.1.transport.isWireless }
        let wireless = active.filter { $0.1.transport.isWireless }
        guard !wired.isEmpty, wireless.count == 1 else {
            state = .waiting(wireless.isEmpty ? "No wireless output to follow" : "Live Sync follows one wireless output at a time")
            return
        }
        guard let wl = wireless.first, let cal = engine.store.profile(uid: wl.0)?.calibration else {
            state = .waiting("Calibrate first")
            return
        }
        guard cal.microphoneUID == micUID else {
            let used = engine.devices.inputDevice(uid: cal.microphoneUID)?.name ?? "another microphone"
            state = .waiting("Calibrated with \(used) — recalibrate with this microphone")
            return
        }
        guard engine.captureLevelDbRaw > -45 else {
            state = .waiting("Waiting for music")
            return
        }
        state = .monitoring
        let activeUIDs = Set(active.map(\.0))
        let profiles = Dictionary(uniqueKeysWithValues: activeUIDs.map { ($0, engine.store.profile(uid: $0)) })
        let settings = engine.store.settings
        let context = LiveSyncPlaybackContext(profiles: profiles, settings: settings)
        if evidenceContext != context { confirmation.reset() }
        evidenceContext = context
        if let previous = unconfirmed, previous.expectedContext != context { unconfirmed = nil }
        let measurementWindow = window.isFinite ? max(3, min(window, 10)) : 3
        let measurementSearch = search.isFinite ? max(0.01, min(search, 1)) : 0.35

        // Record a window.
        recorder.setArmed(false)
        recorder.reset()
        recorder.setArmed(true)
        do {
            try await Task.sleep(nanoseconds: UInt64((measurementWindow + 0.15) * 1e9))
        } catch {
            recorder.setArmed(false)
            return
        }
        recorder.setArmed(false)
        guard !Task.isCancelled, engine.isEnabled, !engine.programMuted, !engine.syncClicksActive else { return }
        let tl = recorder.timeline()
        let n = min(recorder.frameCount, Int(measurementWindow * recorder.sampleRate))
        guard n >= Int(3 * recorder.sampleRate), let h0 = tl.hostTime(ofFrame: 0),
              let h1 = tl.hostTime(ofFrame: Double(n)) else { return }
        let mic = recorder.samples(0..<n)

        // Program audio around the expected arrival of the wired group.
        let timings = engine.currentTimings()
        guard let ref = wired.compactMap({ timings[$0.0] }).first, let ring = engine.sourceRing else { return }
        let arrival = ref.expectedArrivalMs / 1000
        let tps = HostTime.ticksPerSecond
        guard let program = ring.programAudio(fromHost: h0 - (arrival + measurementSearch) * tps,
                                              seconds: Double(n) / recorder.sampleRate + 2 * measurementSearch) else { return }
        let analysis = await analysisWorker.analyze(mic: mic, microphoneRate: recorder.sampleRate,
                                                   program: program, programRate: ring.sampleRate,
                                                   search: measurementSearch, ignored: ignored,
                                                   referenceTolerance: referenceTolerance)
        guard !Task.isCancelled, self.recorder === recorder else { return }
        // Analysis deliberately leaves the main actor. Reject results if their playback/calibration
        // context changed during recording or computation, instead of applying stale measurements.
        guard engine.isEnabled, !engine.programMuted, !engine.syncClicksActive,
              Set(engine.activeOutputUIDs) == activeUIDs, engine.store.settings == settings,
              profiles.allSatisfy({ engine.store.profile(uid: $0.key) == $0.value }) else {
            unconfirmed = nil
            lastOffsetMs = nil
            return
        }
        let peaks = analysis.peaks
        lastCheck = Date()
        // Judge the last correction against the raw peaks: if the secondary peak didn't move, it
        // wasn't the wireless output (a reflection): undo and ignore that offset from now on.
        if let u = unconfirmed {
            unconfirmed = nil
            let raw = LiveSyncAnalyzer.assess(peaks, ignored: ignored, referenceTolerance: referenceTolerance)
            if let previousLatency = u.rollbackLatency(observedOffset: raw?.wirelessOffset,
                                                       wirelessUID: wl.0, context: context) {
                engine.updateProfile(u.uid) { prof in
                    guard var c = prof.calibration else { return }
                    c.latencyMs = previousLatency
                    prof.calibration = c
                }
                ignored.append(u.offset)
                corrections = max(0, corrections - 1)
                engine.log(String(format: "Live Sync: the peak at %+.1f ms is a reflection, not drift — correction undone", u.offset * 1000))
                return
            }
        }
        let assessment = analysis.assessment
        stats.checks += 1
        if assessment == nil { stats.unclear += 1 }
        if let o = assessment?.wirelessOffset { stats.offsets.append(o * 1000) }
        if Date().timeIntervalSince(stats.since) > 60 {
            let drifts = stats.offsets.map { String(format: "%+.1f", $0) }.joined(separator: ", ")
            engine.log("Live Sync: \(stats.checks) checks, \(stats.unclear) without a clear wired peak; drifts seen (ms): \(drifts.isEmpty ? "none" : drifts)")
            stats = (0, 0, 0, [], Date())
        }
        guard let a = assessment else {
            lastOffsetMs = nil
            return
        }
        guard let offset = a.wirelessOffset else {
            // A weak/merged/missing path is not positive evidence of alignment.
            lastOffsetMs = nil
            return
        }
        // Ignore candidates the music itself explains (it repeats at that delay).
        if analysis.rhythmic {
            stats.rhythmic += 1
            lastOffsetMs = nil
            return
        }
        lastOffsetMs = offset * 1000
        // Act only on a drift seen twice in a row (music can produce spurious correlation peaks).
        guard abs(offset) > 0.0025 else {
            return
        }
        keptEvidence = true
        if let accepted = confirmation.observe(offset, start: h0 / tps, end: h1 / tps) {
            let correction = accepted * 1000
            engine.updateProfile(wl.0) { prof in
                guard var c = prof.calibration else { return }
                c.latencyMs += correction
                prof.calibration = c
            }
            // Snapshot after applying our update: it must remain eligible for verification, while
            // subsequent external changes to calibration, EQ, settings or outputs invalidate it.
            let correctedContext = LiveSyncPlaybackContext(
                profiles: Dictionary(uniqueKeysWithValues: activeUIDs.map { ($0, engine.store.profile(uid: $0)) }),
                settings: engine.store.settings)
            unconfirmed = LiveSyncPendingCorrection(offset: offset, previousLatency: cal.latencyMs,
                                                     uid: wl.0, expectedContext: correctedContext)
            corrections += 1
            lastCorrection = (Date(), correction)
            engine.log(String(format: "Live Sync: %@ drifted %+.1f ms — corrected", wl.1.name, correction))
        }
    }
}
