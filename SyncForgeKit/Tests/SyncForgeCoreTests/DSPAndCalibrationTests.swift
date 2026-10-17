import XCTest
@testable import SyncForgeCore
import SyncForgeRT

final class BiquadDesignTests: XCTestCase {
    func testPeakFilterGainAtCenter() {
        let bq = BiquadDesign.design(.peak, frequency: 1000, gainDb: 6, q: 1.41, sampleRate: 48000)!
        XCTAssertEqual(20 * log10(bq.magnitude(at: 1000, sampleRate: 48000)), 6, accuracy: 0.01)
        XCTAssertEqual(20 * log10(bq.magnitude(at: 20, sampleRate: 48000)), 0, accuracy: 0.1)
    }

    func testShelves() {
        let low = BiquadDesign.design(.lowShelf, frequency: 200, gainDb: -8, q: 0.707, sampleRate: 44100)!
        XCTAssertEqual(20 * log10(low.magnitude(at: 20, sampleRate: 44100)), -8, accuracy: 0.3)
        XCTAssertEqual(20 * log10(low.magnitude(at: 10000, sampleRate: 44100)), 0, accuracy: 0.1)
        let high = BiquadDesign.design(.highShelf, frequency: 5000, gainDb: 4, q: 0.707, sampleRate: 48000)!
        XCTAssertEqual(20 * log10(high.magnitude(at: 18000, sampleRate: 48000)), 4, accuracy: 0.4)
    }

    func testButterworthHighPassSlopes() {
        for slope in FilterSlope.allCases {
            let c = BiquadDesign.passFilter(PassFilter(enabled: true, frequency: 100, slope: slope), highPass: true, sampleRate: 48000)
            XCTAssertEqual(c.count, slope.order / 2)
            XCTAssertEqual(BiquadDesign.responseDb(c, frequency: 100, sampleRate: 48000), -3.01, accuracy: 0.05)
            // One octave below the cut-off a Butterworth filter of order N is close to -6N dB.
            let octave = BiquadDesign.responseDb(c, frequency: 50, sampleRate: 48000)
            XCTAssertEqual(octave, -Double(slope.rawValue), accuracy: 1.5, "\(slope)")
            XCTAssertEqual(BiquadDesign.responseDb(c, frequency: 2000, sampleRate: 48000), 0, accuracy: 0.05)
        }
    }

    func testFlatIsNeutralAndPresetsHaveHeadroom() {
        XCTAssertTrue(DSPSettings.flat.isNeutral)
        XCTAssertTrue(BiquadDesign.cascade(.flat, sampleRate: 48000).isEmpty)
        let bass = EQPresets.named("Bass Boost")!.settings
        let boost = BiquadDesign.maxBoostDb(bass, sampleRate: 48000)
        XCTAssertGreaterThan(boost, 4)
        XCTAssertEqual(BiquadDesign.effectivePreampDb(bass, sampleRate: 48000), -boost, accuracy: 1e-9)
    }

    func testSystemAndDeviceEQCombine() {
        var system = DSPSettings.flat
        system.bands[5].gainDb = 4          // +4 dB at 1 kHz for everything
        system.autoHeadroom = false
        var device = DSPSettings.flat
        device.bands[5].gainDb = 3          // +3 dB more on this output
        device.autoHeadroom = false
        let c = BiquadDesign.chain(system: system, device: device, sampleRate: 48000)
        XCTAssertEqual(BiquadDesign.responseDb(c.cascade, frequency: 1000, sampleRate: 48000), 7, accuracy: 0.05)
        let excluded = BiquadDesign.chain(system: nil, device: device, sampleRate: 48000)
        XCTAssertEqual(BiquadDesign.responseDb(excluded.cascade, frequency: 1000, sampleRate: 48000), 3, accuracy: 0.05)
        device.autoHeadroom = true
        XCTAssertEqual(BiquadDesign.chain(system: system, device: device, sampleRate: 48000).preampDb, -7, accuracy: 0.1)
        XCTAssertFalse(BiquadDesign.chain(system: .flat, device: .flat, sampleRate: 48000).isActive)
    }

    func testFiltersAboveNyquistAreSkipped() {
        XCTAssertNil(BiquadDesign.design(.lowPass, frequency: 23000, gainDb: 0, q: 0.7, sampleRate: 44100))
    }
}

