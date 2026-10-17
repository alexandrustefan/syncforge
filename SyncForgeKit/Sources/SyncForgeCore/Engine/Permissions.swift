import AVFoundation
import Foundation

/// System Audio Recording permission (TCC service `kTCCServiceAudioCapture`).
///
/// macOS has no public API to *query* this permission: creating a process tap triggers the
/// prompt, and when access is denied the tap silently delivers zeros. Like Apple-adjacent sample
/// code (AudioCap), we look up the TCC preflight function dynamically; if it is unavailable the
/// status is reported as `.unknown` and the UI falls back to showing the captured signal level.
public enum SystemAudioPermission {
    public enum Status: Sendable, Equatable { case authorized, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int

    private static let preflight: PreflightFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    public static func status() -> Status {
        guard let preflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
}

/// Microphone permission (public AVFoundation API).
public enum MicrophonePermission {
    public enum Status: Sendable, Equatable { case authorized, denied, notDetermined }

    public static func status() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public static func request() async -> Bool {
        if status() == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}
