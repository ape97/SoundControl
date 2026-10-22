import AppKit
import CoreAudio
import Foundation
import Observation
import os

/// Stored setting of an app (key: bundle ID). Survives restarts of the app, Sound Control and the Mac.
struct AppSetting: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    var profile: SoundProfile = .flat
    var balance: Float = 0
    var mono = false
    /// Own output device for this app (UID); nil = system output.
    var outputUID: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        profile = (try? c.decodeIfPresent(SoundProfile.self, forKey: .profile)) ?? .flat
        balance = try c.decodeIfPresent(Float.self, forKey: .balance) ?? 0
        mono = try c.decodeIfPresent(Bool.self, forKey: .mono) ?? false
        outputUID = try c.decodeIfPresent(String.self, forKey: .outputUID)
    }

    var volumeIsNeutral: Bool { !muted && abs(volume - 1) < 0.005 }
    var effectsAreNeutral: Bool { profile == .flat && abs(balance) < 0.01 && !mono && outputUID == nil }
    var isNeutral: Bool { volumeIsNeutral && effectsAreNeutral }
    var effectiveGain: Float { muted ? 0 : volume }

    /// What actually takes effect: with the gear hidden, only volume and mute.
    var applied: AppSetting {
        guard !Features.appDetails else { return self }
        var s = AppSetting()
        s.volume = volume
        s.muted = muted
        return s
    }

    /// Short description for lists, e.g. "0 % · Bass Boost".
    var summary: String {
        var parts: [String] = []
        if muted { parts.append("Muted") } else if !volumeIsNeutral { parts.append("\(Int((volume * 100).rounded()))%") }
        if profile != .flat { parts.append(profile.title) }
        if abs(balance) >= 0.01 { parts.append(balance < 0 ? "Balance left" : "Balance right") }
        if mono { parts.append("Mono") }
        if outputUID != nil { parts.append("Custom output") }
        return parts.isEmpty ? "Default" : parts.joined(separator: " · ")
    }
}

/// Volume, sound and output per app plus software boost of the output device.
/// A tap is created only for apps whose sound actually needs processing – all others run unchanged.
@MainActor
@Observable
final class AppMixer {
    static let maxVolume: Float = 2
    static let releaseDelay: TimeInterval = 1.2

    private(set) var settings: [String: AppSetting] = [:]
    /// Last seen name per bundle ID so stored apps remain readable even when the app is not running.
    private(set) var names: [String: String] = [:]
    /// Software gain per output device (UID): beyond 100 % or for devices without their own volume.
    private(set) var deviceGain: [String: Float] = [:]
    private(set) var permission: CapturePermission.State = CapturePermission.state
    private(set) var failures: [String: String] = [:]
    private(set) var activeTapCount = 0

    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var apps: [AudioApp] = []
    @ObservationIgnored private var defaultOutputUID: String?
    @ObservationIgnored private var availableOutputs: Set<String> = []
    @ObservationIgnored private var neutralSince: [String: Date] = [:]
    @ObservationIgnored private var releaseScheduled = false
    @ObservationIgnored private var permissionRequested = false
    @ObservationIgnored private let log = Logger(subsystem: "io.github.ape97.soundcontrol", category: "mixer")
    @ObservationIgnored private let defaults: UserDefaults

