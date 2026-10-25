import AppKit
import CoreAudio
import Darwin
import Observation

/// An audio client as shown in the list: a Dock app including all its helper processes (e.g. WebContent for Safari),
/// or a standalone process without a Dock app (a Windows program under Wine, a background player).
struct AudioApp: Identifiable, Equatable {
    let id: String              // bundle ID of the app (or a standalone key), key for stored settings
    let name: String
    let pid: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
    /// Where the icon of a standalone entry comes from: an app bundle path or a bundle ID. Empty for Dock apps.
    var iconSource = ""

    var icon: NSImage { AppIconCache.icon(for: pid, bundleID: id, source: iconSource) }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for pid: pid_t, bundleID: String, source: String = "") -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let image = source.isEmpty
            ? NSRunningApplication(processIdentifier: pid)?.icon ?? appIcon(bundleID)
            : source.hasPrefix("/") ? NSWorkspace.shared.icon(forFile: source) : appIcon(source)
        let fixed = IconRaster.fixed(image ?? NSWorkspace.shared.icon(for: .applicationBundle), points: 24)
        cache[bundleID] = fixed
        return fixed
    }

    /// Icon of the installed app with this bundle ID or, failing that, of its closest parent ID
    /// ("com.codeweavers.CrossOver.wineloader" → CrossOver).
    private static func appIcon(_ bundleID: String) -> NSImage? {
        var parts = bundleID.split(separator: ".")
        while parts.count >= 2 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            parts.removeLast()
        }
        return nil
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
            guard let entry = Self.entry(pid: pid, bundleID: bundle, regular: regularApps) else { continue }
            let running: UInt32 = CA.get(obj, CA.address(kAudioProcessPropertyIsRunningOutput), default: 0)

            if var app = byID[entry.id] {
                app.processObjects.append(obj)
                app.isPlaying = app.isPlaying || running != 0
                byID[entry.id] = app
            } else {
                var app = entry
                app.processObjects = [obj]
                app.isPlaying = running != 0
                byID[entry.id] = app
                order.append(entry.id)
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

    /// The list entry a process belongs to (without process objects yet), or nil for system processes.
    private static func entry(pid: pid_t, bundleID: String, regular: [NSRunningApplication]) -> AudioApp? {
        let candidates = regular.compactMap { app -> AppOwnership.Candidate? in
            guard let id = app.bundleIdentifier else { return nil }
            return .init(pid: app.processIdentifier, bundleID: id, bundlePath: app.bundleURL?.path ?? "")
        }
        let path = Self.executablePath(pid)
        switch AppOwnership.resolve(pid: pid, bundleID: bundleID, executablePath: path,
                                    command: AppOwnership.isWine(bundleID, path) ? Self.commandName(pid) : "",
                                    responsiblePID: responsiblePID(pid), among: candidates) {
        case .app(let hit):
            guard let owner = regular.first(where: { $0.processIdentifier == hit.pid }) else { return nil }
            return AudioApp(id: hit.bundleID, name: clean(owner.localizedName ?? hit.bundleID), pid: hit.pid,
                            processObjects: [], isPlaying: false)
        case .standalone(let id, let name, let icon):
            return AudioApp(id: id, name: clean(name), pid: pid, processObjects: [], isPlaying: false, iconSource: icon)
        case nil:
            return nil
        }
    }

    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .controlCharacters.union(.whitespaces)
            .union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}")))
    }

    private static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }

    /// The process's argv[0]. Wine replaces it with the Windows path of the program ("C:\Games\Game.exe"), while the
    /// executable itself is only the Wine loader.
    private static func commandName(_ pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        // Layout: argc, executable path, zero padding, argv[0], …
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        let start = i
        while i < size, buffer[i] != 0 { i += 1 }
        return String(decoding: buffer[start..<i], as: UTF8.self)
    }
}

/// Decides which list entry an audio client process belongs to. Pure logic, covered by the self-test.
/// A process is never filed under an app it does not really belong to: a tap on that app would otherwise mute or
/// change it with the app's settings (e.g. a game started from Terminal while Terminal is muted).
enum AppOwnership {
    struct Candidate: Equatable {
        let pid: pid_t
        let bundleID: String
        let bundlePath: String
    }

