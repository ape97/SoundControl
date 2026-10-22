import AppKit
import Foundation

/// Permission "Screen & System Audio Recording → audio only" (TCC service kTCCServiceAudioCapture).
/// Without it a tap would mute the app but deliver only silence – hence check beforehand.
enum CapturePermission {
    enum State { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    static var state: State {
        if Runtime.isDemo { return .granted }
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(sym, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
            Task { @MainActor in completion(false) }
            return
        }
        unsafeBitCast(sym, to: Request.self)(service, nil) { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
