import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// Changes the device manager reports to its client (the engine).
public enum DeviceEvent: Equatable, Sendable {
    case listChanged
    case defaultOutputChanged
    case defaultInputChanged
    case deviceChanged(uid: String)
    case deviceLatencyChanged(uid: String)
    case defaultOutputVolumeChanged
    case serviceRestarted
}

/// Enumerates and monitors Core Audio devices. All listeners are delivered on the main queue.
@MainActor
@Observable
public final class AudioDeviceManager {
    public private(set) var devices: [AudioDeviceInfo] = []
    public private(set) var defaultOutputUID: String?
    public private(set) var defaultInputUID: String?
    /// Linear gain equivalent of the default output device's volume (nil if it has no volume control).
    public private(set) var defaultOutputGain: Double?
    public private(set) var defaultOutputMuted = false

    @ObservationIgnored public var onEvent: ((DeviceEvent) -> Void)?
    @ObservationIgnored private let systemListeners = PropertyListenerBag()
    @ObservationIgnored private let deviceListeners = PropertyListenerBag()
    @ObservationIgnored private let volumeListeners = PropertyListenerBag()

    public init() {
        refresh()
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners.add(system, kAudioHardwarePropertyDevices) { [weak self] in
            MainActor.assumeIsolated { self?.handleListChange() }
        }
        systemListeners.add(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDefaults()
                self?.onEvent?(.defaultOutputChanged)
            }
        }
        systemListeners.add(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshDefaults()
                self?.onEvent?(.defaultInputChanged)
            }
        }
        systemListeners.add(system, kAudioHardwarePropertyServiceRestarted) { [weak self] in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.onEvent?(.serviceRestarted)
            }
        }
    }

    /// A fixed catalog for coordinator tests; installs no HAL listeners and opens no devices.
    init(snapshot: [AudioDeviceInfo]) {
        devices = snapshot
    }

    // MARK: Queries

    public var outputDevices: [AudioDeviceInfo] {
        devices.filter { $0.isOutput && !$0.isSyncForgePrivate }
    }

    public var inputDevices: [AudioDeviceInfo] {
        devices.filter { $0.isInput && !$0.isSyncForgePrivate }
    }

    public func device(uid: String) -> AudioDeviceInfo? {
        devices.first { $0.uid == uid }
    }

    public func outputDevice(uid: String) -> AudioDeviceInfo? {
        devices.first { $0.uid == uid && $0.isOutput }
    }

    public func inputDevice(uid: String) -> AudioDeviceInfo? {
        devices.first { $0.uid == uid && $0.isInput }
    }

    /// The best default calibration microphone: built-in, then USB, never Bluetooth.
    public var recommendedMicrophone: AudioDeviceInfo? {
        let inputs = inputDevices.filter { $0.isAlive }
        return inputs.first { $0.transport == .builtIn }
            ?? inputs.first { $0.transport == .usb }
            ?? inputs.first { !$0.transport.isBluetooth && $0.transport != .virtual && $0.transport != .continuity }
    }

    // MARK: Refresh

    public func refresh() {
        let ids = CAProperty.getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices,
                                      element: AudioObjectID(0))
        let list = ids.compactMap { AudioDeviceInfo.read($0) }
        if list != devices { devices = list }
        refreshDefaults()
        installDeviceListeners()
    }

    private func handleListChange() {
        refresh()
        onEvent?(.listChanged)
    }

    private func refreshDevice(_ id: AudioObjectID, latencyOnly: Bool) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        guard let fresh = AudioDeviceInfo.read(id) else {
            refresh()
            onEvent?(.listChanged)
            return
        }
        let old = devices[idx]
        if fresh != old {
            devices[idx] = fresh
            if old.reportedOutputLatency != fresh.reportedOutputLatency {
                onEvent?(.deviceLatencyChanged(uid: fresh.uid))
            }
            if !latencyOnly || old.nominalSampleRate != fresh.nominalSampleRate || old.isAlive != fresh.isAlive {
                onEvent?(.deviceChanged(uid: fresh.uid))
            }
        }
    }

    private func installDeviceListeners() {
        deviceListeners.removeAll()
        for device in devices where !device.isSyncForgePrivate {
            let id = device.id
            let changed: () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevice(id, latencyOnly: false) }
            }
            let latency: () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.refreshDevice(id, latencyOnly: true) }
            }
            deviceListeners.add(id, kAudioDevicePropertyDeviceIsAlive, changed)
            deviceListeners.add(id, kAudioDevicePropertyNominalSampleRate, changed)
            deviceListeners.add(id, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, changed)
            deviceListeners.add(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, changed)
            deviceListeners.add(id, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, latency)
            deviceListeners.add(id, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, latency)
        }
    }

    private func refreshDefaults() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let out = CAProperty.getUInt32(system, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
        let inp = CAProperty.getUInt32(system, kAudioHardwarePropertyDefaultInputDevice) ?? 0
        let outUID = out != 0 ? CAProperty.getString(out, kAudioDevicePropertyDeviceUID) : nil
        let inUID = inp != 0 ? CAProperty.getString(inp, kAudioDevicePropertyDeviceUID) : nil
        if outUID != defaultOutputUID {
            defaultOutputUID = outUID
            installVolumeListeners(device: out)
        }
        if inUID != defaultInputUID { defaultInputUID = inUID }
        readDefaultVolume(device: out)
    }

    private func installVolumeListeners(device: AudioObjectID) {
        volumeListeners.removeAll()
        guard device != 0 else { return }
        let handler: () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                self?.readDefaultVolume(device: device)
                self?.onEvent?(.defaultOutputVolumeChanged)
            }
        }
        volumeListeners.add(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, handler)
        volumeListeners.add(device, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, handler)
        volumeListeners.add(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, handler)
    }

    private func readDefaultVolume(device: AudioObjectID) {
        guard device != 0 else {
            defaultOutputGain = nil
            return
        }
        let scope = kAudioObjectPropertyScopeOutput
        var gain: Double?
        if let db = CAProperty.get(device, kAudioDevicePropertyVolumeDecibels, scope, kAudioObjectPropertyElementMain, initial: Float32(0)) {
            gain = pow(10, Double(db) / 20)
        } else if let scalar = CAProperty.get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, initial: Float32(0)) {
            // Perceptual scalar without a dB mapping: approximate with a square law.
            gain = Double(scalar * scalar)
        }
        let muted = (CAProperty.getUInt32(device, kAudioDevicePropertyMute, scope) ?? 0) != 0
        if gain != defaultOutputGain { defaultOutputGain = gain }
        if muted != defaultOutputMuted { defaultOutputMuted = muted }
    }
}
