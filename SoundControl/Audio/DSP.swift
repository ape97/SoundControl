import Foundation
import Synchronization

/// Ready-made sound profiles per app. Each profile is a short chain of biquad filters (RBJ cookbook),
/// night mode additionally with a compressor.
enum SoundProfile: String, Codable, CaseIterable, Identifiable {
    case flat, bassBoost, bassCut, treble, voice, loudness, clarity, night

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Off"
        case .bassBoost: "Bass Boost"
        case .bassCut: "Less Bass"
        case .treble: "Treble"
        case .voice: "Voice"
        case .loudness: "Loudness"
        case .clarity: "Clarity"
        case .night: "Night Mode"
        }
    }

    var symbol: String {
        switch self {
        case .flat: "slash.circle"
        case .bassBoost: "speaker.wave.3.fill"
        case .bassCut: "speaker.wave.1.fill"
        case .treble: "music.note"
        case .voice: "person.wave.2.fill"
        case .loudness: "dial.high.fill"
        case .clarity: "sparkles"
        case .night: "moon.fill"
        }
    }

    var detail: String {
        switch self {
        case .flat: "Unchanged"
        case .bassBoost: "Deep, punchy lows"
        case .bassCut: "Removes boominess"
        case .treble: "More sparkle and detail"
        case .voice: "Clearer speech"
        case .loudness: "Full sound at low volume"
        case .clarity: "Crisper mids and highs"
        case .night: "Quiet parts louder, loud parts softer"
        }
    }

    fileprivate var filters: [Filter] {
        switch self {
        case .flat: []
        case .bassBoost: [.lowShelf(f: 105, db: 8), .peak(f: 55, db: 2, q: 0.9)]
        case .bassCut: [.highPass(f: 45, q: 0.707), .lowShelf(f: 160, db: -9)]
        case .treble: [.highShelf(f: 5200, db: 6), .peak(f: 11000, db: 1.5, q: 0.8)]
        case .voice: [.highPass(f: 110, q: 0.707), .lowShelf(f: 300, db: -3), .peak(f: 2800, db: 5, q: 0.9), .highShelf(f: 9500, db: -2)]
        case .loudness: [.lowShelf(f: 90, db: 6), .highShelf(f: 8500, db: 4)]
        case .clarity: [.lowShelf(f: 220, db: -2), .peak(f: 3200, db: 3, q: 0.8), .highShelf(f: 10000, db: 3.5)]
        case .night: [.highPass(f: 60, q: 0.707), .peak(f: 2500, db: 2.5, q: 0.9)]
        }
    }

    var usesCompressor: Bool { self == .night }
}

fileprivate enum Filter {
    case lowShelf(f: Double, db: Double)
    case highShelf(f: Double, db: Double)
    case peak(f: Double, db: Double, q: Double)
    case highPass(f: Double, q: Double)

    func coefficients(sampleRate fs: Double) -> Biquad {
        func shelf(_ f0: Double, _ db: Double, high: Bool) -> Biquad {
            let a = pow(10, db / 40), w = 2 * Double.pi * f0 / fs, c = cos(w)
            let alpha = sin(w) / 2 * sqrt(2.0)       // slope S = 1
            let s = 2 * sqrt(a) * alpha
            if high {
                return Biquad(b0: a * ((a + 1) + (a - 1) * c + s), b1: -2 * a * ((a - 1) + (a + 1) * c),
                              b2: a * ((a + 1) + (a - 1) * c - s), a0: (a + 1) - (a - 1) * c + s,
                              a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - s)
            }
            return Biquad(b0: a * ((a + 1) - (a - 1) * c + s), b1: 2 * a * ((a - 1) - (a + 1) * c),
                          b2: a * ((a + 1) - (a - 1) * c - s), a0: (a + 1) + (a - 1) * c + s,
                          a1: -2 * ((a - 1) + (a + 1) * c), a2: (a + 1) + (a - 1) * c - s)
        }
        switch self {
        case let .lowShelf(f, db): return shelf(f, db, high: false)
        case let .highShelf(f, db): return shelf(f, db, high: true)
        case let .peak(f0, db, q):
            let a = pow(10, db / 40), w = 2 * Double.pi * f0 / fs, c = cos(w), alpha = sin(w) / (2 * q)
            return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
        case let .highPass(f0, q):
            let w = 2 * Double.pi * f0 / fs, c = cos(w), alpha = sin(w) / (2 * q)
            return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
        }
    }
}

/// Normalized biquad coefficients (a0 = 1).
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    init() {}

    fileprivate init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }
}

/// Everything the real-time processing of one app needs. Small and copyable.
struct DSPConfig {
    static let maxStages = 4

    var gain: Float = 1
    var balance: Float = 0          // −1 left … +1 right
    var mono = false
    var compressor = false
    var stageCount = 0
    var stages: (Biquad, Biquad, Biquad, Biquad) = (Biquad(), Biquad(), Biquad(), Biquad())
    /// Changes with every new profile so the real-time part resets its filter states.
    var profileToken = 0

    init() {}

