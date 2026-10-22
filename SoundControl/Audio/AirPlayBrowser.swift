import Foundation
import Network
import Observation
import SystemConfiguration

/// AirPlay rooms on the local network (Bonjour `_airplay._tcp`) – used only for the name: Core Audio reports a connected
/// AirPlay target merely as "AirPlay", whereas Apple's sound settings show the room name.
/// Rooms = AirPlay groups (TXT `gid`/`gpn`); Apple likewise merges Apple TV + HomePod into one entry.
/// Rooms that are not connected do not appear in the list (connecting is done through Apple; a custom AirPlay sender
/// like SoundSource's was rejected). The first search triggers the macOS "Local Network" prompt → only once the
/// output list is expanded; afterwards (remembered) from launch. Denied or failed → the name stays "AirPlay".
@MainActor
@Observable
final class AirPlayBrowser {
    struct Speaker: Identifiable, Hashable {
        let id: String
        let name: String
        let symbol: String
    }

    private(set) var speakers: [Speaker] = []
    @ObservationIgnored private var browser: NWBrowser?
    private static let enabledKey = "airPlayDiscovery"

    init() {
        if Runtime.isDemo {
            speakers = [Speaker(id: "Living Room", name: "Living Room", symbol: "homepodmini.fill")]
        } else if Runtime.isSnapshot, let names = Runtime.value(after: "--airplay") {
            // Snapshot: sample rooms instead of a network search (no system prompt, nothing stored).
            speakers = names.split(separator: ",").map { Speaker(id: String($0), name: String($0), symbol: "homepodmini.fill") }
        } else if !Runtime.headless && UserDefaults.standard.bool(forKey: Self.enabledKey) {
            start()
        }
    }

    /// Starts the search (once; called when the output list is expanded).
    func start() {
        guard browser == nil, !Runtime.headless else { return }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                let list = Self.speakers(from: results)
                if self?.speakers != list { self?.speakers = list }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            // Network change/error: search again after a short pause instead of showing stale rooms.
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                self?.browser?.cancel()
                self?.browser = nil
                self?.speakers = []
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { self?.start() } }
            }
        }
        browser = b
        b.start(queue: .main)
    }

    /// One entry per AirPlay group; this Mac itself (own AirPlay receiver) does not count.
    private static func speakers(from results: Set<NWBrowser.Result>) -> [Speaker] {
        let own = SCDynamicStoreCopyComputerName(nil, nil) as String?
        var groups: [String: (name: String, models: [String])] = [:]
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint, name != own,
                  !r.interfaces.contains(where: { $0.type == .loopback }) else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = r.metadata { txt = record.dictionary }
            let key = txt["gid"] ?? name
            var g = groups[key] ?? (txt["gpn"] ?? name, [])
            g.models.append(txt["model"] ?? "")
            groups[key] = g
        }
        return groups.map { Speaker(id: $0.key, name: $0.value.name, symbol: symbol(for: $0.value.models)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// If a HomePod plays in the group, it stands for the room (it outputs the sound).
    private static func symbol(for models: [String]) -> String {
        if models.contains(where: { $0.hasPrefix("AudioAccessory5") }) { return "homepodmini.fill" }
        if models.contains(where: { $0.hasPrefix("AudioAccessory") }) { return "homepod.fill" }
        if models.contains(where: { $0.hasPrefix("AppleTV") }) { return "appletv.fill" }
        return "hifispeaker.fill"
    }
}
