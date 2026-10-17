import CoreAudio
import SyncForgeRT

/// The output operations used by the coordinator and calibration. Keeping the HAL lifecycle
/// behind this interface lets failure and recovery paths run without opening an audio device.
public protocol AudioOutputRendering: AnyObject {
    var device: AudioDeviceInfo { get }
    var sampleRate: Double { get }
    var ring: SourceRing { get }
    var isRunning: Bool { get }
    func start() throws
    func stop()
    func setParams(_ params: SFRendererParams)
    @discardableResult
    func playTestSignal(_ samples: [Float], timelineStart: UInt64, period: Double,
                        repeats: UInt32, gain: Float) -> UInt32
    func stopTestSignal()
    func collectRetiredSignals()
    func stats(resetPeaks: Bool) -> SFRendererStats
}

extension AudioOutputRendering {
    @discardableResult
    public func playTestSignal(_ samples: [Float], timelineStart: UInt64, gain: Float) -> UInt32 {
        playTestSignal(samples, timelineStart: timelineStart, period: 0, repeats: 1, gain: gain)
    }
}

protocol SystemAudioCapturing: AnyObject {
    var isRunning: Bool { get }
    func prepareTap() throws -> AudioStreamBasicDescription
    func start(ring: SourceRing) throws
    func stop()
}

extension OutputRenderer: AudioOutputRendering {}
extension SystemAudioCapture: SystemAudioCapturing {}
