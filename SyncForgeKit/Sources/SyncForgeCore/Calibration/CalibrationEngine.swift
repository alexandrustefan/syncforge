import Foundation
import Observation

public struct CalibrationOptions: Sendable {
    public var levelDb: Double = -18
    public var maxLatency: Double = 2.5
    public var repetitions = 5
    public var verify = true
    public var apply = true
    /// Set per-output level trims so all outputs are equally loud at the microphone.
    public var matchLevels = false
    /// Fit tone-matching corrections per output and room-resonance cuts for the system EQ.
    public var autoEQ = true
    /// Bluetooth microphones switch many headsets/speakers into the hands-free profile, which
    /// changes the playback codec and latency. Only allowed when explicitly requested.
    public var allowBluetoothMicrophone = false
    /// Developer diagnostics only: when set, every analysed microphone segment and its timing are
    /// written to this directory. Off by default; the app never sets it.
    public var debugDumpDirectory: URL?
    public init() {}
}

/// Measurement of one output.
public struct DeviceMeasurement: Identifiable, Sendable, Equatable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    /// Time from the Core Audio presentation time stamp until the sound is time-stamped by the
    /// microphone (median of accepted runs), ms. Includes the microphone's own processing delay,
    /// which is the same for every output and cancels in the compensation.
    public var latencyMs: Double?
    public var spreadMs: Double = 0
    public var samplesMs: [Double] = []
    public var accepted = 0
    public var peakToNoiseDb: Double = 0
    public var confidence: MeasurementConfidence = .failed
    public var failure: String?
    /// Compensation applied after calibration, ms.
    public var compensationMs: Double?
    /// Level at the microphone relative to the loudest output, dB (for full-scale input).
    public var relativeLevelDb: Double?
    /// Tone-matching correction fitted for this output.
    public var correction: [EQBand] = []
}

public struct VerificationResult: Sendable, Equatable {
    /// Re-measured arrival of each output relative to the program timeline, ms.
    public var arrivalMs: [String: Double]
    /// Largest difference between outputs after compensation, ms.
    public var remainingDifferenceMs: Double
    /// Largest spread of the repeated verification runs (measurement repeatability), ms.
    public var repeatabilityMs: Double
}

public struct CalibrationReport: Sendable {
    public var date: Date
    public var microphoneName: String
    public var measurements: [DeviceMeasurement]
    public var verification: VerificationResult?
    /// Estimated difference before calibration, from the previous delays and the new measurements, ms.
    public var differenceBeforeMs: Double?
    /// Room-resonance cuts fitted for the system EQ.
    public var roomCorrection: [EQBand] = []
}

public enum CalibrationError: LocalizedError {
    case engineOff, noOutputs, noMicrophone, bluetoothMicrophone(String), permissionDenied, microphoneStalled, outputVanished(String), processingChanged

    public var errorDescription: String? {
        switch self {
        case .engineOff: return "Turn SyncForge on before calibrating."
        case .noOutputs: return "Enable at least one output to calibrate."
        case .noMicrophone: return "No suitable microphone was found."
        case .bluetoothMicrophone(let n):
            return "“\(n)” is a Bluetooth microphone. Using it would switch Bluetooth audio to the low-quality hands-free profile and change its latency. Choose the built-in or a USB microphone."
        case .permissionDenied: return "Microphone access was denied. Allow it in System Settings › Privacy & Security › Microphone."
        case .microphoneStalled: return "The microphone stopped delivering audio."
        case .outputVanished(let n): return "“\(n)” disappeared during calibration."
        case .processingChanged: return "Equalizer settings changed during calibration. Run calibration again with the settings held constant."
        }
    }
}

