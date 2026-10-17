import CoreAudio
import Foundation
import SyncForgeRT

/// Captures the system's audio output with a Core Audio process tap (macOS 14.2+).
///
/// * The tap is global ("all processes except SyncForge"), stereo, private, and
///   `mutedWhenTapped`: while SyncForge reads it, the original playback is silenced, so audio is
///   never heard twice. SyncForge's own output is excluded, so there is no feedback loop.
/// * The tap is read through a private aggregate device that contains only the tap. Private taps
///   and aggregates belong to this process: if SyncForge quits or crashes, Core Audio removes
///   them and normal playback resumes on its own.
/// * The IOProc is C (`sf_capture_ioproc`) and writes into the shared source ring.
public final class SystemAudioCapture {
    public static let aggregateUIDPrefix = "com.syncforge.capture."

    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var format = AudioStreamBasicDescription()
    public private(set) var isRunning = false

    private var procID: AudioDeviceIOProcID?
    private var context: OpaquePointer?
    private var ring: SourceRing?
    private var tapUUID = UUID()

    public init() {}

    deinit { stop() }

    public var sampleRate: Double { format.mSampleRate }

    /// Creates the process tap and returns its stream format.
    public func prepareTap() throws -> AudioStreamBasicDescription {
        stop()
        var exclude: [AudioObjectID] = []
        if let me = CAProperty.processObject(for: getpid()) { exclude.append(me) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "SyncForge System Audio"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create system audio tap")
        tapID = tap
        guard let asbd = CAProperty.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
              asbd.mSampleRate > 0 else {
            stop()
            throw CoreAudioError(kAudioHardwareUnspecifiedError, "Read tap format")
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            stop()
            throw CoreAudioError(kAudioDeviceUnsupportedFormatError, "Tap format is not Float32")
        }
        format = asbd
        return asbd
    }

    /// Creates the private aggregate device and starts writing into `ring`.
    public func start(ring: SourceRing) throws {
        guard tapID != kAudioObjectUnknown else { throw CoreAudioError(kAudioHardwareBadObjectError, "Tap not prepared") }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SyncForge Capture",
            kAudioAggregateDeviceUIDKey: SystemAudioCapture.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Create capture aggregate device")
            aggregateID = aggregate

            let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            guard let ctx = sf_capture_create(ring.pointer, format.mChannelsPerFrame, nonInterleaved) else {
                throw CoreAudioError(kAudioHardwareUnspecifiedError, "Allocate capture context")
            }
            context = ctx
            self.ring = ring
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcID(aggregate, sf_capture_ioproc, UnsafeMutableRawPointer(ctx), &proc),
                      "Create capture IOProc")
            procID = proc
            try check(AudioDeviceStart(aggregate, proc), "Start capture")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Stops capture and destroys the tap. Safe to call repeatedly.
    public func stop() {
        if let proc = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            // After this returns the IOProc is guaranteed not to run again.
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let ctx = context {
            sf_capture_destroy(ctx)
            context = nil
        }
        ring = nil
        isRunning = false
    }
}
