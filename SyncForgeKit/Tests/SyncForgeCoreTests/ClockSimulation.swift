import CoreAudio
import Foundation
@testable import SyncForgeCore
import SyncForgeRT

/// Deterministic simulation of one capture clock and several output clocks driving the real C
/// kernel with synthetic Core Audio time stamps. No audio hardware is involved.
final class ClockSimulation {
    struct Output {
        let renderer: OpaquePointer
        let nominalRate: Double
        let actualRate: Double
        let bufferFrames: Int
        let outputLead: Double      // seconds between the IO cycle and the presented time stamp
        var nextHost: Double        // host ticks of next buffer's first frame (presentation)
        var cycle = 0
        /// Captured output: (presentation host time of frame, left sample, right sample).
        var recorded: [(Double, Float, Float)] = []
        var record = true
    }

    let tps = HostTime.ticksPerSecond
    let ring: SourceRing
    let sourceNominal: Double
    let sourceActual: Double
    let captureFrames: Int
    var captureNextHost: Double
    var captureFrameIndex = 0
    var outputs: [Output] = []
    /// Program signal as a function of capture host time (seconds).
    var signal: (Double) -> (Float, Float)
    var time: Double  // host ticks

    init(sourceRate: Double = 48000, sourcePPM: Double = 0, captureFrames: Int = 512,
         ringSeconds: Double = 8, signal: @escaping (Double) -> (Float, Float)) {
        sourceNominal = sourceRate
        sourceActual = sourceRate * (1 + sourcePPM * 1e-6)
        self.captureFrames = captureFrames
        ring = SourceRing(sampleRate: sourceRate, seconds: ringSeconds)!
        self.signal = signal
        time = 1_000 * HostTime.ticksPerSecond
        captureNextHost = time
    }

    deinit {
        for o in outputs { sf_renderer_destroy(o.renderer) }
    }

    @discardableResult
    func addOutput(rate: Double, ppm: Double = 0, bufferFrames: Int = 512, lead: Double = 0.012,
                   configure: (inout SFRendererParams) -> Void = { _ in }) -> Int {
        let r = sf_renderer_create(ring.pointer, rate, 8192, tps)!
        var p = SFRendererParams()
        sf_params_init(&p)
        p.fadeInSeconds = 0.001
        configure(&p)
        sf_renderer_set_params(r, &p)
        outputs.append(Output(renderer: r, nominalRate: rate, actualRate: rate * (1 + ppm * 1e-6),
                              bufferFrames: bufferFrames, outputLead: lead, nextHost: time + lead * tps))
        return outputs.count - 1
    }

    func setParams(_ index: Int, _ configure: (inout SFRendererParams) -> Void) {
        var p = SFRendererParams()
        sf_params_init(&p)
        p.fadeInSeconds = 0.001
        configure(&p)
        sf_renderer_set_params(outputs[index].renderer, &p)
    }

    func stats(_ index: Int) -> SFRendererStats {
        var s = SFRendererStats()
        sf_renderer_get_stats(outputs[index].renderer, &s, false)
        return s
    }

    /// Advances simulated time, delivering capture and output callbacks in host-time order.
    func run(seconds: Double) {
        let end = time + seconds * tps
        var left = [Float](repeating: 0, count: captureFrames)
        var right = [Float](repeating: 0, count: captureFrames)
        while true {
            // Capture callback fires when its buffer is complete (+1 ms delivery delay).
            let captureDue = captureNextHost + Double(captureFrames) / sourceActual * tps + 0.001 * tps
            var nextOut = -1
            var outDue = Double.infinity
            for (i, o) in outputs.enumerated() {
                let due = o.nextHost - o.outputLead * tps
                if due < outDue { outDue = due; nextOut = i }
            }
            let due = min(captureDue, outDue)
            if due > end { break }
            time = due
            if captureDue <= outDue {
                let ticksPerFrame = tps / sourceActual
                let stamp = captureNextHost.rounded()
                for j in 0..<captureFrames {
                    let (l, r) = signal((stamp + Double(j) * ticksPerFrame) / tps)
                    left[j] = l
                    right[j] = r
                }
                let rs = sourceNominal / sourceActual
                sf_ring_write(ring.pointer, left, right, 1, UInt32(captureFrames), UInt64(stamp), rs)
                captureNextHost += Double(captureFrames) * ticksPerFrame
                captureFrameIndex += captureFrames
            } else {
                render(nextOut)
            }
        }
    }

    private func render(_ i: Int) {
        let n = outputs[i].bufferFrames
        var data = [Float](repeating: 0, count: n * 2)
        let host = outputs[i].nextHost.rounded()
        let rs = outputs[i].nominalRate / outputs[i].actualRate
        data.withUnsafeMutableBufferPointer { buf in
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(n * 8), mData: UnsafeMutableRawPointer(buf.baseAddress!)))
            sf_renderer_render(outputs[i].renderer, &abl, UInt32(n), UInt64(host), rs)
        }
        let ticksPerFrame = tps / outputs[i].actualRate
        if outputs[i].record {
            for j in 0..<n {
                outputs[i].recorded.append((host + Double(j) * ticksPerFrame, data[2 * j], data[2 * j + 1]))
            }
        }
        outputs[i].nextHost += Double(n) * ticksPerFrame
        outputs[i].cycle += 1
    }

    /// Compares an output against the ideal program delayed by `delay` seconds over a time range.
    /// Returns the signal-to-error ratio in dB.
    func snr(_ i: Int, delay: Double, from: Double, to: Double) -> Double {
        var sig = 0.0, err = 0.0
        for (host, l, _) in outputs[i].recorded {
            let t = host / tps
            guard t >= from, t <= to else { continue }
            let ideal = Double(signal(t - delay).0)
            sig += ideal * ideal
            err += (Double(l) - ideal) * (Double(l) - ideal)
        }
        return 10 * log10(sig / max(err, 1e-30))
    }

    var nowSeconds: Double { time / tps }
}

/// Band-limited multi-tone test program.
func multiTone(_ t: Double) -> (Float, Float) {
    let v = 0.25 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 1234.5 * t + 1) + 0.15 * sin(2 * .pi * 5003 * t + 2)
        + 0.1 * sin(2 * .pi * 11017 * t + 0.5)
    return (Float(v), Float(-v))
}