final class SyncMathTests: XCTestCase {
    func testSlowestOutputGetsNoCompensation() {
        let t = SyncMath.timings([
            .init(uid: "analog", latencyMs: 12, source: .measured, mode: .automatic, manualDelayMs: 0, trimMs: 0),
            .init(uid: "bt", latencyMs: 754, source: .measured, mode: .automatic, manualDelayMs: 0, trimMs: 0),
            .init(uid: "usb", latencyMs: 30, source: .measured, mode: .automatic, manualDelayMs: 0, trimMs: 0.5),
        ], baseLatencyMs: 45, maxDelayMs: 3000)
        XCTAssertEqual(t["bt"]!.appliedDelayMs, 0)
        XCTAssertEqual(t["analog"]!.appliedDelayMs, 742)
        XCTAssertEqual(t["usb"]!.appliedDelayMs, 724.5)
        XCTAssertEqual(t["analog"]!.expectedArrivalMs, t["bt"]!.expectedArrivalMs)
        XCTAssertEqual(t["analog"]!.totalDelayMs, 787)
    }

    func testManualOutputParticipatesAndClamps() {
        let t = SyncMath.timings([
            .init(uid: "a", latencyMs: 10, source: .measured, mode: .automatic, manualDelayMs: 0, trimMs: 0),
            .init(uid: "m", latencyMs: 100, source: .driverEstimate, mode: .manual, manualDelayMs: 400, trimMs: 0),
            .init(uid: "z", latencyMs: 5, source: .measured, mode: .manual, manualDelayMs: 5000, trimMs: 0),
        ], baseLatencyMs: 40, maxDelayMs: 3000)
        XCTAssertEqual(t["a"]!.appliedDelayMs, 2995, accuracy: 1e-9) // aligns to z's clamped 3005 ms arrival
        XCTAssertTrue(t["z"]!.clamped)
        XCTAssertEqual(t["m"]!.appliedDelayMs, 400)
    }

    func testVolumeLaw() {
        XCTAssertEqual(SyncMath.linearToDb(SyncMath.sliderGain(0.5)), -12.04, accuracy: 0.01)
        XCTAssertEqual(SyncMath.sliderGain(1), 1)
        XCTAssertEqual(SyncMath.sliderGain(0), 0)
    }
}

final class LatencyEstimatorTests: XCTestCase {
    /// Simulated room: the chirp arrives after a fractional delay through a band-limited speaker,
    /// followed by a *stronger* desk reflection 1.4 ms later, a reverberant tail and noise.
    func testFindsDirectSoundDespiteStrongReflection() {
        let fs = 48000.0
        let reference = TestSignals.logChirp(sampleRate: fs)
        let trueDelay = 0.7543  // seconds
        var rec = [Float](repeating: 0, count: Int(fs * 1.5))
        func addEcho(_ delay: Double, _ gain: Float) {
            // Fractional delay via linear interpolation of the reference.
            let d = delay * fs
            let i0 = Int(d.rounded(.down)), frac = Float(d - Double(i0))
            for k in 0..<reference.count - 1 where i0 + k < rec.count {
                rec[i0 + k] += gain * (reference[k] * (1 - frac) + reference[k + 1] * frac)
            }
        }
        addEcho(trueDelay, 0.3)
        addEcho(trueDelay + 0.0014, 0.42)
        var rng = SystemRandomNumberGenerator()
        for k in 0..<40 { addEcho(trueDelay + 0.005 + Double(k) * 0.0021, 0.15 * Float(exp(-Double(k) / 12))) }
        for i in 0..<rec.count { rec[i] += Float.random(in: -0.05...0.05, using: &rng) }
        // Speaker colouration: small speaker with weak bass and treble.
        let hp = BiquadDesign.passFilter(PassFilter(enabled: true, frequency: 300, slope: .db24), highPass: true, sampleRate: fs)
        let lp = BiquadDesign.passFilter(PassFilter(enabled: true, frequency: 6000, slope: .db12), highPass: false, sampleRate: fs)
        rec = filter(rec, hp + lp)

        let est = LatencyEstimator.estimate(recording: rec, reference: reference, sampleRate: fs)!
        let measured = est.lag / fs
        // The filters add a little group delay; direct-path accuracy within 0.3 ms.
        XCTAssertEqual(measured, trueDelay, accuracy: 0.0003, "measured \(measured)")
        XCTAssertGreaterThan(est.peakToNoiseDb, 15)
        XCTAssertGreaterThan(est.strongestLag, est.lag) // the reflection was stronger
    }