    private enum Key {
        static let settings = "appSettings"
        static let names = "appNames"
        static let deviceGain = "deviceGain"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Key.settings),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) {
            settings = saved.filter { !$0.value.isNeutral }
        }
        names = defaults.dictionary(forKey: Key.names) as? [String: String] ?? [:]
        if let gains = defaults.dictionary(forKey: Key.deviceGain) as? [String: Double] {
            deviceGain = gains.mapValues { Float($0) }.filter { abs($0.value - 1) > 0.005 }
        }
        log.info("Start: \(self.settings.count) stored app settings, permission  \(String(describing: self.permission), privacy: .public)")
    }

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }
    func applied(for id: String) -> AppSetting { setting(for: id).applied }

    // MARK: External inputs

    func update(apps: [AudioApp]) {
        self.apps = apps
        var changed = false
        for app in apps where names[app.id] != app.name {
            names[app.id] = app.name
            changed = true
        }
        if changed { defaults.set(names, forKey: Key.names) }
        reconcile()
    }

    func update(defaultOutputUID: String?, available: Set<String>) {
        guard defaultOutputUID != self.defaultOutputUID || available != availableOutputs else { return }
        self.defaultOutputUID = defaultOutputUID
        availableOutputs = available
        reconcile()
    }

    /// After a sample rate change, rebuild all taps (filters adapt).
    func rebuildAll() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
        reconcile()
    }

    // MARK: Controls

    func setVolume(_ volume: Float, for id: String) {
        mutate(id) {
            $0.volume = max(0, min(Self.maxVolume, volume))
            if $0.volume > 0 { $0.muted = false }
        }
    }

    func toggleMute(for id: String) { mutate(id) { $0.muted.toggle() } }
    func setProfile(_ profile: SoundProfile, for id: String) { mutate(id) { $0.profile = profile } }
    func setBalance(_ balance: Float, for id: String) { mutate(id) { $0.balance = abs(balance) < 0.03 ? 0 : max(-1, min(1, balance)) } }
    func setMono(_ mono: Bool, for id: String) { mutate(id) { $0.mono = mono } }
    func setOutput(_ uid: String?, for id: String) { mutate(id) { $0.outputUID = uid } }

    /// Resets only volume and mute; sound and output remain.
    func resetVolume(_ id: String) { mutate(id) { $0.volume = 1; $0.muted = false } }
    func reset(_ id: String) { mutate(id) { $0 = AppSetting() } }

    /// Everything back to default: app volumes, effects and device boost.
    func resetAll() {
        settings.removeAll()
        save()
        deviceGain.removeAll()
        defaults.removeObject(forKey: Key.deviceGain)
        reconcile()
    }

    /// Reset advanced settings of all apps (profile, balance, mono, own output); volume and mute remain.
    func resetEffects() {
        for (id, s) in settings {
            var plain = AppSetting()
            plain.volume = s.volume
            plain.muted = s.muted
            settings[id] = plain.isNeutral ? nil : plain
        }
        save()
        reconcile()
    }

    func gain(forDevice uid: String?) -> Float {
        guard let uid else { return 1 }
        return deviceGain[uid] ?? 1
    }

    func setDeviceGain(_ gain: Float, for uid: String?) {
        guard let uid else { return }
        let g = max(0, min(Self.maxVolume, gain))
        let value: Float? = abs(g - 1) < 0.005 ? nil : g
        guard deviceGain[uid] != value else { return }
        deviceGain[uid] = value
        defaults.set(deviceGain.mapValues { Double($0) }, forKey: Key.deviceGain)
        if value != nil { ensurePermission() }
        reconcile()
    }

    func refreshPermission() {
        let new = CapturePermission.state
        if new != permission {
            permission = new
            log.info("Permission now \(String(describing: new), privacy: .public)")
        }
        reconcile()
    }

    func requestPermission() {
        CapturePermission.request { [weak self] _ in self?.refreshPermission() }
    }

    private func mutate(_ id: String, _ change: (inout AppSetting) -> Void) {
        var s = setting(for: id)
        change(&s)
        settings[id] = s.isNeutral ? nil : s
        save()
        if !s.isNeutral { ensurePermission() }
        reconcile()
    }

    private func ensurePermission() {
        guard permission != .granted, !permissionRequested, !Runtime.headless else { return }
        permissionRequested = true
        requestPermission()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Key.settings)
        }
    }

    // MARK: Reconcile taps

    private func targetOutput(for s: AppSetting) -> String? {
        if let uid = s.outputUID, availableOutputs.contains(uid) { return uid }
        return defaultOutputUID
    }

    private func config(for s: AppSetting, output: String, sampleRate: Double) -> DSPConfig {
        DSPConfig(gain: s.effectiveGain * gain(forDevice: output), balance: s.balance, mono: s.mono,
                  profile: s.profile, sampleRate: sampleRate)
    }

    private func needsTap(_ s: AppSetting, output: String) -> Bool {
        !s.isNeutral || abs(gain(forDevice: output) - 1) > 0.005
    }

    /// Advanced features toggled: re-apply the effective settings.
    func refresh() { reconcile() }

    private func reconcile() {
        let live = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let canTap = permission == .granted && !Runtime.headless
        let now = Date()

        for (id, tap) in taps {
            let s = applied(for: id)
            guard canTap, let app = live[id], let output = targetOutput(for: s) else {
                drop(id)
                continue
            }
            if tap.outputUID != output || !tap.updateProcesses(app.processObjects) {
                drop(id)
                continue
            }
            if needsTap(s, output: output) {
                neutralSince[id] = nil
                tap.update(config(for: s, output: output, sampleRate: tap.sampleRate))
            } else {
                // Keep apps that just became neutral for a moment so a slider around 100 % does not constantly create and tear down taps.
                tap.update(config(for: s, output: output, sampleRate: tap.sampleRate))
                let since = neutralSince[id] ?? now
                neutralSince[id] = since
                if now.timeIntervalSince(since) >= Self.releaseDelay { drop(id) } else { scheduleRelease() }
            }
        }

        if canTap {
            for app in apps where taps[app.id] == nil {
                let s = applied(for: app.id)
                guard let output = targetOutput(for: s), needsTap(s, output: output) else { continue }
                do {
                    let tap = try AppTap(processObjects: app.processObjects, outputUID: output,
                                         config: config(for: s, output: output, sampleRate: 48000))
                    tap.update(config(for: s, output: output, sampleRate: tap.sampleRate))
                    let id = app.id
                    tap.onSampleRateChange = { [weak self] _ in
                        MainActor.assumeIsolated { self?.retune(id) }
                    }
                    taps[app.id] = tap
                    failures[app.id] = nil
                    log.info("Tap active:  \(app.id, privacy: .public) → \(output, privacy: .public)")
                } catch {
                    log.error("Tap for \(app.id, privacy: .public) failed:  \(String(describing: error), privacy: .public)")
                    failures[app.id] = "Couldn't process audio: \(error)"
                }
            }
        }
        for id in failures.keys where live[id] == nil || applied(for: id).isNeutral { failures[id] = nil }
        if activeTapCount != taps.count { activeTapCount = taps.count }
    }

    private func retune(_ id: String) {
        guard let tap = taps[id] else { return }
        tap.update(config(for: applied(for: id), output: tap.outputUID, sampleRate: tap.sampleRate))
    }

    private func drop(_ id: String) {
        taps[id]?.stop()
        taps[id] = nil
        neutralSince[id] = nil
    }

    private func scheduleRelease() {
        guard !releaseScheduled else { return }
        releaseScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.releaseScheduled = false
                self?.reconcile()
            }
        }
    }

    func isTapped(_ id: String) -> Bool { taps[id] != nil }

    func shutdown() {
        taps.values.forEach { $0.stop() }
        taps.removeAll()
    }
}
