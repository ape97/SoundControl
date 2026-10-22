import AudioToolbox
import CoreAudio
import Foundation
import Observation

enum AudioDirection {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let direction: AudioDirection

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") { return "beats.headphones" }
        if lower.contains("homepod") { return "homepod.fill" }
        if lower.contains("iphone") { return "iphone" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            if direction == .input { return "mic.fill" }
            // The built-in headphone jack is localized; German macOS calls it "Kopfhörer".
            return lower.contains("kopfhörer") || lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return direction == .input ? "headset" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire:
            return direction == .input ? "mic" : "hifispeaker.fill"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
            return "waveform"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "iphone"
        default:
            return direction == .input ? "mic" : "speaker.wave.2.fill"
        }
    }
}

/// Device list, default devices and system volume of output and input.
@MainActor
@Observable
final class DeviceManager {
    nonisolated static let ownUIDPrefix = "io.github.ape97.soundcontrol"

    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioObjectID = kAudioObjectUnknown
    private(set) var defaultInput: AudioObjectID = kAudioObjectUnknown

    var outputVolume: Float = 0
    var outputMuted = false
    var inputVolume: Float = 0
    var inputMuted = false
    private(set) var outputHasVolume = true
    private(set) var inputHasVolume = true

    /// Sample rate and possible rates of the current devices.
    private(set) var outputRate: Double = 0
    private(set) var inputRate: Double = 0
    private(set) var outputRates: [Double] = []
    private(set) var inputRates: [Double] = []
    /// Desired fixed sample rate per device UID; if there is no entry, macOS decides ("Automatic").
    private(set) var preferredRates: [String: Double] = [:]

    /// Called after every change of the default output device or the device list.
    var onOutputsChange: (() -> Void)?
    /// Called after every change of the output volume (also by keyboard or other apps).
    var onOutputVolumeChange: (() -> Void)?

    private var volumeObservers: [() -> Void] = []
    private var knownUIDs: Set<String> = []
    private static let ratesKey = "preferredSampleRates"

    /// Hidden devices ("out:<uid>" / "in:<uid>"), listed under "Hidden" in the device list.
    /// Snapshot: only from `--hidden <name part>`, nothing is stored.
    private(set) var hiddenKeys: Set<String> = []
    private static let hiddenKey = "hiddenDevices"