    /// A microphone path that removes everything above 5 kHz (as measured on a MacBook Pro): with
    /// noise-aware weighting the empty band must not degrade the estimate.
    func testBandLimitedMicrophoneWithNoiseProfile() {
        let fs = 48000.0
        let reference = TestSignals.logChirp(sampleRate: fs)
        let delay = 0.4321
        var rec = [Float](repeating: 0, count: Int(fs * 1.2))
        let d0 = Int(delay * fs)
        for k in 0..<reference.count { rec[d0 + k] += 0.2 * reference[k] }
        let lp = BiquadDesign.passFilter(PassFilter(enabled: true, frequency: 5000, slope: .db48), highPass: false, sampleRate: fs)
        rec = filter(rec, lp)
        let noise = (0..<Int(fs)).map { _ in Float.random(in: -0.02...0.02) }
        for i in rec.indices { rec[i] += Float.random(in: -0.02...0.02) }
        let profile = LatencyEstimator.NoiseProfile(noise: noise)!
        let est = LatencyEstimator.estimate(recording: rec, reference: reference, sampleRate: fs, noise: profile)!
        XCTAssertEqual(est.lag / fs, delay, accuracy: 0.0003)
        XCTAssertGreaterThan(est.peakToNoiseDb, 20)
    }

    func testRejectsPureNoise() {
        let fs = 48000.0
        let reference = TestSignals.logChirp(sampleRate: fs)
        let rec = (0..<Int(fs)).map { _ in Float.random(in: -0.1...0.1) }
        let est = LatencyEstimator.estimate(recording: rec, reference: reference, sampleRate: fs)!
        XCTAssertLessThan(est.peakToNoiseDb, 12)
    }

    /// The microphone path's delay drifts by 25 ms during an interleaved session (e.g. an iPhone over
    /// Wi-Fi); relative measurement removes the drift.
    func testDriftCancellationRemovesMicrophoneDrift() {
        var samples: [String: [DriftCancellation.Sample]] = ["wired": [], "bt": []]
        for k in 0..<6 {
            let tA = Double(k) * 1.6, tB = tA + 0.8
            let drift: (Double) -> Double = { 125 + 25 * $0 / 9.6 }   // mic delay, ms
            samples["wired"]!.append(.init(time: tA, latency: 3 + drift(tA)))
            samples["bt"]!.append(.init(time: tB, latency: 430 + drift(tB) + (k == 3 ? 9 : 0)))  // one outlier
        }
        let r = DriftCancellation.combine(samples, reference: "wired")
        XCTAssertEqual(r["bt"]!.latencyMs - r["wired"]!.latencyMs, 427, accuracy: 0.3)
        XCTAssertEqual(r["bt"]!.accepted, 5)
        XCTAssertLessThan(r["bt"]!.spreadMs, 0.5)
    }

    func testAutoEQFitsPeaksAndDips() {
        let grid = AutoEQ.grid
        let fs = 48000.0
        let room = BiquadDesign.design(.peak, frequency: 120, gainDb: 8, q: 4, sampleRate: fs)!
        let dip = BiquadDesign.design(.peak, frequency: 3000, gainDb: -5, q: 0.8, sampleRate: fs)!
        let deviation = grid.map { 20 * log10(room.magnitude(at: $0, sampleRate: fs) * dip.magnitude(at: $0, sampleRate: fs)) }
        let valid = grid.map { $0 >= 50 && $0 <= 10000 }
        let bands = AutoEQ.fit(deviation: deviation, valid: valid, maxBoostDb: 6)
        XCTAssertFalse(bands.isEmpty)
        let fitted = BiquadDesign.bands(bands, sampleRate: fs)
        let residual = grid.indices.filter { valid[$0] && grid[$0] >= 60 && grid[$0] <= 8000 }
            .map { abs(deviation[$0] + BiquadDesign.responseDb(fitted, frequency: grid[$0], sampleRate: fs)) }
        XCTAssertLessThan(residual.max()!, 2.0)
        XCTAssertTrue(bands.contains { abs($0.frequency - 120) < 15 && $0.gainDb < -6 })
    }

