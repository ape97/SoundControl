import AppKit
import CoreAudio
import Darwin
import Observation

/// An app known to Core Audio as an audio client – including all helper processes (e.g. WebContent for Safari).
struct AudioApp: Identifiable, Equatable {
    let id: String              // bundle ID of the app, key for stored settings
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool

    var icon: NSImage { AppIconCache.icon(for: pid, bundleID: id) }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for pid: pid_t, bundleID: String) -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let image = NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        let fixed = IconRaster.fixed(image, points: 24)
        cache[bundleID] = fixed
        return fixed
    }
}

/// Converts an icon once to exactly the display size (Retina 2×). App icons (layered since macOS 26)
/// would otherwise be downscaled from large templates on every redraw of the row – ~150× more expensive in testing.
enum IconRaster {
    static func fixed(_ image: NSImage, points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: points, height: points))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: rep.size)
        out.addRepresentation(rep)
        return out
    }
}

/// Returns the process ID of the "responsible" app (e.g. Safari for a WebContent process).
private let responsiblePID: (pid_t) -> pid_t = {
    typealias Fn = @convention(c) (pid_t) -> pid_t
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return { $0 }
    }
    let fn = unsafeBitCast(sym, to: Fn.self)
    return { pid in
        let r = fn(pid)
        return r > 0 ? r : pid
    }
}()

/// Observes Core Audio's audio process list and groups it into apps.
@MainActor
@Observable
final class AudioAppMonitor {
    private(set) var apps: [AudioApp] = []
    var onChange: (([AudioApp]) -> Void)?

    private var runningObservers: [AudioObjectID: () -> Void] = [:]
    private var pending = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        CA.observe(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }
        refresh()
    }

    /// Coalesces rapidly successive notifications.
    func scheduleRefresh() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        let objects = CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)

        // Keep the "is playing" observers up to date.
        let current = Set(objects)
        for (obj, remove) in runningObservers where !current.contains(obj) {
            remove()
            runningObservers[obj] = nil
        }
        for obj in objects where runningObservers[obj] == nil {
            runningObservers[obj] = CA.observe(obj, CA.address(kAudioProcessPropertyIsRunningOutput)) { [weak self] in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
        }

        let regularApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var byID: [String: AudioApp] = [:]
        var order: [String] = []

        for obj in objects {
            let pid: pid_t = CA.get(obj, CA.address(kAudioProcessPropertyPID), default: -1)
            guard pid > 0, pid != ownPID else { continue }
            let bundle = CA.string(obj, CA.address(kAudioProcessPropertyBundleID)) ?? ""
            guard let owner = Self.owningApp(pid: pid, bundleID: bundle, regular: regularApps),
                  let ownerID = owner.bundleIdentifier, owner.processIdentifier != ownPID else { continue }
            let running: UInt32 = CA.get(obj, CA.address(kAudioProcessPropertyIsRunningOutput), default: 0)

            if var app = byID[ownerID] {
                app.processObjects.append(obj)
                app.isPlaying = app.isPlaying || running != 0
                byID[ownerID] = app
            } else {
                byID[ownerID] = AudioApp(id: ownerID,
                                         name: (owner.localizedName ?? ownerID).trimmingCharacters(in: .controlCharacters.union(.whitespaces).union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}"))),
                                         pid: owner.processIdentifier,
                                         processObjects: [obj],
                                         isPlaying: running != 0)
                order.append(ownerID)
            }
        }

        let result = order.compactMap { byID[$0] }.map { app -> AudioApp in
            var a = app
            a.processObjects.sort()
            return a
        }.sorted { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if result != apps {
            apps = result
            onChange?(result)
        }
    }

    private static func owningApp(pid: pid_t, bundleID: String, regular: [NSRunningApplication]) -> NSRunningApplication? {
        let candidates = regular.compactMap { app -> AppOwnership.Candidate? in
            guard let id = app.bundleIdentifier else { return nil }
            return .init(pid: app.processIdentifier, bundleID: id, bundlePath: app.bundleURL?.path ?? "")
        }
        guard let hit = AppOwnership.owner(pid: pid, bundleID: bundleID, executablePath: Self.executablePath(pid),
                                           responsiblePID: responsiblePID(pid), among: candidates) else { return nil }
        return regular.first { $0.processIdentifier == hit.pid }
    }

    private static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }
}

/// Decides which regular (Dock) app an audio client process belongs to. Pure logic, covered by the self-test.
enum AppOwnership {
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleID: String
        let bundlePath: String
    }

    static func owner(pid: pid_t, bundleID: String, executablePath: String, responsiblePID: pid_t,
                      among regular: [Candidate]) -> Candidate? {
        if let app = regular.first(where: { $0.pid == pid }) { return app }
        if let app = regular.first(where: { $0.pid == responsiblePID }) { return app }
        // Helper processes such as "com.google.Chrome.helper" belong to the app with the matching prefix.
        if !bundleID.isEmpty, let app = regular.first(where: { bundleID.hasPrefix($0.bundleID + ".") }) { return app }
        // Helpers living inside an app bundle whose responsible PID is unavailable (e.g. root-owned VM processes of a
        // virtualization app, whose bundle ID differs from the app's). The innermost enclosing app wins.
        return regular
            .filter { !$0.bundlePath.isEmpty && executablePath.hasPrefix($0.bundlePath + "/") }
            .max { $0.bundlePath.count < $1.bundlePath.count }
    }
}