    init() {
        if !Runtime.isDemo { preferredRates = UserDefaults.standard.dictionary(forKey: Self.ratesKey) as? [String: Double] ?? [:] }
        if !Runtime.headless { hiddenKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []) }
        refreshDevices()
        if Runtime.isSnapshot, let part = Runtime.value(after: "--hidden") {
            hiddenKeys = Set((outputs + inputs).filter { $0.name.localizedCaseInsensitiveContains(part) }.map(Self.hideKey))
        }
        refreshDefaults()
        if Runtime.isDemo { return }   // invented devices: no hardware observers
        let sys = CA.system
        CA.observe(sys, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        CA.observe(sys, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDefaults() }
        }
        CA.observe(sys, CA.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDefaults() }
        }
    }

    var currentOutput: AudioDevice? { outputs.first { $0.id == defaultOutput } }
    var outputUIDs: Set<String> { Set(outputs.map(\.uid)) }
    var currentInput: AudioDevice? { inputs.first { $0.id == defaultInput } }

    // MARK: Devices

    func refreshDevices() {
        if Runtime.isDemo { outputs = Self.demoDevices(.output); inputs = Self.demoDevices(.input); return }
        let ids = CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
        var outs: [AudioDevice] = []
        var ins: [AudioDevice] = []
        for id in ids {
            guard let uid = CA.string(id, CA.address(kAudioDevicePropertyDeviceUID)),
                  !uid.hasPrefix(Self.ownUIDPrefix),
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { continue }
            let hidden: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyIsHidden), default: 0)
            if hidden != 0 { continue }
            let name = CA.string(id, CA.address(kAudioObjectPropertyName)) ?? uid
            let transport: UInt32 = CA.get(id, CA.address(kAudioDevicePropertyTransportType), default: 0)
            if Self.streamCount(id, .output) > 0 {
                outs.append(AudioDevice(id: id, uid: uid, name: name, transport: transport, direction: .output))
            }
            if Self.streamCount(id, .input) > 0 {
                ins.append(AudioDevice(id: id, uid: uid, name: name, transport: transport, direction: .input))
            }
        }
        let order: (AudioDevice, AudioDevice) -> Bool = { a, b in
            let ab = a.transport == kAudioDeviceTransportTypeBuiltIn, bb = b.transport == kAudioDeviceTransportTypeBuiltIn
            if ab != bb { return ab }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let sortedOuts = outs.sorted(by: order), sortedIns = ins.sorted(by: order)
        let changed = sortedOuts != outputs
        if changed { outputs = sortedOuts }
        if sortedIns != inputs { inputs = sortedIns }

        // Newly connected devices get their stored sample rate back.
        let all = outs + ins
        for device in all where Features.sampleRate && !knownUIDs.contains(device.uid) {
            if let rate = preferredRates[device.uid] { Self.applyRate(rate, to: device.id) }
        }
        knownUIDs = Set(all.map(\.uid))
        if changed { onOutputsChange?() }
    }

    private static func streamCount(_ id: AudioObjectID, _ dir: AudioDirection) -> Int {
        CA.array(id, CA.address(kAudioDevicePropertyStreams, scope: dir.scope), of: AudioStreamID.self).count
    }

    /// Demo mode: generic Apple-style devices with fixed state (never reads the real hardware).
    private static func demoDevices(_ dir: AudioDirection) -> [AudioDevice] {
        let list: [(String, UInt32)] = dir == .output
            ? [("MacBook Pro Speakers", kAudioDeviceTransportTypeBuiltIn), ("AirPods Pro", kAudioDeviceTransportTypeBluetooth),
               ("Studio Display", kAudioDeviceTransportTypeDisplayPort), ("AirPlay", kAudioDeviceTransportTypeAirPlay)]
            : [("MacBook Pro Microphone", kAudioDeviceTransportTypeBuiltIn), ("AirPods Pro", kAudioDeviceTransportTypeBluetooth),
               ("Studio Display Microphone", kAudioDeviceTransportTypeDisplayPort)]
        return list.enumerated().map { i, d in
            AudioDevice(id: AudioObjectID((dir == .output ? 80000 : 81000) + i), uid: "demo-\(dir == .output ? "out" : "in")-\(i)",
                        name: d.0, transport: d.1, direction: dir)
        }
    }

    private func setUpDemoDefaults() {
        // `--airplay` (as in the other snapshots) makes the AirPlay target the current output.
        let airplay = Runtime.arguments.contains("--airplay")
        defaultOutput = outputs[airplay ? 3 : 0].id
        defaultInput = inputs[0].id
        outputVolume = 1; outputMuted = false; inputVolume = 0.62; inputMuted = false
        outputRate = 48000; inputRate = 48000
        outputRates = [44100, 48000, 96000]; inputRates = [44100, 48000]
    }

    private func refreshDefaults() {
        if Runtime.isDemo { setUpDemoDefaults(); return }
        let out: AudioObjectID = CA.get(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), default: kAudioObjectUnknown)
        let inp: AudioObjectID = CA.get(CA.system, CA.address(kAudioHardwarePropertyDefaultInputDevice), default: kAudioObjectUnknown)
        let outChanged = out != defaultOutput
        defaultOutput = out
        defaultInput = inp
        bindVolumeObservers()
        readVolumes()
        if outChanged { onOutputsChange?() }
    }

    /// Self-test: counts selections instead of switching (the real output stays untouched).
    @ObservationIgnored private(set) var testSelections = 0

    func select(_ device: AudioDevice) {
        if Runtime.isDemo { return }
        if Runtime.isSelfTest { testSelections += 1; return }
        CA.set(CA.system, CA.address(device.direction.defaultSelector), device.id)
        if device.direction == .output {
            // System sounds follow the output, as with the selection in Control Center.
            CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device.id)
        }
        refreshDefaults()
    }

    // MARK: Hiding

    private static func hideKey(_ d: AudioDevice) -> String { (d.direction == .output ? "out:" : "in:") + d.uid }

    func isHidden(_ device: AudioDevice) -> Bool { hiddenKeys.contains(Self.hideKey(device)) }

    func setHidden(_ hidden: Bool, _ device: AudioDevice) {
        if hidden { hiddenKeys.insert(Self.hideKey(device)) } else { hiddenKeys.remove(Self.hideKey(device)) }
        if !Runtime.headless { UserDefaults.standard.set(hiddenKeys.sorted(), forKey: Self.hiddenKey) }
    }

    func showAllDevices() {
        hiddenKeys.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }

    // MARK: Volume

    private func bindVolumeObservers() {
        volumeObservers.forEach { $0() }
        volumeObservers.removeAll()
        for (device, dir) in [(defaultOutput, AudioDirection.output), (defaultInput, AudioDirection.input)]
        where device != kAudioObjectUnknown {
            volumeObservers.append(CA.observe(device, CA.address(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
                MainActor.assumeIsolated { self?.readRates() }
            })
            let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
            for sel in selectors {
                for element in [kAudioObjectPropertyElementMain, 1, 2] {
                    let addr = CA.address(sel, scope: dir.scope, element: element)
                    guard CA.has(device, addr) else { continue }
                    volumeObservers.append(CA.observe(device, addr) { [weak self] in
                        MainActor.assumeIsolated { self?.readVolumes() }
                    })
                }
            }
        }
    }

    func readVolumes() {
        if Runtime.isDemo { return }
        let (ov, oh) = Self.volume(defaultOutput, .output)
        let (iv, ih) = Self.volume(defaultInput, .input)
        if abs(ov - outputVolume) > 0.001 { outputVolume = ov }
        if abs(iv - inputVolume) > 0.001 { inputVolume = iv }
        outputHasVolume = oh
        inputHasVolume = ih
        let om = Self.muted(defaultOutput, .output), im = Self.muted(defaultInput, .input)
        if om != outputMuted { outputMuted = om }
        if im != inputMuted { inputMuted = im }
        readRates()
        onOutputVolumeChange?()
    }

    // MARK: Sample rate

    func readRates() {
        if Runtime.isDemo { return }
        let (orate, orates) = Self.rates(defaultOutput)
        let (irate, irates) = Self.rates(defaultInput)
        if orate != outputRate { outputRate = orate }
        if irate != inputRate { inputRate = irate }
        if orates != outputRates { outputRates = orates }
        if irates != inputRates { inputRates = irates }
    }

    func preferredRate(_ dir: AudioDirection) -> Double? {
        guard let uid = (dir == .output ? currentOutput : currentInput)?.uid else { return nil }
        return preferredRates[uid]
    }

    /// nil = Automatic: Sound Control does not intervene and macOS or the apps determine the rate.
    func setPreferredRate(_ rate: Double?, _ dir: AudioDirection) {
        guard let device = dir == .output ? currentOutput : currentInput else { return }
        preferredRates[device.uid] = rate
        UserDefaults.standard.set(preferredRates, forKey: Self.ratesKey)
        if let rate { Self.applyRate(rate, to: device.id) }
        readRates()
    }

    /// Advanced features switched on: apply stored rates to all connected devices.
    /// When switched off, the current rate stays (there is no "previous" value that macOS would reliably know).
    func applyPreferredRates() {
        guard Features.sampleRate else { return }
        for device in outputs + inputs {
            if let rate = preferredRates[device.uid] { Self.applyRate(rate, to: device.id) }
        }
        readRates()
    }

    /// All devices back to "Automatic"; the current rate stays until macOS or an app changes it.
    func resetRates() {
        preferredRates.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.ratesKey)
        readRates()
    }

    private static func applyRate(_ rate: Double, to device: AudioObjectID) {
        let addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        let current: Float64 = CA.get(device, addr, default: 0)
        guard current != rate, CA.isSettable(device, addr) else { return }
        CA.set(device, addr, Float64(rate))
    }

    private static func rates(_ device: AudioObjectID) -> (Double, [Double]) {
        guard device != kAudioObjectUnknown else { return (0, []) }
        let current: Float64 = CA.get(device, CA.address(kAudioDevicePropertyNominalSampleRate), default: 0)
        let ranges = CA.array(device, CA.address(kAudioDevicePropertyAvailableNominalSampleRates), of: AudioValueRange.self)
        let standard: [Double] = [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var list = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { list.insert(r.mMinimum) }
            else { standard.filter { $0 >= r.mMinimum && $0 <= r.mMaximum }.forEach { list.insert($0) } }
        }
        return (current, list.sorted())
    }

    func setVolume(_ value: Float, _ dir: AudioDirection) {
        let device = dir == .output ? defaultOutput : defaultInput
        let v = max(0, min(1, value))
        if dir == .output { outputVolume = v } else { inputVolume = v }
        let main = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: dir.scope)
        if !(CA.has(device, main) && CA.set(device, main, Float32(v)) == noErr) {
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                let a = CA.address(kAudioDevicePropertyVolumeScalar, scope: dir.scope, element: element)
                if CA.has(device, a), CA.isSettable(device, a) { CA.set(device, a, Float32(v)) }
            }
        }
        // Raising the volume lifts the mute, as with the volume keys.
        if v > 0, dir == .output ? outputMuted : inputMuted { setMuted(false, dir) }
    }

    func setMuted(_ muted: Bool, _ dir: AudioDirection) {
        let device = dir == .output ? defaultOutput : defaultInput
        if dir == .output { outputMuted = muted } else { inputMuted = muted }
        let a = CA.address(kAudioDevicePropertyMute, scope: dir.scope)
        if CA.has(device, a), CA.isSettable(device, a) {
            CA.set(device, a, UInt32(muted ? 1 : 0))
        }
    }

    private static func volume(_ device: AudioObjectID, _ dir: AudioDirection) -> (Float, Bool) {
        guard device != kAudioObjectUnknown else { return (0, false) }
        let main = CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: dir.scope)
        if CA.has(device, main) { return (CA.get(device, main, default: Float32(0)), true) }
        for element in [kAudioObjectPropertyElementMain, 1] {
            let a = CA.address(kAudioDevicePropertyVolumeScalar, scope: dir.scope, element: element)
            if CA.has(device, a) { return (CA.get(device, a, default: Float32(0)), true) }
        }
        return (1, false)
    }

    private static func muted(_ device: AudioObjectID, _ dir: AudioDirection) -> Bool {
        let a = CA.address(kAudioDevicePropertyMute, scope: dir.scope)
        guard device != kAudioObjectUnknown, CA.has(device, a) else { return false }
        let v: UInt32 = CA.get(device, a, default: 0)
        return v != 0
    }
}
