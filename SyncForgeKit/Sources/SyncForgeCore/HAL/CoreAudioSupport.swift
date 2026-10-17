import CoreAudio
import Darwin
import Foundation

/// An error returned by a Core Audio call.
public struct CoreAudioError: Error, CustomStringConvertible, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    public var description: String { "\(operation) failed (\(CoreAudioError.describe(status)))" }

    static func describe(_ status: OSStatus) -> String {
        let u = UInt32(bitPattern: status)
        let bytes = [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), let s = String(bytes: bytes, encoding: .ascii) {
            return "'\(s)'"
        }
        return "\(status)"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status, operation()) }
}

/// Host-time (mach absolute time) helpers. Core Audio time stamps use the same clock.
public enum HostTime {
    public static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    @inline(__always) public static func now() -> UInt64 { mach_absolute_time() }
    @inline(__always) public static func seconds(_ ticks: Int64) -> Double { Double(ticks) / ticksPerSecond }
    @inline(__always) public static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * ticksPerSecond).rounded()) }
    @inline(__always) public static func offset(_ base: UInt64, seconds: Double) -> UInt64 {
        UInt64(Int64(bitPattern: base) + ticks(seconds))
    }
    /// Signed difference a - b in seconds.
    @inline(__always) public static func delta(_ a: UInt64, _ b: UInt64) -> Double {
        Double(Int64(bitPattern: a &- b)) / ticksPerSecond
    }
}

/// Thin typed wrappers around the AudioObject property API.
enum CAProperty {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        var addr = address(selector, scope, element)
        return AudioObjectHasProperty(object, &addr)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                       as type: T.Type = T.self, initial: T) -> T? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func getUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
        get(object, selector, scope, element, initial: UInt32(0))
    }

    static func getDouble(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
        get(object, selector, scope, initial: Float64(0))
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                            element: T) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: element, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
        var addr = address(selector, scope, element)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                       value: T) throws {
        var addr = address(selector, scope, element)
        var v = value
        let status = withUnsafePointer(to: &v) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        try check(status, "Set property \(CoreAudioError.describe(OSStatus(bitPattern: selector)))")
    }

    static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        getArray(device, kAudioDevicePropertyStreams, scope, element: AudioObjectID(0))
    }

    static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func translateUID(_ uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { cfPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), cfPtr, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var p = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &p, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

/// Keeps a set of property listener blocks and removes them together.
final class PropertyListenerBag {
    private struct Entry {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var entries: [Entry] = []
    private let queue: DispatchQueue

    init(queue: DispatchQueue = .main) { self.queue = queue }

    @discardableResult
    func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
             _ handler: @escaping () -> Void) -> Bool {
        var addr = CAProperty.address(selector, scope, element)
        guard AudioObjectHasProperty(object, &addr) else { return false }
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
        guard status == noErr else { return false }
        entries.append(Entry(object: object, address: addr, block: block))
        return true
    }

    func removeAll() {
        for var e in entries {
            AudioObjectRemovePropertyListenerBlock(e.object, &e.address, queue, e.block)
        }
        entries.removeAll()
    }

    func remove(object: AudioObjectID) {
        entries.removeAll { e in
            guard e.object == object else { return false }
            var addr = e.address
            AudioObjectRemovePropertyListenerBlock(e.object, &addr, queue, e.block)
            return true
        }
    }

    deinit { removeAll() }
}

/// Enables or disables the streams of one direction for a specific IOProc. Used to make sure an
/// output renderer never opens a device's microphone (which can, for example, force a Bluetooth
/// device from A2DP into the low-quality hands-free profile) and vice versa.
func setIOProcStreamUsage(device: AudioObjectID, procID: AudioDeviceIOProcID,
                          scope: AudioObjectPropertyScope, enabled: Bool) throws {
    var addr = CAProperty.address(kAudioDevicePropertyIOProcStreamUsage, scope)
    var size: UInt32 = 0
    guard AudioObjectHasProperty(device, &addr) else { return }
    try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "IOProcStreamUsage size")
    guard size >= UInt32(MemoryLayout<UnsafeMutableRawPointer>.size + 4) else { return }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
    try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw), "IOProcStreamUsage get")
    let countOffset = MemoryLayout<UnsafeMutableRawPointer>.size
    let count = Int(raw.load(fromByteOffset: countOffset, as: UInt32.self))
    guard count > 0 else { return }
    for i in 0..<count {
        raw.storeBytes(of: enabled ? UInt32(1) : UInt32(0), toByteOffset: countOffset + 4 + i * 4, as: UInt32.self)
    }
    try check(AudioObjectSetPropertyData(device, &addr, 0, nil, size, raw), "IOProcStreamUsage set")
}
