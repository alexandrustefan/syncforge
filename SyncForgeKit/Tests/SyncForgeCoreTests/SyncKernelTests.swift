import XCTest
@testable import SyncForgeCore
import SyncForgeRT

/// Simulation tests of the real-time kernel (no audio hardware involved).
final class SyncKernelTests: XCTestCase {
    /// A single output at the source rate reproduces the program exactly delayed (test A, simulated).
    func testDelayedPlaybackMatchesProgram() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.25 }
        sim.run(seconds: 3)
        let snr = sim.snr(o, delay: 0.25, from: sim.nowSeconds - 2, to: sim.nowSeconds)
        XCTAssertGreaterThan(snr, 70, "SNR \(snr) dB")
        XCTAssertEqual(sim.stats(o).underruns, 0)
    }

    /// Two outputs with different delays each match their own delay (test B, simulated).
    func testIndependentDelaysAndVolumes() {
        let sim = ClockSimulation(signal: multiTone)
        let a = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.05 }
        let b = sim.addOutput(rate: 48000, bufferFrames: 256) { $0.delaySeconds = 0.80; $0.gain = 0.5 }
        sim.run(seconds: 3)
        let t1 = sim.nowSeconds
        XCTAssertGreaterThan(sim.snr(a, delay: 0.05, from: t1 - 1.5, to: t1), 70)
        // b plays at half gain: compare against scaled ideal.
        var sig = 0.0, err = 0.0
        for (host, l, _) in sim.outputs[b].recorded where host / sim.tps > t1 - 1.5 {
            let ideal = 0.5 * Double(multiTone(host / sim.tps - 0.80).0)
            sig += ideal * ideal
            err += (Double(l) - ideal) * (Double(l) - ideal)
        }
        XCTAssertGreaterThan(10 * log10(sig / err), 70)
    }

    /// 48 kHz program to a 44.1 kHz device (e.g. a Bluetooth speaker).
    func testSampleRateConversion() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 44100) { $0.delaySeconds = 0.1 }
        sim.run(seconds: 4)
        let snr = sim.snr(o, delay: 0.1, from: sim.nowSeconds - 2, to: sim.nowSeconds)
        XCTAssertGreaterThan(snr, 60, "SNR \(snr) dB")
    }

    /// Test E: clocks that disagree by hundreds of ppm stay locked to the programmed delay over a
    /// long run; the error does not grow with time.
    func testClockDriftDoesNotAccumulate() {
        let sim = ClockSimulation(sourcePPM: 150, signal: multiTone)
        let fast = sim.addOutput(rate: 48000, ppm: 250) { $0.delaySeconds = 0.3 }
        let slow = sim.addOutput(rate: 44100, ppm: -300, bufferFrames: 1024) { $0.delaySeconds = 0.3 }
        sim.outputs[fast].record = false
        sim.outputs[slow].record = false
        sim.run(seconds: 30)
        var early: [Double] = []
        for (i, o) in [fast, slow].enumerated() {
            sim.outputs[o].record = true
            _ = i
        }
        sim.run(seconds: 3)
        let t = sim.nowSeconds
        early = [sim.snr(fast, delay: 0.3, from: t - 2, to: t), sim.snr(slow, delay: 0.3, from: t - 2, to: t)]
        for o in [fast, slow] { sim.outputs[o].recorded.removeAll(); sim.outputs[o].record = false }
        sim.run(seconds: 240)
        for o in [fast, slow] { sim.outputs[o].record = true }
        sim.run(seconds: 3)
        let t2 = sim.nowSeconds
        let late = [sim.snr(fast, delay: 0.3, from: t2 - 2, to: t2), sim.snr(slow, delay: 0.3, from: t2 - 2, to: t2)]
        for (e, l) in zip(early, late) {
            XCTAssertGreaterThan(e, 55, "early SNR \(e)")
            XCTAssertGreaterThan(l, 55, "late SNR \(l)")
        }
        for o in [fast, slow] {
            let s = sim.stats(o)
            XCTAssertLessThan(abs(s.servoErrorSeconds), 20e-6, "servo error \(s.servoErrorSeconds)")
            XCTAssertEqual(s.underruns, 0)
            XCTAssertEqual(s.resyncs, 0)
        }
    }

    /// A large delay change crossfades (no hard discontinuity) and settles on the new delay.
    func testDelayChangeCrossfadesWithoutClicks() {
        // A single low tone makes discontinuities easy to detect via the sample-to-sample step.
        let tone: (Double) -> (Float, Float) = { t in let v = Float(0.5 * sin(2 * .pi * 200 * t)); return (v, v) }
        let sim = ClockSimulation(signal: tone)
        let o = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.1 }
        sim.run(seconds: 1)
        sim.outputs[o].recorded.removeAll()
        sim.setParams(o) { $0.delaySeconds = 0.4637 }
        sim.run(seconds: 2)
        let samples = sim.outputs[o].recorded.map { $0.1 }
        let maxNaturalStep = Float(0.5 * 2 * Double.pi * 200 / 48000)
        var maxStep: Float = 0
        for i in 1..<samples.count { maxStep = max(maxStep, abs(samples[i] - samples[i - 1])) }
        XCTAssertLessThan(maxStep, maxNaturalStep * 3, "click detected: step \(maxStep)")
        XCTAssertEqual(sim.stats(o).resyncs, 1)
        let t = sim.nowSeconds
        XCTAssertGreaterThan(sim.snr(o, delay: 0.4637, from: t - 1, to: t), 70)
    }

    /// Small adjustments (fine tuning) slew smoothly instead of jumping, and converge.
    func testFineDelayAdjustmentSlews() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.2 }
        sim.run(seconds: 1)
        sim.setParams(o) { $0.delaySeconds = 0.2015 }
        sim.outputs[o].recorded.removeAll()
        sim.run(seconds: 2)
        // Within 2 s the error is below 50 µs ...
        XCTAssertLessThan(abs(sim.stats(o).servoErrorSeconds), 50e-6)
        sim.run(seconds: 4)
        XCTAssertEqual(sim.stats(o).resyncs, 0)
        let t = sim.nowSeconds
        XCTAssertGreaterThan(sim.snr(o, delay: 0.2015, from: t - 1, to: t), 60) // ... and converges completely
        // The slew never exceeds the 0.2 % limit (about 3.5 cents).
        XCTAssertLessThanOrEqual(abs(sim.stats(o).correctionPPM), 2000.001)
    }

    /// Asking for data that has not been captured yet produces silence and counts an underrun.
    func testUnderrunWhenDelayTooSmall() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 48000, lead: 0.012) { $0.delaySeconds = 0.0 }
        sim.run(seconds: 1)
        XCTAssertGreaterThan(sim.stats(o).underruns, 0)
    }

    /// Regression: a delay jump while the old read position is unreadable (underrun, e.g. after a
    /// Bluetooth hiccup) must not leave the output stuck in an endless crossfade of silence.
    func testRecoversWhenJumpingFromUnreadablePosition() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 44100) { $0.delaySeconds = 0.0 }   // permanently underrunning
        sim.run(seconds: 1)
        XCTAssertGreaterThan(sim.stats(o).underruns, 0)
        sim.setParams(o) { $0.delaySeconds = 0.3 }
        sim.outputs[o].recorded.removeAll()
        sim.run(seconds: 2)
        let t = sim.nowSeconds
        XCTAssertGreaterThan(sim.snr(o, delay: 0.3, from: t - 1, to: t), 60, "output did not recover")
    }

    /// Test G: one output's EQ does not affect another output.
    func testEqualizerIsIndependentPerOutput() {
        let tone: (Double) -> (Float, Float) = { t in let v = Float(0.2 * sin(2 * .pi * 1000 * t)); return (v, v) }
        let sim = ClockSimulation(signal: tone)
        let boost = BiquadDesign.design(.peak, frequency: 1000, gainDb: 6, q: 1, sampleRate: 48000)!
        let eq = sim.addOutput(rate: 48000) { p in
            p.delaySeconds = 0.1
            p.dspEnabled = 1
            p.numBiquads = 1
            sf_params_set_biquad(&p, 0, boost.b0, boost.b1, boost.b2, boost.a1, boost.a2)
        }
        let flat = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.1 }
        sim.run(seconds: 2)
        func rms(_ i: Int) -> Double {
            let tail = sim.outputs[i].recorded.suffix(24000)
            return (tail.reduce(0) { $0 + Double($1.1) * Double($1.1) } / Double(tail.count)).squareRoot()
        }
        let ratioDb = 20 * log10(rms(eq) / rms(flat))
        XCTAssertEqual(ratioDb, 6, accuracy: 0.1)
        XCTAssertEqual(20 * log10(rms(flat) / (0.2 / 2.0.squareRoot())), 0, accuracy: 0.05)
    }

    /// The limiter keeps peaks under its ceiling even with excessive gain.
    func testLimiterPreventsClipping() {
        let tone: (Double) -> (Float, Float) = { t in let v = Float(0.8 * sin(2 * .pi * 300 * t)); return (v, v) }
        let sim = ClockSimulation(signal: tone)
        let o = sim.addOutput(rate: 48000) { p in
            p.delaySeconds = 0.1
            p.gain = 4
            p.limiterEnabled = 1
            p.limiterCeiling = 0.9
        }
        sim.run(seconds: 2)
        let peak = sim.outputs[o].recorded.map { abs($0.1) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.9001)
        XCTAssertEqual(sim.stats(o).clippedFrames, 0)
    }

    /// Program mute and test signal: the test signal appears exactly `delay` after its timeline time.
    func testTestSignalTimingFollowsTimeline() {
        let sim = ClockSimulation(signal: multiTone)
        let delay = 0.3372
        let o = sim.addOutput(rate: 44100) { p in
            p.delaySeconds = delay
            p.programMuted = 1
        }
        sim.run(seconds: 0.5)
        // A single-sample impulse at a known timeline instant.
        let impulse = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        impulse.pointee = 1
        defer { impulse.deallocate() }
        let startHost = sim.time + 0.2 * sim.tps
        var t = SFTestSignal()
        t.samples = UnsafePointer(impulse)
        t.length = 1
        t.sampleRate = 44100
        t.startTimelineHost = UInt64(startHost)
        t.gain = 1
        t.identifier = 7
        t.active = 1
        sf_renderer_set_test_signal(sim.outputs[o].renderer, &t)
        sim.outputs[o].recorded.removeAll()
        sim.run(seconds: 1.0)
        // Program is muted (after the gain smoother settles), so the largest sample is the impulse.
        let peak = sim.outputs[o].recorded.max { abs($0.1) < abs($1.1) }!
        let expected = (startHost + delay * sim.tps) / sim.tps
        XCTAssertEqual(peak.0 / sim.tps, expected, accuracy: 1.0 / 44100)
        XCTAssertEqual(sf_renderer_test_ack(sim.outputs[o].renderer), 7)
    }

    /// Capture restarts (gaps in host time) keep the timeline continuous: outputs keep their delay.
    func testCaptureGapKeepsTimelineContinuous() {
        let sim = ClockSimulation(signal: multiTone)
        let o = sim.addOutput(rate: 48000) { $0.delaySeconds = 0.5 }
        sim.run(seconds: 2)
        // Simulate a 150 ms capture outage.
        sim.captureNextHost += 0.15 * sim.tps
        sim.outputs[o].recorded.removeAll()
        sim.run(seconds: 3)
        let t = sim.nowSeconds
        XCTAssertGreaterThan(sim.snr(o, delay: 0.5, from: t - 1.5, to: t), 70)
        XCTAssertEqual(sim.stats(o).resyncs, 0)
        var cs = SFCaptureStats()
        sf_ring_get_stats(sim.ring.pointer, &cs, false)
        XCTAssertEqual(cs.gapsFilled, 1)
    }
}
