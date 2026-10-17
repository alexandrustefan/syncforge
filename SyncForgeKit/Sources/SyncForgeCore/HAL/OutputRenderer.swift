import CoreAudio
import Foundation
import SyncForgeRT

/// Plays the program audio on one physical output device through its own HAL IOProc.
///
/// Every device runs on its own IO thread and its own hardware clock. The C renderer reads the
/// shared source ring at `outputHostTime - delay`, resampling to the device's rate and clock.
public final class OutputRenderer {
    public let device: AudioDeviceInfo
    public let sampleRate: Double
    let renderer: OpaquePointer
    public let ring: SourceRing

    private var procID: AudioDeviceIOProcID?
    public private(set) var isRunning = false
    public let createdAt = Date()

    public init(device: AudioDeviceInfo, ring: SourceRing) throws {
        guard device.isOutput else { throw CoreAudioError(kAudioHardwareBadDeviceError, "\(device.name) has no outputs") }
        guard device.outputFormatIsFloat else {
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "\(device.name) does not use a Float32 stream format")
        }
        self.device = device
        self.sampleRate = device.nominalSampleRate
        self.ring = ring
        let maxFrames = UInt32(max(8192, device.maxBufferFrameSize, device.bufferFrameSize * 2))
        guard let r = sf_renderer_create(ring.pointer, device.nominalSampleRate, maxFrames, HostTime.ticksPerSecond) else {
            throw CoreAudioError(kAudioHardwareUnspecifiedError, "Allocate renderer for \(device.name)")
        }
        renderer = r

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(device.id, sf_renderer_ioproc, UnsafeMutableRawPointer(r), &proc)
        guard status == noErr, let proc else {
            sf_renderer_destroy(r)
            throw CoreAudioError(status, "Create output IOProc for \(device.name)")
        }
        procID = proc
        // Never open the device's input side (e.g. a Bluetooth headset microphone).
        if device.isInput {
            try? setIOProcStreamUsage(device: device.id, procID: proc, scope: kAudioObjectPropertyScopeInput, enabled: false)
        }
    }

    deinit {
        stop()
        if let proc = procID {
            AudioDeviceDestroyIOProcID(device.id, proc)
        }
        // The IOProc is destroyed, so the renderer can no longer be referenced by the IO thread.
        sf_renderer_destroy(renderer)
    }

    public func start() throws {
        guard !isRunning, let proc = procID else { return }
        try check(AudioDeviceStart(device.id, proc), "Start output \(device.name)")
        isRunning = true
    }

    public func stop() {
        guard isRunning, let proc = procID else { return }
        AudioDeviceStop(device.id, proc)
        isRunning = false
    }

    public func setParams(_ params: SFRendererParams) {
        var p = params
        sf_renderer_set_params(renderer, &p)
    }

    // MARK: Test signals
    //
    // The C renderer only holds a raw pointer to the samples. A buffer is retired when it is
    // replaced and freed only once the IO thread has acknowledged the replacement (or the IOProc
    // has been destroyed), so the IO thread can never read freed memory.

    private var currentSignal: SignalBuffer?
    private var retiredSignals: [(ack: UInt32, buffer: SignalBuffer)] = []
    private var nextSignalID: UInt32 = 0

    /// Plays `samples` (mono, at the device rate) on the program timeline starting at
    /// `timelineStart`, optionally repeating every `period` seconds `repeats` times (0 = forever).
    @discardableResult
    public func playTestSignal(_ samples: [Float], timelineStart: UInt64, period: Double = 0,
                               repeats: UInt32 = 1, gain: Float) -> UInt32 {
        let buffer = SignalBuffer(samples)
        nextSignalID &+= 1
        var s = SFTestSignal()
        s.samples = UnsafePointer(buffer.pointer)
        s.length = UInt32(samples.count)
        s.sampleRate = sampleRate
        s.startTimelineHost = timelineStart
        s.periodTicks = period > 0 ? UInt64(HostTime.ticks(period)) : 0
        s.repeatCount = period > 0 ? repeats : 0
        s.gain = gain
        s.identifier = nextSignalID
        s.active = 1
        sf_renderer_set_test_signal(renderer, &s)
        retire(newAck: nextSignalID)
        currentSignal = buffer
        return nextSignalID
    }

    public func stopTestSignal() {
        nextSignalID &+= 1
        var s = SFTestSignal()
        s.identifier = nextSignalID
        sf_renderer_set_test_signal(renderer, &s)
        retire(newAck: nextSignalID)
        currentSignal = nil
    }

    private func retire(newAck: UInt32) {
        if let old = currentSignal { retiredSignals.append((newAck, old)) }
        collectRetiredSignals()
    }

    /// Frees retired test-signal buffers the IO thread no longer references.
    public func collectRetiredSignals() {
        let ack = sf_renderer_test_ack(renderer)
        retiredSignals.removeAll { entry in Int32(bitPattern: ack &- entry.ack) >= 0 }
    }

    public var testAck: UInt32 { sf_renderer_test_ack(renderer) }

    public func stats(resetPeaks: Bool) -> SFRendererStats {
        var s = SFRendererStats()
        sf_renderer_get_stats(renderer, &s, resetPeaks)
        return s
    }
}