/// Acoustic latency calibration.
///
/// The microphone is opened only while calibration runs (the UI shows an indicator), recordings
/// live in memory and are discarded afterwards. Each output is measured on its own: a log sweep is
/// scheduled on the program timeline, so it passes through exactly the same delay line, resampler
/// and filters as music. Because both the scheduled presentation time and the microphone samples
/// are expressed in host time, the result is the device's real acoustic latency, independent of
/// what its driver reports. All outputs then wait for the slowest one.
@MainActor
@Observable
public final class CalibrationEngine {
    public enum Phase: Equatable, Sendable {
        case idle, preparing, listening, measuring(String), applying, verifying(String), finished, failed(String), cancelled
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: Double = 0
    /// Actual target count, including any expansion required by microphone changes.
    public private(set) var speakerCount = 0
    /// 1-based only while acquiring one speaker at a time; nil for interleaved measurements.
    public private(set) var currentSpeakerIndex: Int?
    public private(set) var micLevelDb: Float = -120
    public private(set) var micInUse = false
    public private(set) var measurements: [DeviceMeasurement] = []
    public private(set) var verification: VerificationResult?
    public private(set) var lastReport: CalibrationReport?
    public private(set) var log: [String] = []
    public var options = CalibrationOptions()

    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    private let chirpSeconds = 0.35

    public init(engine: SyncEngine) {
        self.engine = engine
    }

    public var isRunning: Bool {
        switch phase {
        case .preparing, .listening, .measuring, .applying, .verifying: return true
        default: return false
        }
    }

