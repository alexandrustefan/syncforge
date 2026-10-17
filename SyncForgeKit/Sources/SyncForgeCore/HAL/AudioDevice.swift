import CoreAudio
import Foundation

/// Physical transport of an audio device, as reported by Core Audio.
public enum TransportKind: String, Codable, CaseIterable, Sendable {
    case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, firewire, pci
    case aggregate, virtual, continuity, avb, unknown

    init(code: UInt32) {
        switch code {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeAirPlay: self = .airPlay
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypeFireWire: self = .firewire
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        default:
            // 'ccwd' / 'ccwl' (Continuity) on older SDKs.
            if code == 0x63637764 || code == 0x6363776C { self = .continuity } else { self = .unknown }
        }
    }

    public var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .usb: return "USB"
        case .bluetooth: return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .airPlay: return "AirPlay"
        case .thunderbolt: return "Thunderbolt"
        case .firewire: return "FireWire"
        case .pci: return "PCI"
        case .aggregate: return "Aggregate"
        case .virtual: return "Virtual"
        case .continuity: return "Continuity"
        case .avb: return "AVB"
        case .unknown: return "Other"
        }
    }

    public var isWireless: Bool { self == .bluetooth || self == .bluetoothLE || self == .airPlay || self == .continuity }
    public var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

/// A snapshot of an audio device's relevant properties.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let transport: TransportKind
    public let outputChannels: Int
    public let inputChannels: Int
    public let nominalSampleRate: Double
    /// Driver-reported latency after the IO time stamp (device + stream latency), seconds.
    public let reportedOutputLatency: Double
    public let reportedInputLatency: Double
    public let outputSafetyOffset: Int
    public let bufferFrameSize: Int
    public let maxBufferFrameSize: Int
    public let isAlive: Bool
    /// 1-based channel pair the device prefers for stereo output.
    public let preferredStereo: (Int, Int)
    public let outputFormatIsFloat: Bool
    public let dataSourceName: String?

    public var isOutput: Bool { outputChannels > 0 }
    public var isInput: Bool { inputChannels > 0 }
    /// Devices SyncForge creates for itself (process-tap aggregates).
    public var isSyncForgePrivate: Bool { uid.hasPrefix(SystemAudioCapture.aggregateUIDPrefix) }

    public static func == (a: AudioDeviceInfo, b: AudioDeviceInfo) -> Bool {
        a.id == b.id && a.uid == b.uid && a.name == b.name && a.nominalSampleRate == b.nominalSampleRate
            && a.outputChannels == b.outputChannels && a.inputChannels == b.inputChannels
            && a.reportedOutputLatency == b.reportedOutputLatency && a.isAlive == b.isAlive
            && a.dataSourceName == b.dataSourceName
    }

    public func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(uid)
    }

    public var reportedOutputLatencyMs: Double { reportedOutputLatency * 1000 }
}

extension AudioDeviceInfo {
    /// Reads all properties of a device. Returns nil if the device has no UID (not a real device).
    static func read(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = CAProperty.getString(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let name = CAProperty.getString(id, kAudioObjectPropertyName) ?? "Unknown Device"
        let manufacturer = CAProperty.getString(id, kAudioObjectPropertyManufacturer) ?? ""
        let transport = TransportKind(code: CAProperty.getUInt32(id, kAudioDevicePropertyTransportType) ?? 0)
        let outCh = CAProperty.channelCount(id, kAudioObjectPropertyScopeOutput)
        let inCh = CAProperty.channelCount(id, kAudioObjectPropertyScopeInput)
        let rate = CAProperty.getDouble(id, kAudioDevicePropertyNominalSampleRate) ?? 48000

        func latency(_ scope: AudioObjectPropertyScope) -> Double {
            let dev = Double(CAProperty.getUInt32(id, kAudioDevicePropertyLatency, scope) ?? 0)
            let streams = CAProperty.streams(id, scope)
            let streamLat = streams.first.flatMap { Double(CAProperty.getUInt32($0, kAudioStreamPropertyLatency) ?? 0) } ?? 0
            return rate > 0 ? (dev + streamLat) / rate : 0
        }

        let safety = Int(CAProperty.getUInt32(id, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput) ?? 0)
        let buffer = Int(CAProperty.getUInt32(id, kAudioDevicePropertyBufferFrameSize) ?? 512)
        let range = CAProperty.get(id, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange(mMinimum: 0, mMaximum: 0))
        let alive = (CAProperty.getUInt32(id, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
        let pref = CAProperty.get(id, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput,
                                  initial: (UInt32(1), UInt32(2))) ?? (1, 2)

        var isFloat = true
        for stream in CAProperty.streams(id, kAudioObjectPropertyScopeOutput) {
            if let f = CAProperty.get(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()) {
                if f.mFormatID != kAudioFormatLinearPCM || f.mFormatFlags & kAudioFormatFlagIsFloat == 0 || f.mBitsPerChannel != 32 {
                    isFloat = false
                }
            }
        }

        var sourceName: String?
        if let source = CAProperty.getUInt32(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) {
            var src = source
            var cf: Unmanaged<CFString>?
            var addr = CAProperty.address(kAudioDevicePropertyDataSourceNameForIDCFString, kAudioObjectPropertyScopeOutput)
            let status = withUnsafeMutablePointer(to: &src) { srcPtr in
                withUnsafeMutablePointer(to: &cf) { cfPtr in
                    var translation = AudioValueTranslation(
                        mInputData: srcPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                        mOutputData: cfPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &translation)
                }
            }
            if status == noErr, let s = cf?.takeRetainedValue() { sourceName = s as String }
        }

        return AudioDeviceInfo(
            id: id, uid: uid, name: name, manufacturer: manufacturer, transport: transport,
            outputChannels: outCh, inputChannels: inCh, nominalSampleRate: rate,
            reportedOutputLatency: outCh > 0 ? latency(kAudioObjectPropertyScopeOutput) : 0,
            reportedInputLatency: inCh > 0 ? latency(kAudioObjectPropertyScopeInput) : 0,
            outputSafetyOffset: safety, bufferFrameSize: buffer,
            maxBufferFrameSize: Int(range?.mMaximum ?? 0), isAlive: alive,
            preferredStereo: (Int(pref.0), Int(pref.1)), outputFormatIsFloat: isFloat,
            dataSourceName: sourceName)
    }
}
