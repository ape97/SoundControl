import CoreAudio
import Foundation

enum TapError: Error, CustomStringConvertible {
    case status(String, OSStatus)

    var description: String {
        switch self {
        case let .status(step, code): "\(step) failed (\(code))"
        }
    }
}

/// Intercepts an app's sound (the app is muted in the process) and plays it back processed – volume, sound profile,
/// balance, mono – through the desired output device. The tap and aggregate device are private and vanish with the process.
final class AppTap {
    private(set) var processObjects: [AudioObjectID]
    let outputUID: String
    private(set) var sampleRate: Double = 48000
    let shared: DSPShared

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapUUID = UUID()
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let state: DSPState
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 4096
    private let queue = DispatchQueue(label: "io.github.ape97.soundcontrol.tap", qos: .userInteractive)
    private var tapChannels = 2
    private var removeRateObserver: (() -> Void)?

    /// Called on the main thread when the device's sample rate changes (recompute filters).
    var onSampleRateChange: ((Double) -> Void)?

    init(processObjects: [AudioObjectID], outputUID: String, config: DSPConfig, silent: Bool = false) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        shared = DSPShared(config, silent: silent)
        state = DSPState(initialGain: config.gain)
        scratch = .allocate(capacity: Self.scratchFrames * 2)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func update(_ config: DSPConfig) {
        shared.config.withLock { $0 = config }
    }

    /// Pick up new or ended helper processes of the app, ideally without interruption.
    func updateProcesses(_ objects: [AudioObjectID]) -> Bool {
        guard objects != processObjects else { return true }
        let description = makeDescription(objects)
        description.uuid = tapUUID
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let status = AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size), &ref)
        guard status == noErr else { return false }
        processObjects = objects
        return true
    }

    private func makeDescription(_ objects: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Sound Control"
        return description
    }

    private func start() throws {
        let description = makeDescription(processObjects)
        description.uuid = tapUUID

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.status("Tap", status) }

        let format: AudioStreamBasicDescription = CA.get(tapID, CA.address(kAudioTapPropertyFormat), default: AudioStreamBasicDescription())
        if format.mChannelsPerFrame > 0 { tapChannels = Int(format.mChannelsPerFrame) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sound Control",
            kAudioAggregateDeviceUIDKey: "\(DeviceManager.ownUIDPrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.status("Aggregate", status) }

        sampleRate = CA.get(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate), default: Float64(48000))
        state.prepare(sampleRate: sampleRate)
        removeRateObserver = CA.observe(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate)) { [weak self] in
            guard let self, aggregateID != kAudioObjectUnknown else { return }
            let rate: Float64 = CA.get(aggregateID, CA.address(kAudioDevicePropertyNominalSampleRate), default: sampleRate)
            guard rate != sampleRate else { return }
            sampleRate = rate
            onSampleRateChange?(rate)
        }

        let shared = self.shared, state = self.state, scratch = self.scratch, tapChannels = self.tapChannels
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            AppTap.render(input: input, output: output, tapChannels: tapChannels, state: state, shared: shared, scratch: scratch)
        }
        guard status == noErr else { throw TapError.status("IOProc", status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.status("Start", status) }
    }

    func stop() {
        removeRateObserver?()
        removeRateObserver = nil
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Real-time path: no allocations, no blocking locks.
    /// The tap channels are at the end of the input buffers (after any inputs of the output device).
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               tapChannels: Int,
                               state: DSPState,
                               shared: DSPShared,
                               scratch: UnsafeMutablePointer<Float>) {
        shared.callbacks.add(1, ordering: .relaxed)
        let outs = UnsafeMutableAudioBufferListPointer(output)
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Clear the output first; afterwards only the first two channels are written.
        var outFrames = 0
        for ob in 0..<outs.count {
            guard let data = outs[ob].mData else { continue }
            memset(data, 0, Int(outs[ob].mDataByteSize))
            let nch = max(Int(outs[ob].mNumberChannels), 1)
            outFrames = max(outFrames, Int(outs[ob].mDataByteSize) / (MemoryLayout<Float32>.size * nch))
        }

        // Source left/right: collect as many channels from the end as the tap delivers.
        var collected = 0
        var i = ins.count - 1
        while i >= 0 && collected < tapChannels {
            collected += Int(ins[i].mNumberChannels)
            i -= 1
        }
        let b = i + 1
        guard b >= 0, b < ins.count, let lData = ins[b].mData?.assumingMemoryBound(to: Float32.self) else { return }
        let lStride = max(Int(ins[b].mNumberChannels), 1)
        var rData = lData, rStride = lStride, rOffset = 0
        if lStride > 1 {
            rOffset = 1
        } else if b + 1 < ins.count, let r = ins[b + 1].mData?.assumingMemoryBound(to: Float32.self) {
            rData = r; rStride = max(Int(ins[b + 1].mNumberChannels), 1)
        }
        let inFrames = Int(ins[b].mDataByteSize) / (MemoryLayout<Float32>.size * lStride)
        let frames = min(min(inFrames, outFrames), scratchFrames)
        guard frames > 0 else { return }

        let left = scratch, right = scratch + scratchFrames
        var inSq: Double = 0
        for f in 0..<frames {
            let l = lData[f * lStride], r = rData[f * rStride + rOffset]
            left[f] = l; right[f] = r
            inSq += Double(l * l + r * r) * 0.5
        }

        if inSq > 0, !shared.heard.load(ordering: .relaxed) { shared.heard.store(true, ordering: .relaxed) }
        state.process(left: left, right: right, frames: frames, shared: shared)

        var outSq: Double = 0, peak: Float = 0
        for f in 0..<frames {
            outSq += Double(left[f] * left[f] + right[f] * right[f]) * 0.5
            peak = max(peak, max(abs(left[f]), abs(right[f])))
        }
        shared.meter.withLockIfAvailable { m in
            m.inSquares += inSq; m.outSquares += outSq; m.frames += frames; m.outPeak = max(m.outPeak, peak)
        }
        if shared.silent.load(ordering: .relaxed) { return }

        // Distribute onto the first two output channels, mix down for a mono output.
        var written = 0
        for ob in 0..<outs.count where written < 2 {
            guard let out = outs[ob].mData?.assumingMemoryBound(to: Float32.self) else { continue }
            let nch = Int(outs[ob].mNumberChannels)
            guard nch > 0 else { continue }
            if nch == 1 && outs.count == 1 {
                for f in 0..<frames { out[f] = 0.5 * (left[f] + right[f]) }
                return
            }
            for c in 0..<min(nch, 2 - written) {
                let src = written + c == 0 ? left : right
                for f in 0..<frames { out[f * nch + c] = src[f] }
            }
            written += min(nch, 2 - written)
        }
    }
}
