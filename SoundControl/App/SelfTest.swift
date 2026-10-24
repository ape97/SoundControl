import AppKit
import CoreAudio
import Foundation
import SwiftUI

/// Invisible self-test: checks sound profiles, limiter, persistence, hide/show and menu closing and, if permitted, a real tap
/// on a silent test tone. Nothing is played audibly, no windows are shown, no real settings are touched.
/// Usage: open -n -g -a /Applications/SoundControl.app --args --selftest /path/result.json
@MainActor
enum SelfTest {
    private static var report: [String: Any] = [:]
    private static var failures: [String] = []

    static func run(writingTo path: String) {
        checkProfiles()
        checkLimiter()
        checkBalanceAndMono()
        checkPersistence()
        checkAppOwnership()
        failures += UpdateCheck.selfTest()
        report["permission"] = String(describing: CapturePermission.state)
        report["device"] = [
            "output": AppModel.shared.devices.currentOutput?.name ?? "-",
            "rate": AppModel.shared.devices.outputRate,
            "rates": AppModel.shared.devices.outputRates,
            "inputRates": AppModel.shared.devices.inputRates,
            "hasVolume": AppModel.shared.devices.outputHasVolume,
        ]
        report["apps"] = AppModel.shared.monitor.apps.map { "\($0.name)\($0.isPlaying ? " ▶" : "")" }

        let finish = {
            report["failures"] = failures
            report["ok"] = failures.isEmpty
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
        checkDeviceList {
            if CapturePermission.state == .granted {
                liveTap(then: finish)
            } else {
                report["liveTap"] = "skipped (no permission)"
                finish()
            }
        }
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }

    // MARK: Offline DSP

    /// Gain in dB for a sine of frequency f after settling.
    private static func response(_ profile: SoundProfile, f: Double, amplitude: Float = 0.05, gain: Float = 1,
                                 fs: Double = 48000) -> Double {
        let shared = DSPShared(DSPConfig(gain: gain, balance: 0, mono: false, profile: profile, sampleRate: fs))
        let state = DSPState(initialGain: gain)
        state.prepare(sampleRate: fs)
        let block = 512, total = Int(fs * 1.5)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }
        var inSq = 0.0, outSq = 0.0, n = 0
        for start in stride(from: 0, to: total, by: block) {
            for i in 0..<block {
                let v = amplitude * Float(sin(2 * Double.pi * f * Double(start + i) / fs))
                l[i] = v; r[i] = v
                if start > total / 2 { inSq += Double(v * v) }
            }
            state.process(left: l, right: r, frames: block, shared: shared)
            if start > total / 2 { for i in 0..<block { outSq += Double(l[i] * l[i]) }; n += block }
        }
        return 10 * log10(max(outSq, 1e-20) / max(inSq, 1e-20))
    }

    private static func checkProfiles() {
        var table: [String: [String: Double]] = [:]
        for p in SoundProfile.allCases {
            var row: [String: Double] = [:]
            for f in [40.0, 100, 1000, 3000, 10000] {
                row["\(Int(f))"] = (response(p, f: f) * 10).rounded() / 10
            }
            table[p.rawValue] = row
        }
        report["profiles_dB"] = table
        func at(_ p: SoundProfile, _ f: Int) -> Double { table[p.rawValue]?["\(f)"] ?? .nan }

        for f in [40, 100, 1000, 3000, 10000] { expect(abs(at(.flat, f)) < 0.2, "Off is not neutral at  \(f) Hz: \(at(.flat, f))") }
        expect(at(.bassBoost, 100) > 5 && abs(at(.bassBoost, 3000)) < 1, "Bass boost does not behave as expected")
        expect(at(.bassCut, 40) < -6 && abs(at(.bassCut, 3000)) < 1, "Bass cut does not behave as expected")
        expect(at(.treble, 10000) > 4 && abs(at(.treble, 100)) < 1, "Treble does not behave as expected")
        expect(at(.voice, 3000) > 3 && at(.voice, 40) < -6, "Voice does not behave as expected")
        expect(at(.loudness, 40) > 3 && at(.loudness, 10000) > 2 && abs(at(.loudness, 1000)) < 1.5, "Loudness does not behave as expected")
        expect(at(.clarity, 3000) > 1.5 && at(.clarity, 10000) > 2, "Clarity does not behave as expected")
        // Night mode raises quiet signals ...
        expect(at(.night, 1000) > 4, "Night mode does not raise quiet signals:  \(at(.night, 1000))")
        // ... and raises loud ones much less.
        let loud = response(.night, f: 1000, amplitude: 0.7)
        report["night_loud_dB"] = (loud * 10).rounded() / 10
        expect(loud < at(.night, 1000) - 3, "Night mode does not compress")
        for p in SoundProfile.allCases {
            for f in [40, 100, 1000, 3000, 10000] { expect(at(p, f).isFinite, "\(p) at \(f) Hz not finite") }
        }
    }