/// Owns sample memory handed to the C renderer.
final class SignalBuffer {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    init(_ samples: [Float]) {
        count = max(1, samples.count)
        pointer = .allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { pointer.update(from: base, count: samples.count) }
        }
    }
    deinit { pointer.deallocate() }
}

/// Records a microphone through its own HAL IOProc with timestamps (used for calibration only).
public final class MicrophoneRecorder {
    public let device: AudioDeviceInfo
    public let sampleRate: Double
    let mic: OpaquePointer
    private var procID: AudioDeviceIOProcID?
    public private(set) var isRunning = false

    public init(device: AudioDeviceInfo, capacitySeconds: Double = 120, channel: Int32 = -1) throws {
        guard device.isInput else { throw CoreAudioError(kAudioHardwareBadDeviceError, "\(device.name) has no inputs") }
        self.device = device
        self.sampleRate = device.nominalSampleRate
        let capacity = UInt32(device.nominalSampleRate * capacitySeconds)
        guard let m = sf_mic_create(capacity, 1 << 16) else {
            throw CoreAudioError(kAudioHardwareUnspecifiedError, "Allocate microphone buffer")
        }
        mic = m
        sf_mic_set_channel(m, channel)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(device.id, sf_mic_ioproc, UnsafeMutableRawPointer(m), &proc)
        guard status == noErr, let proc else {
            sf_mic_destroy(m)
            throw CoreAudioError(status, "Create microphone IOProc for \(device.name)")
        }
        procID = proc
        if device.isOutput {
            try? setIOProcStreamUsage(device: device.id, procID: proc, scope: kAudioObjectPropertyScopeOutput, enabled: false)
        }
    }

    deinit {
        stop()
        if let proc = procID { AudioDeviceDestroyIOProcID(device.id, proc) }
        sf_mic_destroy(mic)
    }

    public func start() throws {
        guard !isRunning, let proc = procID else { return }
        try check(AudioDeviceStart(device.id, proc), "Start microphone \(device.name)")
        isRunning = true
    }

    public func stop() {
        guard isRunning, let proc = procID else { return }
        AudioDeviceStop(device.id, proc)
        isRunning = false
    }

    public func setArmed(_ armed: Bool) { sf_mic_set_armed(mic, armed) }
    public func reset() { sf_mic_reset(mic) }
    public var frameCount: Int { Int(sf_mic_frames(mic)) }
    public var callbacks: UInt64 { sf_mic_callbacks(mic) }
    public func peak(reset: Bool) -> Float { sf_mic_peak(mic, reset) }

    /// Input latency between the acoustic event and the IO time stamp, as reported by the driver.
    public var reportedLatency: Double { device.reportedInputLatency }

    /// Copies recorded samples in `range` (clamped to what has been recorded).
    public func samples(_ range: Range<Int>) -> [Float] {
        let n = frameCount
        let lo = max(0, range.lowerBound), hi = min(n, range.upperBound)
        guard hi > lo, let base = sf_mic_data(mic) else { return [] }
        return Array(UnsafeBufferPointer(start: base + lo, count: hi - lo))
    }

    /// Snapshot of the frame <-> host time anchors recorded so far.
    public func timeline() -> MicTimeline {
        let count = Int(sf_mic_anchor_count(mic))
        guard count > 0, let base = sf_mic_anchors(mic) else { return MicTimeline(anchors: [], sampleRate: sampleRate) }
        return MicTimeline(anchors: Array(UnsafeBufferPointer(start: base, count: count)), sampleRate: sampleRate)
    }
}

/// Maps microphone frame indices to host time and back, using per-buffer Core Audio time stamps.
public struct MicTimeline {
    public let anchors: [SFMicAnchor]
    public let sampleRate: Double

    public init(anchors: [SFMicAnchor], sampleRate: Double) {
        self.anchors = anchors
        self.sampleRate = sampleRate
    }

    private func ticksPerFrame(_ a: SFMicAnchor) -> Double {
        let rs = a.rateScalar > 0.5 && a.rateScalar < 2 ? a.rateScalar : 1
        return HostTime.ticksPerSecond * rs / sampleRate
    }

    /// Host time at which (fractional) frame `frame` was captured at the hardware.
    public func hostTime(ofFrame frame: Double) -> Double? {
        guard !anchors.isEmpty else { return nil }
        var lo = 0, hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(anchors[mid].frame) <= frame { lo = mid } else { hi = mid - 1 }
        }
        let a = anchors[lo]
        return Double(a.host) + (frame - Double(a.frame)) * ticksPerFrame(a)
    }

    /// Frame index captured at host time `host`.
    public func frame(atHost host: Double) -> Double? {
        guard !anchors.isEmpty else { return nil }
        var lo = 0, hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(anchors[mid].host) <= host { lo = mid } else { hi = mid - 1 }
        }
        let a = anchors[lo]
        return Double(a.frame) + (host - Double(a.host)) / ticksPerFrame(a)
    }
}
