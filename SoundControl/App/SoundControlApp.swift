import AppKit
import CoreAudio
import OSLog
import ServiceManagement
import SwiftUI

@main
struct SoundControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Runtime.headless)) {
            // New identity after every close: expanded sections and the settings page start collapsed again.
            MenuView()
                .id(model.menuGeneration)
                .environment(model)
        } label: {
            Image(nsImage: model.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Launch modes without a menu bar item: developer snapshots and the self-test run invisibly.
enum Runtime {
    static let arguments = CommandLine.arguments
    static let isSnapshot = arguments.contains("--snapshot")
    static let isSelfTest = arguments.contains("--selftest")
    static let isDemo = arguments.contains("--demo")
    static let headless = isSnapshot || isSelfTest

    static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

/// Advanced features, switched on/off via the small button at the bottom left.
/// Off: plain menu; stored effects and fixed sample rates are kept but have no effect.
@Observable
final class Features {
    static let shared = Features()
    private static let key = "advancedControls"

    private(set) var advanced: Bool
    /// Called after toggling (debounced) so taps and sample rates catch up.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var lastToggle = Date.distantPast
    @ObservationIgnored private var pending: DispatchWorkItem?

    private init() {
        advanced = Runtime.arguments.contains("--advanced") || (!Runtime.headless && UserDefaults.standard.bool(forKey: Self.key))
    }

    /// Gear per app: sound profiles, balance, mono, own output device.
    static var appDetails: Bool { shared.advanced }
    /// Sample rate per device.
    static var sampleRate: Bool { shared.advanced }

    /// Everything back to default: advanced features off, without delay.
    func reset() {
        pending?.cancel()
        advanced = false
        if !Runtime.headless { UserDefaults.standard.set(false, forKey: Self.key) }
    }

    func toggle() {
        // Debounce: a double click or bounce within 0.3 s counts once.
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.3 else { return }
        lastToggle = now
        advanced.toggle()
        if !Runtime.headless { UserDefaults.standard.set(advanced, forKey: Self.key) }
        // Rebuild audio only after a short quiet period so rapid toggling does not repeatedly create and tear down taps.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let base = Runtime.value(after: "--snapshot") {
            MainActor.assumeIsolated { Snapshot.render(to: base) }
            NSApp.terminate(nil)
        } else if let path = Runtime.value(after: "--selftest") {
            MainActor.assumeIsolated { SelfTest.run(writingTo: path) }
        } else {
            LoginItem.enableOnFirstLaunch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.mixer.shutdown() }
    }
}

/// Connects devices, audio apps and mixer.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let devices = DeviceManager()
    let monitor = AudioAppMonitor()
    let mixer: AppMixer
    let airPlay = AirPlayBrowser()

    /// Apps that are playing now or played within the last few seconds (top of the list).
    private(set) var recentlyPlaying: Set<String> = []
    @ObservationIgnored private var lastPlayed: [String: Date] = [:]
    @ObservationIgnored private var recheckScheduled = false
    @ObservationIgnored private var demoApps: [AudioApp] = []
    static let recentWindow: TimeInterval = 30

    /// Incremented as soon as the menu window is closed.
    private(set) var menuGeneration = 0
    @ObservationIgnored private var resignObserver: NSObjectProtocol?
    /// Incremented as soon as the menu window becomes key (opened).
    private(set) var menuOpenCount = 0
    @ObservationIgnored private var becomeObserver: NSObjectProtocol?
    /// Windows whose closing is being awaited (one check per window).
    @ObservationIgnored private var closeChecks: Set<ObjectIdentifier> = []

    private init() {
        if Runtime.isDemo {
            let suite = "io.github.ape97.soundcontrol.demo"
            UserDefaults().removePersistentDomain(forName: suite)
            mixer = AppMixer(defaults: UserDefaults(suiteName: suite)!)
        } else {
            mixer = AppMixer()
        }
        // Advanced off: leftovers from earlier versions (e.g. stored balance) count as reset.
        if !Features.shared.advanced && !Runtime.isDemo && !Runtime.headless {
            mixer.resetEffects()
            devices.resetRates()
        }
        Features.shared.onChange = { [weak self] in
            guard let self else { return }
            if Features.shared.advanced {
                mixer.refresh()
                devices.applyPreferredRates()
            } else {
                // Switched off: invisible settings must not keep acting → reset.
                mixer.resetEffects()
                devices.resetRates()
            }
        }
        monitor.onChange = { [weak self] apps in
            guard let self, !Runtime.isDemo else { return }
            mixer.update(apps: apps)
            trackPlaying(apps)
        }
        devices.onOutputsChange = { [weak self] in self?.syncOutputs() }
        devices.onOutputVolumeChange = { [weak self] in self?.dropBoostIfLowered() }
        syncOutputs()
        if Runtime.isDemo { setUpDemo() }
        mixer.update(apps: apps)
        trackPlaying(apps)
        if !Runtime.headless { observeMenuClose() }
    }

    // MARK: AirPlay

    /// Core Audio reports a selected AirPlay target only as "AirPlay" and does not say which one. If there is exactly one
    /// AirPlay room on the network, that is it → name and symbol as in Apple's sound settings; with several it stays "AirPlay".
    private func airPlaySpeaker(for d: AudioDevice) -> AirPlayBrowser.Speaker? {
        guard d.transport == kAudioDeviceTransportTypeAirPlay, airPlay.speakers.count == 1 else { return nil }
        return airPlay.speakers[0]
    }

    func name(_ d: AudioDevice) -> String { airPlaySpeaker(for: d)?.name ?? d.name }
    func symbol(_ d: AudioDevice) -> String { airPlaySpeaker(for: d)?.symbol ?? d.symbol }

    /// Reset everything after the menu window closes. What matters is that the window is hidden
    /// (verified: closed = no longer on screen), not mere focus loss: a context menu
    /// (right-click → "Hide from List") or a tooltip takes focus without closing (otherwise
    /// hiding a device collapsed the list). Also runs in the self-test (checks exactly that, without taking focus).
    func observeMenuClose() {
        let center = NotificationCenter.default
        resignObserver = center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { AppModel.shared.awaitClose(window) }
        }
        becomeObserver = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.menuOpenCount += 1 }
        }
    }

    /// Checks every 0.4 s: key again → stayed open; hidden → closed, reset.
    private func awaitClose(_ window: NSWindow) {
        guard closeChecks.insert(ObjectIdentifier(window)).inserted else { return }
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    guard let window, !window.isKeyWindow else {
                        if let window { model.closeChecks.remove(ObjectIdentifier(window)) }
                        return
                    }
                    if window.isVisible { return check() }
                    model.closeChecks.remove(ObjectIdentifier(window))
                    // Evidence for later debugging (log show --predicate 'subsystem == "io.github.ape97.soundcontrol"').
                    Logger(subsystem: "io.github.ape97.soundcontrol", category: "menu")
                        .notice("Menu closed → reset (\(String(describing: type(of: window)), privacy: .public))")
                    model.menuGeneration += 1
                }
            }
        }
        check()
    }

    /// All apps with an audio connection (in demo mode an invented, long list).
    var apps: [AudioApp] { Runtime.isDemo ? demoApps : monitor.apps }

    private func trackPlaying(_ apps: [AudioApp]) {
        let now = Date()
        for app in apps where app.isPlaying { lastPlayed[app.id] = now }
        let live = Set(apps.map(\.id))
        lastPlayed = lastPlayed.filter { live.contains($0.key) }
        let recent = Set(lastPlayed.filter { now.timeIntervalSince($0.value) < Self.recentWindow }.keys)
        if recent != recentlyPlaying { recentlyPlaying = recent }
        // Re-sort after the window expires so apps that went quiet move down.
        if !recent.isEmpty, !recheckScheduled {
            recheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recheckScheduled = false
                    self.trackPlaying(self.apps)
                }
            }
        }
    }

    private func setUpDemo() {
        let candidates: [(String, String, Bool)] = [
            ("com.apple.Music", "Music", true), ("com.apple.Safari", "Safari", true),
            ("com.apple.FaceTime", "FaceTime", false), ("com.apple.Podcasts", "Podcasts", false),
            ("com.apple.TV", "TV", false), ("com.apple.QuickTimePlayerX", "QuickTime Player", false),
            ("com.apple.Maps", "Maps", false), ("com.apple.mail", "Mail", false),
            ("com.apple.MobileSMS", "Messages", false), ("com.apple.Notes", "Notes", false),
            ("com.apple.Photos", "Photos", false), ("com.apple.Preview", "Preview", false),
            ("com.apple.Terminal", "Terminal", false), ("com.apple.finder", "Finder", false),
            ("com.apple.systempreferences", "System Settings", false), ("com.apple.calculator", "Calculator", false),
        ]
        demoApps = candidates.enumerated().map { i, c in
            AudioApp(id: c.0, name: c.1, pid: -1, processObjects: [AudioObjectID(90000 + i)], isPlaying: c.2)
        }
        mixer.setVolume(0.62, for: "com.apple.Safari")
        mixer.setProfile(.bassBoost, for: "com.apple.Music")
        mixer.setVolume(1.4, for: "com.apple.Music")
        mixer.setVolume(0, for: "com.apple.FaceTime")
        mixer.toggleMute(for: "com.apple.Podcasts")
        mixer.setProfile(.voice, for: "com.apple.Podcasts")
        mixer.setDeviceGain(1.25, for: devices.outputs[0].uid)
    }

    private func syncOutputs() {
        mixer.update(defaultOutputUID: devices.currentOutput?.uid, available: devices.outputUIDs)
    }

    // MARK: Output volume with boost (0 … 200 %)

    /// Up to 100 % the device regulates itself, above that Sound Control amplifies the apps.
    /// Devices without their own volume (e.g. HDMI) are regulated entirely in software.
    var outputLevel: Double {
        get {
            let boost = Double(mixer.gain(forDevice: devices.currentOutput?.uid))
            if !devices.outputHasVolume { return boost }
            return Double(devices.outputVolume) < 0.999 ? Double(devices.outputVolume) : boost
        }
        set {
            let uid = devices.currentOutput?.uid
            let v = max(0, min(Double(AppMixer.maxVolume), newValue))
            if !devices.outputHasVolume {
                mixer.setDeviceGain(Float(v), for: uid)
                if v > 0, devices.outputMuted { devices.setMuted(false, .output) }
                return
            }
            if v <= 1 {
                mixer.setDeviceGain(1, for: uid)
                devices.setVolume(Float(v), .output)
            } else {
                if devices.outputVolume < 0.999 { devices.setVolume(1, .output) }
                if devices.outputMuted { devices.setMuted(false, .output) }
                mixer.setDeviceGain(Float(v), for: uid)
            }
        }
    }

    var outputBoosted: Bool { outputLevel > 1.005 }

    /// If someone lowers the device volume (volume keys, Control Center), the boost ends.
    private func dropBoostIfLowered() {
        guard devices.outputHasVolume, devices.outputVolume < 0.995 else { return }
        let uid = devices.currentOutput?.uid
        if mixer.gain(forDevice: uid) > 1.005 { mixer.setDeviceGain(1, for: uid) }
    }

    // MARK: Menu bar

    var menuBarSymbol: String {
        if devices.outputMuted || outputLevel < 0.001 { return "speaker.slash.fill" }
        return "speaker.wave.3.fill"
    }

    /// Custom template image instead of a text symbol: as large and bold as the Control Center symbols.
    var menuBarImage: NSImage {
        let level = min(outputLevel, 1)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let base = NSImage(systemSymbolName: menuBarSymbol, variableValue: level, accessibilityDescription: "Sound Control")
            ?? NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "Sound Control")!
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}