    private static func checkLimiter() {
        // Loud signal at 200 % with bass boost: must never clip.
        let fs = 48000.0
        let shared = DSPShared(DSPConfig(gain: 2, balance: 0, mono: false, profile: .bassBoost, sampleRate: fs))
        let state = DSPState(initialGain: 2)
        state.prepare(sampleRate: fs)
        let block = 256
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }
        var peak: Float = 0
        for start in stride(from: 0, to: Int(fs), by: block) {
            for i in 0..<block {
                let t = Double(start + i) / fs
                let v = Float(0.9 * sin(2 * .pi * 80 * t) + 0.1 * sin(2 * .pi * 2500 * t))
                l[i] = v; r[i] = -v
            }
            state.process(left: l, right: r, frames: block, shared: shared)
            for i in 0..<block { peak = max(peak, abs(l[i]), abs(r[i])) }
        }
        report["limiter_peak"] = Double(peak)
        expect(peak <= 0.98, "Limiter lets \(peak) through")

        // A volume change is applied without a jump.
        let quiet = response(.flat, f: 1000, gain: 0.5)
        expect(abs(quiet - 20 * log10(0.5)) < 0.3, "Volume 50 % yields \(quiet) dB")
        let boosted = response(.flat, f: 1000, gain: 2)
        expect(abs(boosted - 20 * log10(2)) < 0.3, "Boost 200 % yields \(boosted) dB")
        report["gain_50_dB"] = (quiet * 100).rounded() / 100
        report["gain_200_dB"] = (boosted * 100).rounded() / 100
        expect(response(.flat, f: 1000, gain: 0) < -100, "0 % is not silent")
    }

    private static func checkBalanceAndMono() {
        let shared = DSPShared(DSPConfig(gain: 1, balance: -1, mono: true, profile: .flat, sampleRate: 48000))
        let state = DSPState(initialGain: 1)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 64), r = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { l.deallocate(); r.deallocate() }
        for _ in 0..<4 {
            for i in 0..<64 { l[i] = 0; r[i] = 0.4 }
            state.process(left: l, right: r, frames: 64, shared: shared)
        }
        expect(abs(l[10] - 0.2) < 0.001 && abs(r[10]) < 0.001, "Balance left + mono wrong:  \(l[10]) / \(r[10])")
    }

    // MARK: Process → app

    /// Test data modelled on real processes (no live system): browser helpers, a virtualization app whose root-owned
    /// VM process has no responsible PID and a different bundle ID, and a stray background process that must stay hidden.
    private static func checkAppOwnership() {
        typealias C = AppOwnership.Candidate
        let safari = C(pid: 100, bundleID: "com.apple.Safari", bundlePath: "/Applications/Safari.app")
        let chrome = C(pid: 200, bundleID: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app")
        let vmApp = C(pid: 300, bundleID: "com.vendor.desktop.console", bundlePath: "/Applications/Vendor Desktop.app")
        let xcode = C(pid: 400, bundleID: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app")
        let sim = C(pid: 410, bundleID: "com.apple.iphonesimulator",
                    bundlePath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        let regular = [safari, chrome, vmApp, xcode, sim]
        func owner(_ pid: pid_t, _ bundle: String = "", path: String = "", resp: pid_t? = nil) -> pid_t? {
            AppOwnership.owner(pid: pid, bundleID: bundle, executablePath: path, responsiblePID: resp ?? pid, among: regular)?.pid
        }
        expect(owner(100) == 100, "ownership: app itself")
        expect(owner(101, "com.apple.WebKit.GPU", resp: 100) == 100, "ownership: responsible PID")
        expect(owner(201, "com.google.Chrome.helper", resp: 201) == 200, "ownership: bundle ID prefix")
        // Root-owned VM process: no responsible PID, own bundle ID, executable inside the app bundle.
        let vmPath = "/Applications/Vendor Desktop.app/Contents/MacOS/VM.app/Contents/MacOS/vm_app"
        expect(owner(301, "com.vendor.vm", path: vmPath, resp: 301) == 300, "ownership: helper inside app bundle")
        expect(owner(302, "com.vendor.dispatcher",
                     path: "/Applications/Vendor Desktop.app/Contents/MacOS/Service.app/Contents/MacOS/disp", resp: 302) == 300,
               "ownership: service inside app bundle")
        expect(owner(411, "x", path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/helper") == 410,
               "ownership: innermost enclosing app wins")
        // Must stay hidden: system daemons and look-alike paths.
        expect(owner(500, "com.apple.audiomxd", path: "/usr/sbin/audiomxd") == nil, "ownership: daemon is not an app")
        expect(owner(501, "", path: "/Applications/Vendor Desktop.app.backup/x") == nil, "ownership: look-alike path")
        expect(owner(502, "", path: "") == nil, "ownership: unknown path")
    }

    // MARK: Persistence

    private static func checkPersistence() {
        let suite = "io.github.ape97.soundcontrol.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return failures.append("Test store missing") }

        let whatsapp = "net.whatsapp.WhatsApp"
        let first = AppMixer(defaults: defaults)
        first.setVolume(0, for: whatsapp)
        first.setProfile(.night, for: "com.apple.Music")
        first.setBalance(0.4, for: "com.apple.Music")
        first.setMono(true, for: "com.apple.Music")
        first.setOutput("TEST-UID", for: "com.apple.Music")
        first.setDeviceGain(1.5, for: "BuiltInSpeakerDevice")
        first.setVolume(1, for: "com.apple.Safari")         // neutral → not stored

        // "Restart": a new mixer reads the same store.
        let second = AppMixer(defaults: defaults)
        let w = second.setting(for: whatsapp), m = second.setting(for: "com.apple.Music")
        expect(w.volume == 0, "WhatsApp after restart \(w.volume) instead of 0")
        expect(m.profile == .night && abs(m.balance - 0.4) < 0.001 && m.mono && m.outputUID == "TEST-UID",
               "Music settings not fully stored")
        expect(abs(second.gain(forDevice: "BuiltInSpeakerDevice") - 1.5) < 0.001, "Device boost not stored")
        expect(second.settings["com.apple.Safari"] == nil, "Neutral app was stored")

        // Old records (volume/muted only) must remain readable.
        let legacy = #"{"x":{"volume":0.3,"muted":true}}"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode([String: AppSetting].self, from: legacy)
        expect(decoded?["x"]?.volume == 0.3 && decoded?["x"]?.muted == true && decoded?["x"]?.profile == .flat,
               "Old settings not readable")

        second.reset(whatsapp)
        let third = AppMixer(defaults: defaults)
        expect(third.settings[whatsapp] == nil, "Reset not stored")
        report["persistence"] = "checked"
    }

    // MARK: Real tap (only with permission, silent)

    private static func liveTap(then finish: @escaping () -> Void) {
        let dir = FileManager.default.temporaryDirectory
        let wav = dir.appendingPathComponent("soundcontrol-selftest.wav")
        writeTestTone(to: wav)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        do { try player.run() } catch {
            report["liveTap"] = "afplay could not be started"
            return finish()
        }
        // The process object appears as soon as afplay opens its audio device.
        var waited = 0.0
        func attempt() {
            var pid = player.processIdentifier
            var object = AudioObjectID(kAudioObjectUnknown)
            var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            if object == kAudioObjectUnknown, waited < 2 {
                waited += 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { attempt() }
                return
            }
            guard object != kAudioObjectUnknown, let output = AppModel.shared.devices.currentOutput?.uid else {
                report["liveTap"] = "no process object for afplay"
                player.terminate()
                return finish()
            }
            do {
                let tap = try AppTap(processObjects: [object], outputUID: output,
                                     config: DSPConfig(gain: 0.5, balance: 0, mono: false, profile: .flat, sampleRate: 48000),
                                     silent: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    let half = tap.shared.meter.withLock { m -> Meter in let c = m; m = Meter(); return c }
                    tap.update(DSPConfig(gain: 0, balance: 0, mono: false, profile: .flat, sampleRate: tap.sampleRate))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        let zero = tap.shared.meter.withLock { $0 }
                        tap.stop()
                        player.terminate()
                        let ratio = half.inRMS > 0 ? half.outRMS / half.inRMS : 0
                        report["liveTap"] = [
                            "sampleRate": tap.sampleRate,
                            "inRMS": half.inRMS, "outRMS": half.outRMS, "ratio": ratio,
                            "zeroOutRMS": zero.outRMS, "frames": half.frames,
                        ]
                        expect(half.inRMS > 0.005, "Tap delivers no sound (inRMS  \(half.inRMS))")
                        expect(abs(ratio - 0.5) < 0.08, "Tap volume 50 % yields ratio  \(ratio)")
                        expect(zero.outRMS < 0.002, "Tap at 0 % not silent (\(zero.outRMS))")
                        try? FileManager.default.removeItem(at: wav)
                        finish()
                    }
                }
            } catch {
                report["liveTap"] = "Error: \(error)"
                failures.append("Tap could not be created:  \(error)")
                player.terminate()
                finish()
            }
        }
        attempt()
    }

    // MARK: UI

    /// Invisible test of the device list and menu closing: the real menu in a transparent window far outside the
    /// screen (no mouse pointer, no focus, no system prompt). Clicks are not possible: SwiftUI does not build its accessibility
    /// tree in-process. Checks at the logic level: hiding/showing selects nothing,
    /// losing focus with the menu open (context menu, tooltip) does not reset, only closing does. The self-test
    /// never switches the selection.
    private static func checkDeviceList(then next: @escaping () -> Void) {
        let model = AppModel.shared, dm = model.devices
        guard let current = dm.currentOutput, let other = dm.outputs.first(where: { $0.id != current.id }) else {
            report["ui"] = "skipped (only one output device)"
            return next()
        }
        let wasHidden = dm.isHidden(other)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 380, height: 1200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TestMenu().environment(model))
        window.orderFrontRegardless()
        model.observeMenuClose()
        let generation = model.menuGeneration, selections = dm.testSelections
        var done: [String] = []

        func step(_ actions: [() -> Void]) {
            guard let first = actions.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                MainActor.assumeIsolated { first(); step(Array(actions.dropFirst())) }
            }
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        step([
            {
                expect(model.menuIsOpen, "UI: opening is not noticed")
                dm.setHidden(!wasHidden, other)
                expect(dm.isHidden(other) != wasHidden, "UI: hide/show has no effect")
                dm.setHidden(wasHidden, other)
                expect(dm.isHidden(other) == wasHidden, "UI: hide/show cannot be undone")
                expect(dm.testSelections == selections, "UI: hide/show selected a device")
                done.append("Hide/show without selection")
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                done.append("Focus loss with menu open")
            },
            {
                expect(model.menuGeneration == generation, "UI: focus loss with menu open resets")
                expect(model.menuIsOpen, "UI: focus loss with menu open counts as closed")
                window.orderOut(nil)
                done.append("Closing the menu")
            },
            {
                expect(model.menuGeneration == generation + 1, "UI: closing does not reset")
                expect(!model.menuIsOpen, "UI: closed menu keeps animating")
                window.close()
                report["ui"] = done
                next()
            },
        ])
    }

    /// Like the content of `MenuBarExtra` in `SoundControlApp`: new identity after closing.
    private struct TestMenu: View {
        @Environment(AppModel.self) private var model
        var body: some View { MenuView().id(model.menuGeneration) }
    }

    /// 0.3 s of silence, then a 1 kHz sine at amplitude 0.05 up to 4 s, as 16-bit WAV.
    private static func writeTestTone(to url: URL) {
        let fs = 48000, seconds = 4, n = fs * seconds
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(fs)); u32(UInt32(fs * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n {
            let v = i < fs * 3 / 10 ? 0 : Int16(0.05 * 32767 * sin(2 * Double.pi * 1000 * Double(i) / Double(fs)))
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url)
    }
}
