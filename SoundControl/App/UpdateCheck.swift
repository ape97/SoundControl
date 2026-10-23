import AppKit
import Observation
import SwiftUI

/// Optional update notice (Settings → Check for Updates, off by default).
///
/// Asks GitHub for the latest release at most once a day – on launch, when the menu opens and after waking, never on a
/// timer – and only compares version numbers. Nothing is downloaded or replaced: "Download" opens the release page.
/// Only published releases count (`releases/latest` skips drafts and pre-releases), so commits never trigger a notice.
/// Self-contained on purpose: the same file works in every app of this family; the repository is the executable's name.
@MainActor
@Observable
final class UpdateCheck {
    static let shared = UpdateCheck()

    nonisolated static let owner = "ape97"
    nonisolated static let interval: TimeInterval = 24 * 60 * 60
    /// After a failed check (offline, rate limit) try again sooner than a day.
    nonisolated static let retryAfterFailure: TimeInterval = 60 * 60

    enum Status: Equatable { case idle, checking, failed }

    private(set) var enabled: Bool
    private(set) var status = Status.idle
    private(set) var latest: String?
    private(set) var lastCheck: Date?
    private(set) var skipped: String?
    @ObservationIgnored private var pageURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    nonisolated static var repository: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "" }
    nonisolated static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    nonisolated static var apiURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")! }
    nonisolated static var releasesPage: URL { URL(string: "https://github.com/\(owner)/\(repository)/releases/latest")! }

    /// The version to offer: newer than the running one and not skipped.
    var available: String? {
        guard let latest, Self.isNewer(latest, than: Self.current), latest != skipped else { return nil }
        return latest
    }

    private init() {
        // Snapshots and self-test never touch the real settings and never go online.
        if Runtime.headless {
            let name = Bundle.main.bundleIdentifier! + ".update-scratch"
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        } else {
            defaults = .standard
        }
        enabled = defaults.bool(forKey: Keys.enabled)
        latest = defaults.string(forKey: Keys.latest)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        skipped = defaults.string(forKey: Keys.skipped)
        pageURL = defaults.string(forKey: Keys.page).flatMap(URL.init(string:))
        if Runtime.isDemo { prepareDemo() }
    }

    private nonisolated enum Keys {
        static let enabled = "updateCheckEnabled", latest = "updateLatest", lastCheck = "updateLastCheck"
        static let skipped = "updateSkipped", page = "updatePage"
    }

    /// Launch: check if due, and again after every wake (the menu may stay closed for days).
    func start() {
        guard !Runtime.headless, wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateCheck.shared.checkIfDue() }
        }
        checkIfDue()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Keys.enabled)
        if value { checkIfDue() }
    }

    func checkIfDue() {
        guard Self.isDue(enabled: enabled, lastCheck: lastCheck, now: Date()) else { return }
        checkNow()
    }

    func checkNow() {
        guard !Runtime.headless, status != .checking else { return }
        status = .checking
        Self.fetchLatest { result in
            DispatchQueue.main.async { MainActor.assumeIsolated { UpdateCheck.shared.finish(result) } }
        }
    }

    private func finish(_ result: Result<Release, Error>) {
        switch result {
        case .success(let release):
            status = .idle
            latest = release.version
            pageURL = release.page
            lastCheck = Date()
            defaults.set(release.version, forKey: Keys.latest)
            defaults.set(release.page.absoluteString, forKey: Keys.page)
        case .failure:
            status = .failed
            lastCheck = Date().addingTimeInterval(Self.retryAfterFailure - Self.interval)
        }
        defaults.set(lastCheck, forKey: Keys.lastCheck)
    }

    func download() {
        NSWorkspace.shared.open(pageURL ?? Self.releasesPage)
    }

    /// Hides the notice for this version only; a later release shows it again.
    func skip() {
        skipped = latest
        defaults.set(latest, forKey: Keys.skipped)
    }

    /// Snapshots: switched on and checked a moment ago; `--update <version>` pretends a newer release exists.
    private func prepareDemo() {
        enabled = true
        lastCheck = Date().addingTimeInterval(-2 * 60 * 60)
        latest = Runtime.value(after: "--update") ?? Self.current
    }

    // MARK: Pure logic (self-test)

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    enum CheckError: Error { case http(Int), format }

    nonisolated static func fetchLatest(completion: @escaping @Sendable (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(repository)/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else { return completion(.failure(CheckError.http(code))) }
            guard let release = parse(data) else { return completion(.failure(CheckError.format)) }
            completion(.success(release))
        }.resume()
    }

    /// Reads `tag_name` ("v1.3.0") and `html_url` of GitHub's release JSON. The page must belong to this app's repository –
    /// "Download" never opens anything else.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let version = normalized(tag) else { return nil }
        let prefix = "https://github.com/\(owner)/\(repository)/releases/"
        let page = (json["html_url"] as? String).flatMap { $0.hasPrefix(prefix) ? URL(string: $0) : nil } ?? releasesPage
        return Release(version: version, page: page)
    }

    /// "v1.3.0" → "1.3.0"; nil unless it starts with a number.
    nonisolated static func normalized(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return version.first?.isNumber == true ? version : nil
    }

    /// Numeric comparison per component: 1.10.0 > 1.9.3, 1.3 == 1.3.0; a suffix like "-beta" is ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated static func isDue(enabled: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now   // clock set back: check again
    }

    nonisolated static func selfTest() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append("update check: \(what)") } }
        expect(isNewer("1.10.0", than: "1.9.3"), "1.10.0 > 1.9.3")
        expect(isNewer("2.0", than: "1.99.99"), "2.0 > 1.99.99")
        expect(!isNewer("1.3", than: "1.3.0") && !isNewer("1.3.0", than: "1.3"), "1.3 == 1.3.0")
        expect(!isNewer("1.2.0", than: "1.3.0"), "older is not newer")
        expect(isNewer("1.3.0-beta", than: "1.2.9"), "suffix ignored")
        expect(normalized("v1.3.0") == "1.3.0" && normalized("1.3.0") == "1.3.0" && normalized("latest") == nil, "tag normalized")
        let now = Date()
        expect(!isDue(enabled: false, lastCheck: nil, now: now), "off is never due")
        expect(isDue(enabled: true, lastCheck: nil, now: now), "first check is due")
        expect(!isDue(enabled: true, lastCheck: now.addingTimeInterval(-3600), now: now), "checked an hour ago")
        expect(isDue(enabled: true, lastCheck: now.addingTimeInterval(-interval - 1), now: now), "a day ago is due")
        let page = "https://github.com/\(owner)/\(repository)/releases/tag/v9.9.9"
        let sample = #"{"tag_name":"v9.9.9","html_url":"\#(page)","draft":false,"prerelease":false}"#
        expect(parse(Data(sample.utf8)) == Release(version: "9.9.9", page: URL(string: page)!), "release JSON parsed")
        let foreign = #"{"tag_name":"v9.9.9","html_url":"https://example.com/x"}"#
        expect(parse(Data(foreign.utf8))?.page == releasesPage, "foreign page replaced by the releases page")
        expect(parse(Data(#"{"tag_name":"v9.9.9","prerelease":true}"#.utf8)) == nil, "pre-release ignored")
        expect(parse(Data("{}".utf8)) == nil, "missing tag rejected")
        return failures
    }

    /// `--check-update <json>`: one real request from the installed app (manual test, never in check.sh). Reads the stored
    /// settings without changing them.
    static func report(writingTo path: String) {
        let enabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
        let loginItem = LoginItem.isEnabled
        fetchLatest { result in
            var report: [String: Any] = ["current": current, "repository": "\(owner)/\(repository)", "enabled": enabled,
                                         "loginItem": loginItem]
            report["skipped"] = skipped ?? NSNull()
            switch result {
            case .success(let release):
                report["latest"] = release.version
                report["page"] = release.page.absoluteString
                report["available"] = isNewer(release.version, than: current) && release.version != skipped
            case .failure(let error):
                report["error"] = String(describing: error)
            }
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

/// Menu notice, only while a newer release exists.
struct UpdateNotice: View {
    private let update = UpdateCheck.shared

    var body: some View {
        if let version = update.available {
            Module {
                HStack(spacing: 8) {
                    SettingLabel(symbol: "arrow.down.circle.fill", title: "Version \(version) available", tint: .blue)
                    Spacer()
                    Button("Skip") { update.skip() }
                        .controlSize(.small)
                    Button("Download") { update.download() }
                        .controlSize(.small)
                        .demoTarget("download")
                }
            }
        }
    }
}

/// Settings row: the switch, what it sends, and the last result.
struct UpdateSettings: View {
    private let update = UpdateCheck.shared

    var body: some View {
        Module {
            HStack {
                SettingLabel(symbol: "arrow.down.circle", title: "Check for Updates", tint: .blue)
                Spacer()
                Toggle("Check for Updates", isOn: Binding(get: { update.enabled }, set: { update.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.setting)
                    .controlSize(.small)
                    .demoTarget("updates")
            }
            if update.enabled {
                HStack(spacing: 6) {
                    SettingNote(statusText, tint: update.status == .failed ? .orange : update.available != nil ? .blue : nil)
                    Spacer()
                    Button(update.status == .checking ? "Checking…" : "Check Now") { update.checkNow() }
                        .controlSize(.small)
                        .disabled(update.status == .checking)
                }
            }
            SettingNote("Once a day, asks GitHub for the latest release number. Nothing else is sent, nothing is installed.")
        }
    }

    private var statusText: String {
        switch update.status {
        case .checking: return "Checking…"
        case .failed: return "Couldn't reach GitHub – trying again later."
        case .idle:
            if let version = update.available { return "Version \(version) available – see the menu." }
            if let latest = update.latest, latest == update.skipped, UpdateCheck.isNewer(latest, than: UpdateCheck.current) {
                return "Version \(latest) skipped."
            }
            guard let last = update.lastCheck else { return "Not checked yet." }
            return "Up to date · checked \(last.formatted(.relative(presentation: .named)))."
        }
    }
}
