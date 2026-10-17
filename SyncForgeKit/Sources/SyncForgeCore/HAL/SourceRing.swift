import Foundation
import SyncForgeRT

/// Owns the C source ring shared by the capture IOProc and all output renderers. Capture and every
/// renderer hold a strong reference, so the ring outlives every IOProc that may touch it.
public final class SourceRing {
    let pointer: OpaquePointer
    public let sampleRate: Double
    public let capacityFrames: Int

    public init?(sampleRate: Double, seconds: Double) {
        guard let p = sf_ring_create(UInt32(min(Double(1 << 26), sampleRate * seconds)), sampleRate, HostTime.ticksPerSecond) else {
            return nil
        }
        pointer = p
        self.sampleRate = sampleRate
        capacityFrames = Int(sf_ring_capacity(p))
    }

    deinit { sf_ring_destroy(pointer) }

    public var capacitySeconds: Double { Double(capacityFrames) / sampleRate }

    public func stats(resetPeak: Bool) -> SFCaptureStats {
        var s = SFCaptureStats()
        sf_ring_get_stats(pointer, &s, resetPeak)
        return s
    }

    public func timeline() -> SFTimeline? {
        var t = SFTimeline()
        return sf_ring_get_timeline(pointer, &t) && t.valid != 0 ? t : nil
    }

    public func requestReanchor() { sf_ring_request_reanchor(pointer) }

    /// Copies program audio (mono) for the program-timeline interval starting at host time `host`.
    /// Returns nil if it is not (or no longer) in the buffer.
    public func programAudio(fromHost host: Double, seconds: Double) -> [Float]? {
        guard let tl = timeline() else { return nil }
        let start = Double(tl.anchorFrame) + (host - Double(tl.anchorHost)) * tl.framesPerTick
        let count = Int(seconds * sampleRate)
        guard count > 0, start.isFinite else { return nil }
        var out = [Float](repeating: 0, count: count)
        let ok = out.withUnsafeMutableBufferPointer { sf_ring_copy_mono(pointer, Int64(start.rounded()), UInt32(count), $0.baseAddress!) }
        return ok ? out : nil
    }
}
