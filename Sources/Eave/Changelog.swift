import Foundation

// Release notes shown in Settings > About, keyed by marketing version
// (CFBundleShortVersionString, i.e. "0.1.<commit count>"). Like the ChatGPT
// selectors, installed apps fetch remote/changelog.json from
// raw.githubusercontent.com on launch, every 6 hours, and on demand when the
// user checks for updates.
//
// Why remote rather than bundled: the notes must describe the version being
// offered by the updater, which the currently-installed (older) app has never
// seen — a changelog baked into the running build could only ever list
// versions already installed. Fetching lets "what's new in the update" appear
// before the user installs it. The compiled-in `builtin` set is the offline
// fallback, and a fetched feed is used only if sanitize() passes.
struct Changelog: Codable, Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var version: String
        var date: String?
        var notes: [String]

        var id: String { version }
    }

    var entries: [Entry]

    // Must stay in sync with remote/changelog.json — the remote file starts as
    // an exact copy of this. Newest release first.
    static let builtin = Changelog(entries: [
        Entry(
            version: "0.1.38",
            date: "2026-07-21",
            notes: [
                "Settings now opens reliably instead of occasionally shifting focus without appearing.",
                "New \"What's New\" section in Settings > About shows release notes when you check for updates.",
                "Checking for updates from the menu bar opens the About tab instead of a separate popup.",
                "Selected controls in Settings use your macOS accent color.",
                "Shortcut rows show a pencil to signal they can be rebound.",
                "Haptic feedback now double-taps the trackpad when a response finishes.",
                "Tidied Settings: removed the theme descriptions, the Keep panel pinned option, and the About tagline and link.",
            ]
        ),
    ])

    // MARK: - Active feed

    // ObservableObject wrapper so the About tab re-renders when a fetch lands.
    // Read and reassigned on the main thread only.
    final class Store: ObservableObject {
        static let shared = Store()
        @Published fileprivate(set) var changelog: Changelog = loadCached() ?? builtin
    }

    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/utmostelf5752/notch-agent/main/remote/changelog.json"
    )!

    private static let cacheURL: URL = {
        let dir = AppPaths.supportDirectory.appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("changelog.json")
    }()

    static func startRefreshing() {
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 6 * 3600, repeating: 6 * 3600, leeway: .seconds(300))
        timer.setEventHandler { refresh() }
        timer.resume()
        refreshTimer = timer
    }

    private static var refreshTimer: DispatchSourceTimer?

    // Also called on demand (opening About, checking for updates) so the newest
    // notes appear without waiting for the 6-hour tick. Fetch failures are silent.
    static func refresh() {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, _ in
            session.finishTasksAndInvalidate()
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let fetched = try? JSONDecoder().decode(Changelog.self, from: data),
                  let sanitized = sanitize(fetched) else { return }
            if let encoded = try? JSONEncoder().encode(sanitized) {
                try? encoded.write(to: cacheURL)
            }
            DispatchQueue.main.async {
                if sanitized != Store.shared.changelog {
                    Store.shared.changelog = sanitized
                }
            }
        }.resume()
    }

    private static func loadCached() -> Changelog? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(Changelog.self, from: data),
              let sanitized = sanitize(cached) else { return nil }
        return sanitized
    }

    // Bounds volume and strips control characters so a malformed or hostile
    // feed can't flood or corrupt the About tab. Notes render as plain SwiftUI
    // Text, so there's no escaping concern beyond size — non-ASCII prose is
    // allowed through; only ASCII control bytes and newlines are dropped.
    private static func sanitize(_ changelog: Changelog) -> Changelog? {
        func clean(_ s: String, max: Int) -> String {
            let stripped = s.filter { char in
                guard let ascii = char.asciiValue else { return true }
                return ascii >= 0x20 && ascii != 0x7F
            }
            return String(stripped.prefix(max))
        }
        let entries: [Entry] = changelog.entries.prefix(50).compactMap { entry in
            let version = clean(entry.version, max: 20).trimmingCharacters(in: .whitespaces)
            guard !version.isEmpty else { return nil }
            let notes = entry.notes.prefix(30)
                .map { clean($0, max: 300).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !notes.isEmpty else { return nil }
            let date = entry.date.map { clean($0, max: 20) }.flatMap { $0.isEmpty ? nil : $0 }
            return Entry(version: version, date: date, notes: notes)
        }
        guard !entries.isEmpty else { return nil }
        return Changelog(entries: entries)
    }
}