    init(gain: Float, balance: Float, mono: Bool, profile: SoundProfile, sampleRate: Double) {
        self.gain = gain
        self.balance = max(-1, min(1, balance))
        self.mono = mono
        compressor = profile.usesCompressor
        let filters = profile.filters.prefix(Self.maxStages).map { $0.coefficients(sampleRate: max(sampleRate, 8000)) }
        stageCount = filters.count
        withUnsafeMutableBytes(of: &stages) { raw in
            let p = raw.bindMemory(to: Biquad.self)
            for (i, f) in filters.enumerated() { p[i] = f }
        }
        profileToken = profile.hashValue ^ Int(sampleRate)
    }

    func stage(_ i: Int) -> Biquad {
        withUnsafeBytes(of: stages) { $0.bindMemory(to: Biquad.self)[i] }
    }
}

/// Level measurement for the self-test (RMS over the last buffers).
struct Meter {
    var inSquares: Double = 0
    var outSquares: Double = 0
    var frames: Int = 0
    var outPeak: Float = 0

    var inRMS: Double { frames > 0 ? sqrt(inSquares / Double(frames)) : 0 }
    var outRMS: Double { frames > 0 ? sqrt(outSquares / Double(frames)) : 0 }
}

/// Link between the main thread and the real-time thread. The real-time thread never waits:
/// if the lock is currently held, it simply uses the most recently read values.
final class DSPShared: Sendable {
    let config: Mutex<DSPConfig>
    let meter = Mutex(Meter())
    /// In the self-test: output nothing, only measure.
    let silent: Atomic<Bool>

    init(_ config: DSPConfig, silent: Bool = false) {
        self.config = Mutex(config)
        self.silent = Atomic(silent)
    }
}

/// State owned only by the real-time thread. Fixed memory blocks, no allocation in the render path.
final class DSPState: @unchecked Sendable {
    var config = DSPConfig()
    var token = -1
    var gain: Float
    var limiterEnv: Float = 0
    var compEnv: Float = 0
    var compGain: Float = 1
    let z: UnsafeMutablePointer<Float>       // two states per stage and channel: 4 × 2 × 2
    var limiterRelease: Float = 0.9996
    var compAttack: Float = 0.99
    var compRelease: Float = 0.9995

    init(initialGain: Float) {
        gain = initialGain
        z = .allocate(capacity: DSPConfig.maxStages * 4)
        z.initialize(repeating: 0, count: DSPConfig.maxStages * 4)
    }

    deinit { z.deallocate() }

    func prepare(sampleRate: Double) {
        let fs = Float(max(sampleRate, 8000))
        limiterRelease = exp(-1 / (0.06 * fs))
        compAttack = exp(-1 / (0.005 * fs))
        compRelease = exp(-1 / (0.2 * fs))
    }

    /// Processes one block of stereo samples in place.
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int, shared: DSPShared) {
        if let fresh = shared.config.withLockIfAvailable({ $0 }) {
            config = fresh
            if fresh.profileToken != token {
                token = fresh.profileToken
                z.update(repeating: 0, count: DSPConfig.maxStages * 4)
                compGain = 1
            }
        }
        let c = config
        let target = c.gain
        let step = frames > 0 ? (target - gain) / Float(frames) : 0
        let balL = min(1, 1 - c.balance), balR = min(1, 1 + c.balance)
        let threshold: Float = 0.97

        // Compressor (night mode): −30 dB threshold, 3:1 ratio, +9 dB make-up gain.
        let compThreshDB: Float = -30, compRatio: Float = 3, makeup: Float = 2.8

        for f in 0..<frames {
            var l = left[f], r = right[f]
            if c.mono { let m = 0.5 * (l + r); l = m; r = m }

            var s = 0
            while s < c.stageCount {
                let q = c.stage(s)
                let zi = s * 4
                let yl = q.b0 * l + z[zi]
                z[zi] = q.b1 * l - q.a1 * yl + z[zi + 1]
                z[zi + 1] = q.b2 * l - q.a2 * yl
                let yr = q.b0 * r + z[zi + 2]
                z[zi + 2] = q.b1 * r - q.a1 * yr + z[zi + 3]
                z[zi + 3] = q.b2 * r - q.a2 * yr
                l = yl; r = yr
                s += 1
            }

            if c.compressor {
                let level = max(abs(l), abs(r))
                let coeff = level > compEnv ? compAttack : compRelease
                compEnv = coeff * compEnv + (1 - coeff) * level
                if f & 31 == 0 {
                    let db = 20 * log10(max(compEnv, 1e-6))
                    let over = db - compThreshDB
                    compGain = over > 0 ? pow(10, -(over - over / compRatio) / 20) : 1
                }
                l *= compGain * makeup; r *= compGain * makeup
            }

            gain += step
            l *= gain * balL
            r *= gain * balR

            // Limiter: instant attack, soft release – prevents clipping when boosting.
            let peak = max(abs(l), abs(r))
            limiterEnv = peak > limiterEnv ? peak : limiterEnv * limiterRelease
            if limiterEnv > threshold {
                let g = threshold / limiterEnv
                l *= g; r *= g
            }
            left[f] = l
            right[f] = r
        }
        gain = target
        // Avoid denormals when long silence follows.
        if limiterEnv < 1e-9 { limiterEnv = 0 }
        if compEnv < 1e-9 { compEnv = 0 }
    }
}