    enum Owner: Equatable {
        case app(Candidate)
        /// A process without a Dock app: own entry, own settings. `icon` is an app bundle path or a bundle ID.
        case standalone(id: String, name: String, icon: String)
    }

    /// Wine's own service processes, never a sound source of their own.
    private static let wineServices: Set<String> = [
        "winedevice.exe", "services.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe", "conhost.exe",
        "wineboot.exe", "start.exe", "winemenubuilder.exe", "rundll32.exe",
    ]

    /// A process of a Wine variant (CrossOver, Wine, Whisky, …): only for these the command name is looked up.
    static func isWine(_ bundleID: String, _ executablePath: String) -> Bool {
        bundleID.lowercased().contains("wine") || (executablePath as NSString).lastPathComponent.lowercased().hasPrefix("wine")
    }

    /// `command` is argv[0], needed only for Wine processes (empty otherwise).
    static func resolve(pid: pid_t, bundleID: String, executablePath: String, command: String = "", responsiblePID: pid_t,
                        among regular: [Candidate]) -> Owner? {
        // Windows programs run as copies of the Wine loader, all with the same bundle ID and sometimes even as Dock apps.
        // Each one is its own entry, whoever started it.
        let program = command.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        if program.lowercased().hasSuffix(".exe") {
            guard !wineServices.contains(program.lowercased()) else { return nil }
            let name = String(program.dropLast(4))
            return .standalone(id: "exe:" + name, name: name, icon: bundleID)
        }
        if let app = regular.first(where: { $0.pid == pid }) { return .app(app) }

        if let app = regular.first(where: { $0.pid == responsiblePID }), belongs(bundleID, executablePath, to: app) {
            return .app(app)
        }
        // Helper processes such as "com.google.Chrome.helper" belong to the app with the matching prefix.
        if !bundleID.isEmpty, let app = regular.first(where: { hasPrefix(bundleID, $0.bundleID) }) { return .app(app) }
        // Helpers living inside an app bundle whose responsible PID is unavailable (e.g. root-owned VM processes of a
        // virtualization app, whose bundle ID differs from the app's). The innermost enclosing app wins.
        if let app = regular
            .filter({ !$0.bundlePath.isEmpty && executablePath.hasPrefix($0.bundlePath + "/") })
            .max(by: { $0.bundlePath.count < $1.bundlePath.count }) {
            return .app(app)
        }
        return standalone(bundleID: bundleID, executablePath: executablePath)
    }

    /// A process started by an app belongs to it if it is the app's own code or a generic tool (a command-line player
    /// started from Terminal, a system helper). A process with another vendor's bundle ID is a program of its own.
    private static func belongs(_ bundleID: String, _ path: String, to app: Candidate) -> Bool {
        bundleID.isEmpty || bundleID.hasPrefix("com.apple.") || bundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
            || hasPrefix(bundleID, app.bundleID) || (!app.bundlePath.isEmpty && path.hasPrefix(app.bundlePath + "/"))
    }

    private static func hasPrefix(_ bundleID: String, _ appID: String) -> Bool {
        bundleID.lowercased().hasPrefix(appID.lowercased() + ".")
    }

    /// Own entry for a process without a Dock app, unless it is part of the system.
    private static func standalone(bundleID: String, executablePath: String) -> Owner? {
        guard !executablePath.isEmpty, !bundleID.hasPrefix("com.apple."),
              !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/Library/Audio/"].contains(where: executablePath.hasPrefix)
        else { return nil }
        // Name and icon of the outermost app bundle the executable lives in, else the executable itself.
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: false)
        if let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = parts[...index].joined(separator: "/")
            let name = String(parts[index].dropLast(4))
            return .standalone(id: bundleID.isEmpty ? "path:" + bundlePath : bundleID, name: name, icon: bundlePath)
        }
        let name = (executablePath as NSString).lastPathComponent
        return .standalone(id: bundleID.isEmpty ? "path:" + executablePath : bundleID, name: name, icon: bundleID)
    }
}
