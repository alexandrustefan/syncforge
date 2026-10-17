import CoreAudio
import XCTest
@testable import SyncForgeCore
import SyncForgeRT

@MainActor
final class EngineLifecycleTests: XCTestCase {
    func testRendererConstructionFailureStopsMutingCapture() {
        let device = outputDevice("unavailable", id: 1)
        let capture = StubCapture()
        let engine = makeEngine(devices: [device], capture: capture) { _, _ in throw Fault.output }
        defer { engine.shutdown() }

        engine.setEnabled(true)

        XCTAssertEqual(capture.starts, 1)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(capture.isRunning)
        XCTAssertNil(engine.sourceRing)
        XCTAssertTrue(engine.activeOutputUIDs.isEmpty)
        guard case .failed = engine.captureStatus else { return XCTFail("Startup failure must be visible") }
    }

    func testRendererStartFailureAlsoStopsCapture() {
        let device = outputDevice("busy", id: 2)
        let capture = StubCapture()
        let engine = makeEngine(devices: [device], capture: capture) { device, ring in
            let output = StubOutput(device: device, ring: ring)
            output.failStart = true
            return output
        }
        defer { engine.shutdown() }

        engine.setEnabled(true)

        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertTrue(engine.activeOutputUIDs.isEmpty)
    }

    func testOneFailedOutputDoesNotStopHealthyOutput() {
        let good = outputDevice("good", id: 3), bad = outputDevice("bad", id: 4)
        let capture = StubCapture()
        let engine = makeEngine(devices: [good, bad], capture: capture) { device, ring in
            if device.uid == bad.uid { throw Fault.output }
            return StubOutput(device: device, ring: ring)
        }
        defer { engine.shutdown() }

        engine.setEnabled(true)

        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(capture.stops, 0)
        XCTAssertEqual(engine.activeOutputUIDs, [good.uid])
        XCTAssertEqual(engine.outputs.first { $0.uid == good.uid }?.status, .playing)
    }

    func testRetryAfterFailureRecreatesCaptureAndStartsOutput() {
        let device = outputDevice("retry", id: 5)
        let capture = StubCapture()
        var fail = true
        let engine = makeEngine(devices: [device], capture: capture) { device, ring in
            if fail { throw Fault.output }
            return StubOutput(device: device, ring: ring)
        }
        defer { engine.shutdown() }
        engine.setEnabled(true)
        XCTAssertFalse(capture.isRunning)

        fail = false
        engine.reconcile()

        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(capture.starts, 2)
        XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(engine.outputs.first?.status, .playing)
    }

    func testHeadlessDiagnosticsKeepRealCountsAndSubMicrosecondPrecision() throws {
        let device = outputDevice("headless", id: 6)
        let capture = StubCapture()
        var output: StubOutput?
        let engine = makeEngine(devices: [device], capture: capture) { device, ring in
            let r = StubOutput(device: device, ring: ring)
            output = r
            return r
        }
        defer { engine.shutdown() }
        engine.setEnabled(true)
        let r = try XCTUnwrap(output)
        r.reading.callbacks = 12
        r.reading.peakLeft = 0.25
        r.reading.underruns = 7
        r.reading.resyncs = 3
        r.reading.servoErrorSeconds = 4.321e-6
        r.reading.locked = 1

        engine.tick()

        XCTAssertEqual(engine.meteringClients, 0)
        XCTAssertTrue(engine.meters.isEmpty, "Hidden UI must still avoid meter publication")
        let sample = try XCTUnwrap(engine.diagnostics[device.uid])
        XCTAssertEqual(sample.underruns, 7)
        XCTAssertEqual(sample.resyncs, 3)
        XCTAssertEqual(sample.peakLeft, 0.25)
        XCTAssertEqual(sample.servoErrorSeconds, 4.321e-6, accuracy: 1e-12)

        engine.meteringClients = 1
        engine.tick()
        XCTAssertEqual(engine.meters[device.uid]?.underruns, 7)
        engine.meteringClients = 0
        XCTAssertTrue(engine.meters.isEmpty)
        XCTAssertNotNil(engine.diagnostics[device.uid])
        engine.setEnabled(false)
        XCTAssertTrue(engine.diagnostics.isEmpty, "Stopped outputs must not retain stale diagnostics")
    }

    func testNoSelectedOutputsNeverStartsCapture() {
        let capture = StubCapture()
        let engine = makeEngine(devices: [], capture: capture) { _, _ in throw Fault.output }
        defer { engine.shutdown() }
        engine.setEnabled(true)
        XCTAssertEqual(capture.starts, 0)
        XCTAssertFalse(capture.isRunning)
    }

    private func makeEngine(devices: [AudioDeviceInfo], capture: StubCapture,
                            renderer: @escaping (AudioDeviceInfo, SourceRing) throws -> any AudioOutputRendering) -> SyncEngine {
        let store = ProfileStore(fileURL: nil)
        for device in devices {
            store.register(device)
            store.update(device.uid) { $0.enabled = true }
        }
        return SyncEngine(devices: AudioDeviceManager(snapshot: devices), store: store,
                          makeCapture: { capture }, makeRenderer: renderer)
    }

    private func outputDevice(_ uid: String, id: UInt32) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, uid: uid, name: uid, manufacturer: "Test", transport: .builtIn,
                        outputChannels: 2, inputChannels: 0, nominalSampleRate: 48000,
                        reportedOutputLatency: 0.01, reportedInputLatency: 0, outputSafetyOffset: 0,
                        bufferFrameSize: 512, maxBufferFrameSize: 8192, isAlive: true,
                        preferredStereo: (1, 2), outputFormatIsFloat: true, dataSourceName: nil)
    }
}

private enum Fault: Error { case output }

private final class StubCapture: SystemAudioCapturing {
    var isRunning = false
    var starts = 0, stops = 0
    func prepareTap() throws -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8,
                                    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 32, mReserved: 0)
    }
    func start(ring: SourceRing) throws { starts += 1; isRunning = true }
    func stop() { stops += 1; isRunning = false }
}

private final class StubOutput: AudioOutputRendering {
    let device: AudioDeviceInfo
    let ring: SourceRing
    var sampleRate: Double { device.nominalSampleRate }
    var isRunning = false
    var failStart = false
    var reading = SFRendererStats()
    init(device: AudioDeviceInfo, ring: SourceRing) { self.device = device; self.ring = ring }
    func start() throws { if failStart { throw Fault.output }; isRunning = true }
    func stop() { isRunning = false }
    func setParams(_ params: SFRendererParams) {}
    func playTestSignal(_ samples: [Float], timelineStart: UInt64, period: Double, repeats: UInt32, gain: Float) -> UInt32 { 1 }
    func stopTestSignal() {}
    func collectRetiredSignals() {}
    func stats(resetPeaks: Bool) -> SFRendererStats { reading }
}