    /// Two outputs measured through the same coloured microphone: the microphone's colouration
    /// cancels, and each output is corrected towards the average tone.
    func testAutoEQPlanMatchesOutputsDespiteMicrophoneColouration() {
        let grid = AutoEQ.grid
        let mic = grid.map { -6 * log10($0 / 40) / log10(400) }   // tilted microphone
        let bright = BiquadDesign.design(.highShelf, frequency: 3000, gainDb: 6, q: 0.7, sampleRate: 48000)!
        let a = AutoEQ.Response(db: mic, valid: grid.map { $0 < 9000 })
        let b = AutoEQ.Response(db: grid.indices.map { mic[$0] + 20 * log10(bright.magnitude(at: grid[$0], sampleRate: 48000)) },
                                valid: grid.map { $0 < 9000 })
        let plan = AutoEQ.plan(["a": a, "b": b])
        let fb = BiquadDesign.bands(plan.perOutput["b"]!, sampleRate: 48000)
        let fa = BiquadDesign.bands(plan.perOutput["a"]!, sampleRate: 48000)
        // After correction the two outputs match within 2 dB from 100 Hz to 8 kHz.
        for (i, f) in grid.enumerated() where f >= 100 && f <= 8000 {
            let da = a.db[i] + BiquadDesign.responseDb(fa, frequency: f, sampleRate: 48000)
            let db = b.db[i] + BiquadDesign.responseDb(fb, frequency: f, sampleRate: 48000)
            XCTAssertLessThan(abs(da - db), 2.0, "at \(f) Hz")
        }
        XCTAssertTrue(plan.room.isEmpty)
    }