enum LoginItem {
    static var isEnabled: Bool { Runtime.isDemo || SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sound Control: login item failed: \(error)")
        }
    }

    /// Register as a login item automatically on the very first launch.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        set(true)
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// Developer helper: renders the menu content invisibly to PNG files (light and dark) without showing windows.
/// Usage: SoundControl --snapshot /path/base [--demo]  →  base-light.png, base-dark.png
enum Snapshot {
    @MainActor
    static func render(to base: String) {
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)!
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.appearance = appearance
            let host = NSHostingView(rootView: MenuView().environment(AppModel.shared))
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let size = host.fittingSize
            effect.frame = NSRect(origin: .zero, size: size)
            host.frame = effect.bounds
            effect.addSubview(host)
            let window = NSWindow(contentRect: effect.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = effect
            effect.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { continue }
            effect.cacheDisplay(in: effect.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(suffix).png"))
        }
        // Menu bar symbol on a light (top) and a dark (bottom) 24 pt strip at double resolution; scripts/compose.swift reads it.
        let icon = AppModel.shared.menuBarImage
        let width: CGFloat = 44, height: CGFloat = 24
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * 2, pixelsHigh: Int(height) * 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height * 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, background, ink) in [(1, NSColor.white, NSColor.black), (0, NSColor(white: 0.16, alpha: 1), NSColor.white)] {
            let frame = NSRect(x: 0, y: CGFloat(row) * height, width: width, height: height)
            background.setFill()
            frame.fill()
            let tinted = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: (width - icon.size.width) / 2, y: frame.minY + (height - icon.size.height) / 2,
                                   width: icon.size.width, height: icon.size.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-symbol.png"))
    }
}
