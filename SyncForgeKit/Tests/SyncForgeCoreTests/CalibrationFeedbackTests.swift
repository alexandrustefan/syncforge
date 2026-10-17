import XCTest
@testable import SyncForgeCore
import SyncForgeRT

final class CalibrationFeedbackTests: XCTestCase {
    private let fs = 48000.0

    func testKnownDigitalEQIsRemovedWithoutRemovingSpeakerResponse() throws {
        let speaker = [try XCTUnwrap(BiquadDesign.design(.peak, frequency: 1000, gainDb: 6, q: 1, sampleRate: fs))]
        let userAndOldCorrection = [
            try XCTUnwrap(BiquadDesign.design(.lowShelf, frequency: 400, gainDb: 5, q: 0.7, sampleRate: fs)),
            try XCTUnwrap(BiquadDesign.design(.peak, frequency: 1000, gainDb: -3, q: 1, sampleRate: fs)),
            try XCTUnwrap(BiquadDesign.design(.highShelf, frequency: 3500, gainDb: 3, q: 0.7, sampleRate: fs)),
        ]
        let flatProcessing = try measure(speaker: speaker, processing: [])
        let equalized = try measure(speaker: speaker, processing: userAndOldCorrection)
        for (i, f) in AutoEQ.grid.enumerated() where f >= 100 && f <= 8000 {
            XCTAssertTrue(equalized.valid[i])
            XCTAssertEqual(equalized.db[i], flatProcessing.db[i], accuracy: 0.25, "at \(f) Hz")
        }
        let centre = AutoEQ.grid.indices.min { abs(AutoEQ.grid[$0] - 1000) < abs(AutoEQ.grid[$1] - 1000) }!
        let bass = AutoEQ.grid.indices.min { abs(AutoEQ.grid[$0] - 150) < abs(AutoEQ.grid[$1] - 150) }!
        XCTAssertGreaterThan(equalized.db[centre] - equalized.db[bass], 5, "Physical speaker colour must survive de-embedding")
    }

    func testRepeatedCalibrationKeepsCorrectionInsteadOfOscillating() throws {
        let speakerA = [try XCTUnwrap(BiquadDesign.design(.peak, frequency: 1000, gainDb: 6, q: 1, sampleRate: fs))]
        let system = [try XCTUnwrap(BiquadDesign.design(.highShelf, frequency: 3000, gainDb: 3, q: 0.7, sampleRate: fs))]
        let userA = [try XCTUnwrap(BiquadDesign.design(.lowShelf, frequency: 300, gainDb: 4, q: 0.7, sampleRate: fs))]
        var correctionsA: [Biquad] = [], correctionsB: [Biquad] = []
        var firstA: [Biquad] = [], firstB: [Biquad] = []
        for pass in 0..<3 {
            let a = try measure(speaker: speakerA, processing: system + userA + correctionsA)
            let b = try measure(speaker: [], processing: system + correctionsB)
            let plan = AutoEQ.plan(["a": a, "b": b])
            correctionsA = BiquadDesign.bands(plan.perOutput["a"] ?? [], sampleRate: fs)
            correctionsB = BiquadDesign.bands(plan.perOutput["b"] ?? [], sampleRate: fs)
            XCTAssertFalse(correctionsA.isEmpty)
            if pass == 0 { firstA = correctionsA; firstB = correctionsB }
            for f in [150.0, 400, 1000, 3000, 7000] {
                XCTAssertEqual(BiquadDesign.responseDb(correctionsA, frequency: f, sampleRate: fs),
                               BiquadDesign.responseDb(firstA, frequency: f, sampleRate: fs), accuracy: 0.3)
                XCTAssertEqual(BiquadDesign.responseDb(correctionsB, frequency: f, sampleRate: fs),
                               BiquadDesign.responseDb(firstB, frequency: f, sampleRate: fs), accuracy: 0.3)
            }
        }
        let mismatch = BiquadDesign.responseDb(speakerA + correctionsA, frequency: 1000, sampleRate: fs)
            - BiquadDesign.responseDb(correctionsB, frequency: 1000, sampleRate: fs)
        XCTAssertLessThan(abs(mismatch), 5, "Repeated measurements must retain the initial improvement")
    }