    /// Starts calibration in the background (UI entry point).
    public func start(outputs: [String]? = nil, microphoneUID: String? = nil) {
        guard !isRunning else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.run(outputs: outputs, microphoneUID: microphoneUID) } catch {}
        }
    }

    public func cancel() { task?.cancel() }

    /// Clears the completed or failed session when the user starts over. A live measurement
    /// owns its state until it finishes or cancellation completes.
    public func clearResults() {
        guard !isRunning else { return }
        phase = .idle
        progress = 0
        measurements = []
        verification = nil
        lastReport = nil
        log = []
        speakerCount = 0
        currentSpeakerIndex = nil
        micLevelDb = -120
    }

    /// Runs a full calibration and returns the report.
    @discardableResult
    public func run(outputs: [String]? = nil, microphoneUID: String? = nil) async throws -> CalibrationReport {
        measurements = []
        speakerCount = 0
        currentSpeakerIndex = nil
        defer { currentSpeakerIndex = nil }
        verification = nil
        lastReport = nil
        log = []
        progress = 0
        phase = .preparing
        do {
            let report = try await perform(outputs: outputs, microphoneUID: microphoneUID)
            lastReport = report
            phase = .finished
            progress = 1
            return report
        } catch is CancellationError {
            phase = .cancelled
            note("Calibration cancelled")
            throw CancellationError()
        } catch {
            phase = .failed(error.localizedDescription)
            note("Calibration failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func note(_ s: String) {
        log.append(s)
        engine.log(s)
    }

    // MARK: - Procedure

    private func perform(outputs: [String]?, microphoneUID: String?) async throws -> CalibrationReport {
        guard engine.isEnabled else { throw CalibrationError.engineOff }
        var targets = (outputs ?? engine.activeOutputUIDs).filter { engine.renderer(for: $0) != nil }
            .sorted { (engine.renderer(for: $0)?.device.name ?? $0) < (engine.renderer(for: $1)?.device.name ?? $1) }
        guard !targets.isEmpty else { throw CalibrationError.noOutputs }
        // Calibration owns test playback. Clicks on other outputs would contaminate sweeps,
        // including when calibration is opened from the menu without leaving the sync-test UI.
        if engine.syncClicksActive { engine.stopSyncClicks() }

        let micUID = microphoneUID ?? engine.store.settings.calibrationMicrophoneUID
        guard let mic = micUID.flatMap({ engine.devices.inputDevice(uid: $0) }) ?? engine.devices.recommendedMicrophone else {
            throw CalibrationError.noMicrophone
        }
        if mic.transport.isBluetooth && !options.allowBluetoothMicrophone { throw CalibrationError.bluetoothMicrophone(mic.name) }
        // Measurements include the microphone's own delay, so never mix microphones: if another
        // active output was calibrated with a different microphone, measure all active outputs.
        if outputs != nil {
            let others = engine.activeOutputUIDs.filter { !targets.contains($0) }
            if others.contains(where: { engine.store.profile(uid: $0)?.calibration.map { $0.microphoneUID != mic.uid } ?? false }) {
                targets = engine.activeOutputUIDs.sorted()
                note("Other outputs were calibrated with a different microphone — measuring all outputs")
            }
        }
        speakerCount = targets.count
        guard await MicrophonePermission.request() else { throw CalibrationError.permissionDenied }

        // Delays in effect before calibration, to estimate the "before" error later.
        let previousTimings = engine.currentTimings()

        let recorder = try MicrophoneRecorder(device: mic, capacitySeconds: 40 + Double(targets.count) * 25)
        try recorder.start()
        recorder.setArmed(true)
        micInUse = true
        startMeter(recorder)
        engine.setProgramMuted(true)
        defer {
            for uid in targets { engine.renderer(for: uid)?.stopTestSignal() }
            recorder.setArmed(false)
            recorder.stop()
            meterTask?.cancel()
            micInUse = false
            engine.setProgramMuted(false)
        }
        note("Calibrating \(targets.count) output(s) with “\(mic.name)”")

        phase = .listening
        try await sleep(0.6)
        let noise = recorder.samples(max(0, recorder.frameCount - Int(0.5 * recorder.sampleRate))..<recorder.frameCount)
        let noiseDb = 20 * log10(max(rms(noise), 1e-7))
        noiseProfile = LatencyEstimator.NoiseProfile(noise: recorder.samples(max(0, recorder.frameCount - Int(0.5 * recorder.sampleRate))..<recorder.frameCount))
        note(String(format: "Room noise at the microphone: %.0f dBFS", noiseDb))

        let rounds = max(3, options.repetitions)
        let totalSteps = Double(targets.count) * (1 + Double(rounds) + (options.verify ? 3 : 0))
        var done = 0.0
        func step() { done += 1; progress = min(1, done / totalSteps) }

        // 1. Coarse: find each output with a wide search window (one at a time).
        var results: [DeviceMeasurement] = []
        var coarse: [String: (latency: Double, gainDb: Double, pnr: Double)] = [:]
        for (index, uid) in targets.enumerated() {
            currentSpeakerIndex = index + 1
            try Task.checkCancellation()
            guard let r = engine.renderer(for: uid) else { throw CalibrationError.outputVanished(uid) }
            phase = .measuring(r.device.name)
            var m = DeviceMeasurement(uid: uid, name: r.device.name)
            do {
                if let c = try await coarseLatency(uid: uid, recorder: recorder) {
                    coarse[uid] = c
                } else {
                    m.failure = "No test signal detected. Check that the speaker is on, its volume is up and the microphone can hear it."
                    note("\(m.name): \(m.failure!)")
                }
            } catch let e as CalibrationError {
                m.failure = e.localizedDescription
            }
            step()
            results.append(m)
            measurements = results
        }

        currentSpeakerIndex = nil

        // 2. Interleaved repetitions, drift-cancelled against a reference output.
        let found = targets.filter { coarse[$0] != nil }
        let reference = chooseReference(found, coarse: coarse)
        var levels: [String: Double] = [:]
        var responses: [String: AutoEQ.Response] = [:]
        if let reference {
            phase = .measuring(found.count > 1 ? "all outputs (interleaved)" : (engine.renderer(for: reference)?.device.name ?? ""))
            let runs = try await interleaved(found, recorder: recorder, expected: coarse.mapValues { $0.latency },
                                             gains: coarse.mapValues { $0.gainDb }, rounds: rounds, step: step)
            let combined = DriftCancellation.combine(runs.mapValues { $0.map { DriftCancellation.Sample(time: $0.time, latency: $0.latency * 1000) } },
                                                     reference: reference)
            for i in results.indices {
                let uid = results[i].uid
                guard let list = runs[uid], let c = combined[uid] else {
                    if coarse[uid] != nil { results[i].failure = "The repeated sweeps were not detected reliably." }
                    continue
                }
                results[i] = summarize(results[i], list: list, combined: c)
                let lv = list.compactMap(\.levelDb)
                if !lv.isEmpty { levels[uid] = RobustStats.median(lv) - (coarse[uid]?.gainDb ?? 0) }
                if let avg = AutoEQ.average(list.compactMap(\.response)) { responses[uid] = avg }
                let m = results[i]
                if let l = m.latencyMs {
                    note(String(format: "%@: %.1f ms (±%.2f ms, %d/%d runs, %.0f dB, %@ confidence)", m.name, l, m.spreadMs / 2,
                                m.accepted, m.samplesMs.count, m.peakToNoiseDb, m.confidence.rawValue))
                } else {
                    note("\(m.name): \(m.failure ?? "measurement failed")")
                }
            }
            if found.count > 1 { note("Reference for drift cancellation: \(engine.renderer(for: reference)?.device.name ?? reference)") }
            measurements = results
        }

        // Estimated error before calibration: difference of (previous delay + measured latency).
        let measured = results.filter { $0.latencyMs != nil && $0.confidence != .failed }
        var before: Double?
        let beforeArrivals = measured.compactMap { m in previousTimings[m.uid].map { $0.totalDelayMs + m.latencyMs! } }
        if beforeArrivals.count >= 2 { before = beforeArrivals.max()! - beforeArrivals.min()! }

        // 3. Apply.
        if options.apply {
            phase = .applying
            for m in measured {
                let reported = engine.devices.outputDevice(uid: m.uid)?.reportedOutputLatencyMs ?? 0
                engine.updateProfile(m.uid) {
                    $0.calibration = CalibrationRecord(latencyMs: m.latencyMs!, spreadMs: m.spreadMs, peakToNoiseDb: m.peakToNoiseDb,
                                                       confidence: m.confidence, repetitions: m.accepted, date: Date(),
                                                       microphoneUID: mic.uid, reportedLatencyMs: reported)
                    $0.delayMode = .automatic
                    $0.trimMs = 0
                }
            }
            if options.matchLevels, levels.count >= 2 {
                let trims = LevelMatching.trims(levelsDb: levels)
                for (uid, t) in trims {
                    engine.updateProfile(uid) { $0.levelTrimDb = (t * 2).rounded() / 2 }
                    note(String(format: "%@ level trim: %+.1f dB", engine.renderer(for: uid)?.device.name ?? uid, t))
                }
            }
            refreshCompensation(&results)
        }
        for i in results.indices { results[i].relativeLevelDb = levels[results[i].uid].map { $0 - (levels.values.max() ?? 0) } }

        // Tone matching and room-resonance correction from the measured responses.
        var roomCorrection: [EQBand] = []
        if !responses.isEmpty {
            let plan = AutoEQ.plan(responses)
            for i in results.indices { results[i].correction = plan.perOutput[results[i].uid] ?? [] }
            roomCorrection = plan.room
            if options.apply {
                for (uid, curve) in plan.responses {
                    engine.updateProfile(uid) { p in
                        p.calibration?.responseDb = curve
                        if self.options.autoEQ, let bands = plan.perOutput[uid] { p.correction = bands }
                    }
                }
                if options.autoEQ {
                    // Room cuts only when measured over the whole set of active outputs.
                    if targets.count == engine.activeOutputUIDs.count { engine.updateSettings { $0.roomCorrection = plan.room } }
                    for m in results where !m.correction.isEmpty {
                        note("\(m.name) tone correction: " + m.correction.map { String(format: "%@ %.0f Hz %+.1f dB", $0.type.displayName, $0.frequency, $0.gainDb) }.joined(separator: ", "))
                    }
                    if !plan.room.isEmpty {
                        note("Room resonances: " + plan.room.map { String(format: "%.0f Hz %+.1f dB", $0.frequency, $0.gainDb) }.joined(separator: ", "))
                    }
                }
            }
        }
        measurements = results

        // 4. Verification: interleaved again, with the new delays in place.
        var verificationResult: VerificationResult?
        let verifiable = measured.map(\.uid)
        if options.verify && options.apply, let reference, verifiable.contains(reference) {
            try await sleep(0.5) // let renderers crossfade to the new delays
            phase = .verifying(verifiable.count > 1 ? "all outputs" : (results.first?.name ?? ""))
            let latestExpected = Dictionary(uniqueKeysWithValues: measured.map { ($0.uid, $0.latencyMs! / 1000) })
            let runs = try await interleaved(verifiable, recorder: recorder, expected: latestExpected,
                                             gains: coarse.mapValues { $0.gainDb }, rounds: 3, step: step)
            let combined = DriftCancellation.combine(runs.mapValues { $0.map { DriftCancellation.Sample(time: $0.time, latency: $0.latency * 1000) } },
                                                     reference: reference)
            var arrivals: [String: Double] = [:]
            var repeatability = 0.0
            for uid in verifiable {
                guard let c = combined[uid], let total = engine.totalDelaySeconds(uid) else { continue }
                arrivals[uid] = total * 1000 + c.latencyMs
                repeatability = max(repeatability, c.spreadMs)
            }
            if !arrivals.isEmpty {
                let diff = arrivals.count >= 2 ? arrivals.values.max()! - arrivals.values.min()! : 0
                verificationResult = VerificationResult(arrivalMs: arrivals, remainingDifferenceMs: diff, repeatabilityMs: repeatability)
                verification = verificationResult
                note(String(format: "Verification: remaining difference %.2f ms (repeatability %.2f ms)", diff, repeatability))
                // Outputs (notably Bluetooth) can move by a few ms within seconds. The verification
                // runs are the most recent measurement, so refine the compensation with them.
                if diff > 1 {
                    for i in results.indices {
                        guard let old = results[i].latencyMs, let new = combined[results[i].uid]?.latencyMs else { continue }
                        let moved = abs(new - old)
                        if moved > 0.5 { note(String(format: "%@ moved %.1f ms during calibration", results[i].name, moved)) }
                        results[i].latencyMs = new
                        results[i].spreadMs = max(results[i].spreadMs, moved)
                        engine.updateProfile(results[i].uid) { p in
                            guard var c = p.calibration else { return }
                            c.latencyMs = new
                            c.spreadMs = max(c.spreadMs, moved)
                            p.calibration = c
                        }
                    }
                    refreshCompensation(&results)
                    measurements = results
                    note("Compensation refined with the verification measurements")
                }
            }
        }

        return CalibrationReport(date: Date(), microphoneName: mic.name, measurements: results,
                                 verification: verificationResult, differenceBeforeMs: before, roomCorrection: roomCorrection)
    }

    private func refreshCompensation(_ results: inout [DeviceMeasurement]) {
        let timings = engine.currentTimings()
        for i in results.indices { results[i].compensationMs = timings[results[i].uid]?.appliedDelayMs }
        for m in results where m.compensationMs != nil {
            note(String(format: "%@ compensation: +%.1f ms", m.name, m.compensationMs!))
        }
    }

    /// The reference for drift cancellation: preferably a wired output (stable latency) with a strong
    /// response.
    private func chooseReference(_ uids: [String], coarse: [String: (latency: Double, gainDb: Double, pnr: Double)]) -> String? {
        uids.max { a, b in
            let wa = engine.renderer(for: a)?.device.transport.isWireless == false
            let wb = engine.renderer(for: b)?.device.transport.isWireless == false
            if wa != wb { return !wa }
            return (coarse[a]?.pnr ?? 0) < (coarse[b]?.pnr ?? 0)
        }
    }

    // MARK: - Measurement primitives

    private struct Run {
        let latency: Double  // seconds
        let peakToNoiseDb: Double
        var time: Double = 0          // arrival (s since boot), for drift cancellation
        var levelDb: Double?          // received sweep level relative to the reference signal
        var response: AutoEQ.Response?
    }

    /// One sweep with a wide search window; raises the level if the sweep is not detected.
    private func coarseLatency(uid: String, recorder: MicrophoneRecorder) async throws -> (latency: Double, gainDb: Double, pnr: Double)? {
        var gainDb = options.levelDb
        for _ in 0..<3 {
            guard let run = try await sweep(uid: uid, recorder: recorder, gainDb: gainDb, searchFrom: -0.02,
                                            searchTo: options.maxLatency) else { return nil }
            if run.peakToNoiseDb >= 14 { return (run.latency, gainDb, run.peakToNoiseDb) }
            note(String(format: "Weak response (%.0f dB) — repeating louder", run.peakToNoiseDb))
            gainDb = min(-6, gainDb + 6)
        }
        return nil
    }

    /// Plays one sweep on `uid` and locates it in a search window relative to its presentation time.
    private func sweep(uid: String, recorder: MicrophoneRecorder, gainDb: Double, searchFrom: Double, searchTo: Double) async throws -> Run? {
        guard let r = engine.renderer(for: uid), let total = engine.totalDelaySeconds(uid) else {
            throw CalibrationError.outputVanished(uid)
        }
        let emit = Double(HostTime.now()) + 0.3 * HostTime.ticksPerSecond
        let timelineStart = UInt64(emit - total * HostTime.ticksPerSecond)
        let processing = engine.processingChain(for: uid, sampleRate: r.sampleRate).cascade
        r.playTestSignal(TestSignals.logChirp(duration: chirpSeconds, sampleRate: r.sampleRate), timelineStart: timelineStart,
                         gain: TestSignals.dbToGain(gainDb))
        defer { r.stopTestSignal() }
        let lo = emit + searchFrom * HostTime.ticksPerSecond
        let hi = emit + (searchTo + chirpSeconds + 0.05) * HostTime.ticksPerSecond
        try await waitForMicrophone(recorder, untilHost: hi)
        guard engine.processingChain(for: uid, sampleRate: r.sampleRate).cascade == processing else {
            throw CalibrationError.processingChanged
        }
        return analyze(recorder, emit: emit, windowLo: lo, windowHi: hi,
                       processing: processing, processingSampleRate: r.sampleRate)
    }

    /// Interleaved sweeps: every output plays `rounds` sweeps, taking turns. Emission times are offset
    /// by each output's expected latency so that the sweeps *arrive* evenly spaced and never overlap,
    /// even when outputs differ by hundreds of milliseconds.
    private func interleaved(_ uids: [String], recorder: MicrophoneRecorder, expected: [String: Double],
                             gains: [String: Double], rounds: Int, step: () -> Void) async throws -> [String: [Run]] {
        let spacing = chirpSeconds + 0.45
        let slots = Double(uids.count)
        let tps = HostTime.ticksPerSecond
        let maxExpected = uids.compactMap { expected[$0] }.max() ?? 0
        let base = Double(HostTime.now()) + (0.3 + max(0, maxExpected)) * tps   // arrival time of slot 0
        var schedule: [(uid: String, emit0: Double, processing: [Biquad], sampleRate: Double)] = []
        for (d, uid) in uids.enumerated() {
            guard let r = engine.renderer(for: uid), let total = engine.totalDelaySeconds(uid), let l = expected[uid] else {
                throw CalibrationError.outputVanished(uid)
            }
            let emit0 = base + (Double(d) * spacing - l) * tps
            r.playTestSignal(TestSignals.logChirp(duration: chirpSeconds, sampleRate: r.sampleRate),
                             timelineStart: UInt64(emit0 - total * tps), period: slots * spacing, repeats: UInt32(rounds),
                             gain: TestSignals.dbToGain(gains[uid] ?? options.levelDb))
            schedule.append((uid, emit0, engine.processingChain(for: uid, sampleRate: r.sampleRate).cascade, r.sampleRate))
        }
        defer { for uid in uids { engine.renderer(for: uid)?.stopTestSignal() } }

        var out: [String: [Run]] = [:]
        for k in 0..<rounds {
            for (uid, emit0, processing, sampleRate) in schedule {
                let emit = emit0 + Double(k) * slots * spacing * tps
                let l = expected[uid] ?? 0
                let lo = emit + (l - 0.04) * tps
                let hi = emit + (l + 0.04 + chirpSeconds) * tps
                try await waitForMicrophone(recorder, untilHost: hi)
                guard engine.processingChain(for: uid, sampleRate: sampleRate).cascade == processing else {
                    throw CalibrationError.processingChanged
                }
                if let run = analyze(recorder, emit: emit, windowLo: lo, windowHi: hi,
                                     processing: processing, processingSampleRate: sampleRate), run.peakToNoiseDb >= 10 {
                    out[uid, default: []].append(run)
                }
            }
            for _ in uids { step() }
        }
        return out
    }

    private func analyze(_ recorder: MicrophoneRecorder, emit: Double, windowLo: Double, windowHi: Double,
                         processing: [Biquad], processingSampleRate: Double) -> Run? {
        let timeline = recorder.timeline()
        guard let f0 = timeline.frame(atHost: windowLo), let f1 = timeline.frame(atHost: windowHi) else { return nil }
        let start = max(0, Int(f0.rounded(.down)))
        let segment = recorder.samples(start..<Int(f1.rounded(.up)))
        let reference = TestSignals.logChirp(duration: chirpSeconds, sampleRate: recorder.sampleRate)
        guard let est = LatencyEstimator.estimate(recording: segment, reference: reference, sampleRate: recorder.sampleRate,
                                                  noise: noiseProfile),
              let host = timeline.hostTime(ofFrame: Double(start) + est.lag) else { return nil }
        // Arrival is taken at the microphone's time stamp. The driver-reported input latency is not
        // subtracted: on Apple Silicon built-in microphones it is not a valid time-stamp offset
        // (subtracting it produced physically impossible negative latencies). The microphone's own
        // delay is identical for every output, so it cancels in the compensation.
        let latency = (host - emit) / HostTime.ticksPerSecond
        if let dir = options.debugDumpDirectory { dump(dir, segment: segment, start: start, emit: emit, lo: windowLo, est: est, latency: latency, timeline: timeline) }
        let level = LatencyEstimator.bandGainDb(recording: segment, arrival: Int(est.lag.rounded()), reference: reference,
                                                sampleRate: recorder.sampleRate)
        let response = AutoEQ.response(recording: segment, arrival: Int(est.lag.rounded()), reference: reference,
                                       sampleRate: recorder.sampleRate, noise: noiseProfile, sweepBand: 60...10000,
                                       processing: processing, processingSampleRate: processingSampleRate)
        return Run(latency: latency, peakToNoiseDb: est.peakToNoiseDb, time: host / HostTime.ticksPerSecond,
                   levelDb: level, response: response)
    }

    private func summarize(_ base: DeviceMeasurement, list: [Run], combined: DriftCancellation.Result) -> DeviceMeasurement {
        var m = base
        m.samplesMs = list.map { $0.latency * 1000 }
        m.accepted = combined.accepted
        m.peakToNoiseDb = RobustStats.median(list.map(\.peakToNoiseDb))
        guard combined.accepted >= 2 else {
            m.failure = "Measurements were inconsistent (\(list.count) detected, \(combined.accepted) consistent). Reduce background noise or move the microphone closer."
            m.confidence = .failed
            return m
        }
        m.latencyMs = combined.latencyMs
        m.spreadMs = combined.spreadMs
        let needed = max(3, combined.total - 1)
        if combined.accepted >= needed && m.spreadMs <= 0.5 && m.peakToNoiseDb >= 18 { m.confidence = .high }
        else if combined.accepted >= 3 && m.spreadMs <= 2 && m.peakToNoiseDb >= 12 { m.confidence = .medium }
        else { m.confidence = .low }
        return m
    }

    // MARK: - Helpers

    @ObservationIgnored private var dumpIndex = 0
    @ObservationIgnored private var noiseProfile: LatencyEstimator.NoiseProfile?

    private func dump(_ dir: URL, segment: [Float], start: Int, emit: Double, lo: Double, est: ArrivalEstimate,
                      latency: Double, timeline: MicTimeline) {
        dumpIndex += 1
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent(String(format: "seg%03d", dumpIndex))
        segment.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: base.appendingPathExtension("f32")) }
        let segHost = timeline.hostTime(ofFrame: Double(start)) ?? 0
        let meta: [String: Any] = [
            "phase": "\(phase)", "emitHost": emit, "windowLoHost": lo, "segmentStartFrame": start,
            "segmentStartHost": segHost, "lag": est.lag, "strongestLag": est.strongestLag,
            "peakToNoiseDb": est.peakToNoiseDb, "earliestRelativeDb": est.earliestRelativeDb,
            "latencyMs": latency * 1000, "ticksPerSecond": HostTime.ticksPerSecond,
            "micSampleRate": timeline.sampleRate, "anchors": timeline.anchors.count,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: base.appendingPathExtension("json"))
        }
    }

    private func waitForMicrophone(_ recorder: MicrophoneRecorder, untilHost host: Double) async throws {
        let deadline = Date().addingTimeInterval(max(1, (host - Double(HostTime.now())) / HostTime.ticksPerSecond) + 3)
        while true {
            try Task.checkCancellation()
            let tl = recorder.timeline()
            if let needed = tl.frame(atHost: host), Double(recorder.frameCount) >= needed + 64 { return }
            if Date() > deadline { throw CalibrationError.microphoneStalled }
            try await sleep(0.05)
        }
    }

    private func startMeter(_ recorder: MicrophoneRecorder) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                let p = recorder.peak(reset: true)
                self?.micLevelDb = 20 * log10(max(p, 1e-6))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }
}