    /// Music-like program heard through a wired output (on time) and a Bluetooth output that drifted
    /// 17 ms late: Live Sync finds both and reports the drift.
    func testLiveSyncFindsDriftedWirelessOutput() {
        let fs = 48000.0
        let search = 0.35, window = 3.0
        // Program: filtered noise with a slow amplitude envelope and a tonal component.
        var state: UInt64 = 12345
        func rnd() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1 }
        let total = Int((window + 2 * search + 0.1) * fs)
        var program = [Float](repeating: 0, count: total)
        var lp: Float = 0
        for i in 0..<total {
            lp += 0.2 * (rnd() - lp)
            let t = Double(i) / fs
            program[i] = lp * Float(0.6 + 0.4 * sin(2 * .pi * 1.7 * t)) + 0.2 * Float(sin(2 * .pi * 220 * t))
        }
        let n = Int(window * fs)
        let start = Int(search * fs)            // the wired output arrives exactly as expected
        let drift = Int(0.017 * fs)             // Bluetooth 17 ms late
        var mic = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mic[i] = 0.5 * program[start + i] + 0.4 * program[start + i - drift] + 0.05 * rnd()
        }
        let peaks = LiveSyncAnalyzer.offsets(mic: mic, program: program, sampleRate: fs, search: search)
        let a = LiveSyncAnalyzer.assess(peaks)
        XCTAssertNotNil(a)
        XCTAssertEqual(a!.referenceOffset, 0, accuracy: 0.0005)
        XCTAssertEqual(a!.wirelessOffset ?? 0, 0.017, accuracy: 0.0005)

        // Aligned case: a single peak, no wireless offset.
        for i in 0..<n { mic[i] = 0.9 * program[start + i] + 0.05 * rnd() }
        let aligned = LiveSyncAnalyzer.assess(LiveSyncAnalyzer.offsets(mic: mic, program: program, sampleRate: fs, search: search))
        XCTAssertNotNil(aligned)
        XCTAssertNil(aligned!.wirelessOffset)
    }

    /// A rhythmic program (repeating every 77 ms) resembles itself at 77 ms; noise doesn't.
    func testSelfSimilarityDetectsRhythm() {
        let fs = 48000.0
        var state: UInt64 = 99
        func rnd() -> Float { state = state &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1 }
        let period = Int(0.077 * fs)
        let cell = (0..<period).map { _ in rnd() }
        let rhythmic = (0..<Int(4 * fs)).map { cell[$0 % period] + 0.1 * rnd() }
        let noise = (0..<Int(4 * fs)).map { _ in rnd() }
        XCTAssertGreaterThan(LiveSyncAnalyzer.selfSimilarityDb(program: rhythmic, sampleRate: fs, lags: [-0.077])[0], -6)
        XCTAssertLessThan(LiveSyncAnalyzer.selfSimilarityDb(program: noise, sampleRate: fs, lags: [-0.077])[0], -15)
    }

    func testLevelMatching() {
        let t = LevelMatching.trims(levelsDb: ["pebbles": -20, "sony": -18, "mac": -32])
        XCTAssertEqual(t["mac"]!, 6, accuracy: 1e-9)          // boosted at most 6 dB
        XCTAssertEqual(t["pebbles"]!, -6, accuracy: 1e-9)     // others cut to the boosted level
        XCTAssertEqual(t["sony"]!, -8, accuracy: 1e-9)
    }

    func testBandGainMeasuresRelativeLevel() {
        let fs = 48000.0
        let ref = TestSignals.logChirp(sampleRate: fs)
        var rec = [Float](repeating: 0, count: ref.count + 5000)
        for k in ref.indices { rec[1000 + k] = 0.25 * ref[k] }
        XCTAssertEqual(LatencyEstimator.bandGainDb(recording: rec, arrival: 1000, reference: ref, sampleRate: fs)!, 20 * log10(0.25), accuracy: 0.1)
    }

    func testRobustStats() {
        let v = [10.0, 10.1, 9.9, 10.05, 25.0]
        let inl = RobustStats.inliers(v, floor: 0.25)
        XCTAssertEqual(inl.count, 4)
        XCTAssertEqual(RobustStats.median(inl), 10.025, accuracy: 1e-9)
    }

    func testMicTimelineMapping() {
        let fs = 48000.0
        let tpf = HostTime.ticksPerSecond / fs
        let anchors = (0..<10).map { SFMicAnchor(frame: UInt64($0 * 512), host: UInt64(1_000_000 + Double($0 * 512) * tpf), rateScalar: 1) }
        let tl = MicTimeline(anchors: anchors, sampleRate: fs)
        let host = tl.hostTime(ofFrame: 2000.5)!
        XCTAssertEqual(tl.frame(atHost: host)!, 2000.5, accuracy: 0.01)
    }

    private func filter(_ x: [Float], _ cascade: [Biquad]) -> [Float] {
        var y = x
        for c in cascade {
            var s1 = 0.0, s2 = 0.0
            for i in 0..<y.count {
                let input = Double(y[i])
                let out = c.b0 * input + s1
                s1 = c.b1 * input - c.a1 * out + s2
                s2 = c.b2 * input - c.a2 * out
                y[i] = Float(out)
            }
        }
        return y
    }
}

@MainActor
final class ProfileStoreTests: XCTestCase {
    func testRoundTripAndForwardCompatibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("state.json")
        let store = ProfileStore(fileURL: url)
        var p = DeviceProfile(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: .builtIn)
        p.enabled = true
        p.volume = 0.7
        p.dsp = EQPresets.named("Music")!.settings
        p.calibration = CalibrationRecord(latencyMs: 12.3, spreadMs: 0.2, peakToNoiseDb: 30, confidence: .high,
                                          repetitions: 5, date: Date(timeIntervalSince1970: 1_700_000_000),
                                          microphoneUID: "BuiltInMicrophoneDevice", reportedLatencyMs: 3.5)
        store.replace(p)
        store.settings.masterVolume = 0.4
        store.saveNow()

        let reloaded = ProfileStore(fileURL: url)
        XCTAssertEqual(reloaded.profile(uid: p.uid), p)
        XCTAssertEqual(reloaded.settings.masterVolume, 0.4)

        // Older / partial files decode with defaults.
        let partial = #"{"settings":{"masterVolume":0.5},"profiles":{"x":{"uid":"x"}}}"#
        try partial.data(using: .utf8)!.write(to: url)
        let old = ProfileStore(fileURL: url)
        XCTAssertEqual(old.settings.masterVolume, 0.5)
        XCTAssertEqual(old.settings.baseLatencyMs, AppSettings().baseLatencyMs)
        XCTAssertEqual(old.profile(uid: "x")?.dsp, .flat)
        XCTAssertNil(old.loadError)
        try? FileManager.default.removeItem(at: dir)
    }
}