    func testDigitalResponseUsesOutputRateWhenMicrophoneRateDiffers() throws {
        let outputRate = 44100.0
        let processing = [try XCTUnwrap(BiquadDesign.design(.highShelf, frequency: 3500,
                                                          gainDb: 6, q: 0.7, sampleRate: outputRate))]
        let baseline = try measure(speaker: [], processing: [], outputRate: outputRate)
        let corrected = try measure(speaker: [], processing: processing, outputRate: outputRate)
        for (i, f) in AutoEQ.grid.enumerated() where f >= 100 && f <= 8000 {
            XCTAssertTrue(corrected.valid[i])
            XCTAssertEqual(corrected.db[i], baseline.db[i], accuracy: 0.2, "at \(f) Hz")
        }
    }

    func testDeepDigitalStopbandIsNotInventedAsSpeakerResponse() throws {
        let processing = BiquadDesign.passFilter(PassFilter(enabled: true, frequency: 300, slope: .db48),
                                                  highPass: false, sampleRate: fs)
        let response = try measure(speaker: [], processing: processing)
        let bass = AutoEQ.grid.indices.min { abs(AutoEQ.grid[$0] - 150) < abs(AutoEQ.grid[$1] - 150) }!
        let treble = AutoEQ.grid.indices.min { abs(AutoEQ.grid[$0] - 4000) < abs(AutoEQ.grid[$1] - 4000) }!
        XCTAssertTrue(response.valid[bass])
        XCTAssertFalse(response.valid[treble], "A digitally suppressed band is unobservable")
        XCTAssertTrue(response.db.allSatisfy(\.isFinite))
    }

    /// Sends the real chirp through the C test-signal/filter path. The extra cascade models the
    /// physical speaker, which must remain in the response after the known software EQ is removed.
    private func measure(speaker: [Biquad], processing: [Biquad], outputRate: Double = 48000) throws -> AutoEQ.Response {
        let sim = ClockSimulation(signal: { _ in (0, 0) })
        let cascade = processing + speaker
        let output = sim.addOutput(rate: outputRate) { p in
            p.delaySeconds = 0.1
            p.programMuted = 1
            p.dspEnabled = cascade.isEmpty ? 0 : 1
            p.numBiquads = Int32(cascade.count)
            p.limiterEnabled = 0
            for (i, bq) in cascade.enumerated() {
                sf_params_set_biquad(&p, Int32(i), bq.b0, bq.b1, bq.b2, bq.a1, bq.a2)
            }
        }
        let reference = TestSignals.logChirp(sampleRate: fs)
        let emitted = TestSignals.logChirp(sampleRate: outputRate)
        let start = UInt64((sim.time + 0.2 * sim.tps).rounded())
        emitted.withUnsafeBufferPointer { samples in
            var signal = SFTestSignal()
            signal.samples = samples.baseAddress
            signal.length = UInt32(samples.count)
            signal.sampleRate = outputRate
            signal.startTimelineHost = start
            signal.gain = 0.05
            signal.identifier = 1
            signal.active = 1
            sf_renderer_set_test_signal(sim.outputs[output].renderer, &signal)
            sim.run(seconds: 1)
        }
        let recorded = sim.outputs[output].recorded
        let firstHost = try XCTUnwrap(recorded.first?.0)
        let arrival = Int(((Double(start) + 0.1 * sim.tps - firstHost) / sim.tps * fs).rounded())
        // A synthetic 48 kHz microphone samples the device's output. Comparing against the same
        // conversion without software EQ cancels this test resampler's own frequency response.
        let mic = (0..<Int(Double(recorded.count - 1) * fs / outputRate)).map { i -> Float in
            let position = Double(i) * outputRate / fs
            let k = Int(position), fraction = Float(position - Double(k))
            return recorded[k].1 * (1 - fraction) + recorded[k + 1].1 * fraction
        }
        return try XCTUnwrap(AutoEQ.response(recording: mic, arrival: arrival,
                                             reference: reference, sampleRate: fs, noise: nil, sweepBand: 60...10000,
                                             processing: processing, processingSampleRate: outputRate))
    }
}
