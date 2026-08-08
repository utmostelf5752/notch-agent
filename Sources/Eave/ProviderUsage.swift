import Foundation
import Security

// Plan-usage ("how much of my quota is gone") for each provider, which is a
// different thing from the per-chat token counts AgentSession already tracks.
// Each provider reports it its own way:
//
//   Claude — GET api.anthropic.com/api/oauth/usage with the OAuth token Claude
//            Code stores in the login keychain. Returns a normalized `limits`
//            array: session, weekly, and a per-model weekly.
//   Codex  — `account/rateLimits/read` on the app-server we already speak, plus
//            an `account/rateLimits/updated` push during turns. Returns one
//            bucket per metered limit id (the shared one, and one per model
//            that meters separately, e.g. Codex Spark).
//   Cursor — DashboardService/GetCurrentPeriodUsage with the token in the
//            keychain. Splits the billing cycle into a Cursor-model bucket and
//            an everything-else bucket; the response names which models fall in
//            the first one.
//   ChatGPT — nothing. The web app exposes no usage figure.

// MARK: - Model

struct UsageWindow: Identifiable, Equatable {
    // Short key rendered in the composer badge: "5hr", "7d", "cursor", "other".
    let key: String
    // Full name for Settings and tooltips: "Session", "Weekly · all models".
    let name: String
    let percent: Int
    let resetsAt: Date?
    // Ordering weight for badge selection; nil sorts last.
    let windowMinutes: Int?

    var id: String { key + name }

    // "resets in 3h 19m" while it is close, "resets Mon 21:59" when it is not.
    var resetLabel: String? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0 else { return "resetting now" }
        if remaining < 12 * 3600 {
            let hours = Int(remaining) / 3600
            let minutes = (Int(remaining) % 3600) / 60
            return hours > 0 ? "resets in \(hours)h \(minutes)m" : "resets in \(minutes)m"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = remaining < 6 * 86400 ? "EEE HH:mm" : "d MMM HH:mm"
        return "resets \(formatter.string(from: resetsAt))"
    }
}

struct ProviderUsage: Equatable {
    var plan: String?
    // Account-wide windows, shortest first.
    var windows: [UsageWindow] = []
    // Windows metered per model, keyed by a normalized model name.
    var scoped: [String: UsageWindow] = [:]
    // Cursor only: model ids billed against the "cursor" bucket rather than
    // "other". The API returns this list, so it stays right as Cursor moves
    // models between buckets.
    var cursorAutoModels: Set<String> = []
    var fetchedAt: Date?
    // Set when the provider could not be read: signed out, no CLI, keychain
    // denied. Rendered in Settings instead of bars.
    var failure: String?

    var isEmpty: Bool { windows.isEmpty && scoped.isEmpty }
}

// MARK: - Store

// Main-thread only, matching AgentSession and CodexAppServer: fetches hop to a
// background queue internally and hop back before touching published state.
final class ProviderUsageStore: ObservableObject {
    static let shared = ProviderUsageStore()

    @Published private(set) var usage: [AgentProvider: ProviderUsage] = [:]
    @Published private(set) var isRefreshing = false

    // Fetches cost a network round trip and, for Codex, a process launch, so
    // repeated panel opens reuse the last read. Turn completion and the
    // Settings refresh button bypass it.
    private let minimumInterval: TimeInterval = 300
    private var inFlight: Set<AgentProvider> = []
    private var codexProbe: CodexAppServer?

    private init() {}

    // MARK: Reading

    // The single window the composer badge shows: the model's own bucket when
    // it meters separately, otherwise the shortest account-wide window. Cursor
    // has no durations to compare, so the selected model picks the bucket.
    func badgeWindow(
        for provider: AgentProvider, modelValue: String?, modelShort: String?
    ) -> UsageWindow? {
        guard let entry = usage[provider], entry.failure == nil else { return nil }

        if provider == .cursor {
            // Both Cursor buckets run to the same cycle end, so duration can't
            // choose between them; the selected model does.
            let isAutoModel = modelValue.map { Self.isCursorAutoModel($0, in: entry.cursorAutoModels) } ?? true
            return entry.windows.first { $0.key == (isAutoModel ? "cursor" : "other") }
                ?? entry.windows.first
        }

        // A model's own bucket competes with the account-wide ones rather than
        // replacing them: Claude's per-model weekly sits alongside a 5-hour
        // session that is usually tighter, while Codex Spark's weekly is the
        // only weekly that applies to Spark. Shortest window wins, and a tie
        // goes to the model's own bucket because it is the more specific one.
        let scoped = scopedWindow(in: entry, modelValue: modelValue, modelShort: modelShort)
        let candidates = entry.windows.map { ($0, false) } + (scoped.map { [($0, true)] } ?? [])
        return candidates.min { lhs, rhs in
            let left = (lhs.0.windowMinutes ?? .max, lhs.1 ? 0 : 1)
            let right = (rhs.0.windowMinutes ?? .max, rhs.1 ? 0 : 1)
            return left < right
        }?.0
    }

    // Every window worth listing for a provider, account-wide first.
    func allWindows(for provider: AgentProvider) -> [UsageWindow] {
        guard let entry = usage[provider] else { return [] }
        return entry.windows + entry.scoped.values.sorted { $0.name < $1.name }
    }

    // The dimmed, unclickable rows at the top of a provider's model submenu.
    func menuWindows(for provider: AgentProvider) -> [UsageWindow] {
        usage[provider]?.windows ?? []
    }

    // The row that hangs under a model that meters on its own.
    func scopedWindow(forModelValue value: String?, short: String?, provider: AgentProvider) -> UsageWindow? {
        guard let entry = usage[provider] else { return nil }
        return scopedWindow(in: entry, modelValue: value, modelShort: short)
    }

    private func scopedWindow(
        in entry: ProviderUsage, modelValue: String?, modelShort: String?
    ) -> UsageWindow? {
        guard !entry.scoped.isEmpty else { return nil }
        // Providers name these buckets after the model, but not identically to
        // the model id ("Fable" for `claude-fable-5`, "GPT-5.3-Codex-Spark" for
        // `gpt-5.3-codex-spark`), so match on a squashed form from either end.
        let candidates = [modelValue, modelShort].compactMap { $0 }.map(Self.normalize)
        for (key, window) in entry.scoped {
            for candidate in candidates where !candidate.isEmpty {
                if candidate == key || candidate.hasPrefix(key) || key.hasPrefix(candidate) {
                    return window
                }
            }
        }
        return nil
    }

    // Cursor bills its own models against the "cursor" bucket and everything
    // else against "other", and names the first set in the usage response. The
    // two id spaces don't line up exactly: our catalog stores families
    // ("cursor-grok-4.5") while Cursor lists effort variants
    // ("cursor-grok-4.5-high"), and our "auto" is their "default".
    static func isCursorAutoModel(_ value: String, in autoModels: Set<String>) -> Bool {
        let value = value == "auto" ? "default" : value
        if autoModels.contains(value) { return true }
        return autoModels.contains {
            $0.hasPrefix(value + "-") || value.hasPrefix($0 + "-")
        }
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Refreshing

    func refreshAll(force: Bool = false) {
        for provider in AgentProvider.allCases where provider != .chatgpt {
            refresh(provider, force: force)
        }
    }

    // Turning the setting off drops what we already read, so nothing sourced
    // from the CLIs' credentials lingers in the UI.
    func clear() {
        usage.removeAll()
    }

    func refresh(_ provider: AgentProvider, force: Bool = false) {
        guard AppState.shared.usageStatsEnabled else { return }
        guard provider != .chatgpt else { return }
        guard !inFlight.contains(provider) else { return }
        if !force, let fetchedAt = usage[provider]?.fetchedAt,
           Date().timeIntervalSince(fetchedAt) < minimumInterval {
            return
        }
        inFlight.insert(provider)
        isRefreshing = true

        switch provider {
        case .claude: fetchClaude()
        case .cursor: fetchCursor()
        case .codex: fetchCodex()
        case .chatgpt: break
        }
    }

    private func finish(_ provider: AgentProvider, _ entry: ProviderUsage) {
        var entry = entry
        entry.fetchedAt = Date()
        usage[provider] = entry
        inFlight.remove(provider)
        isRefreshing = !inFlight.isEmpty
        if let failure = entry.failure {
            Telemetry.record("error", [
                "domain": "usage.\(provider.rawValue)",
                "kind": failure.prefix(40).description,
            ])
        }
    }

    // Codex pushes a sparse snapshot mid-turn. Merging it keeps the badge live
    // while the agent works, without another process launch.
    func applyCodexSnapshot(_ snapshot: [String: Any]) {
        guard AppState.shared.usageStatsEnabled else { return }
        var entry = usage[.codex] ?? ProviderUsage()
        guard let parsed = Self.parseCodexSnapshot(snapshot) else { return }
        entry.failure = nil
        entry.plan = parsed.plan ?? entry.plan
        if !parsed.windows.isEmpty { entry.windows = parsed.windows }
        entry.fetchedAt = Date()
        usage[.codex] = entry
    }

    // MARK: Claude

    private func fetchClaude() {
        DispatchQueue.global(qos: .utility).async {
            var entry = ProviderUsage()
            guard let raw = Keychain.readString(service: "Claude Code-credentials") else {
                entry.failure = "Sign in to Claude Code"
                DispatchQueue.main.async { self.finish(.claude, entry) }
                return
            }
            let credentials = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let oauth = credentials?["claudeAiOauth"] as? [String: Any]
            guard let token = oauth?["accessToken"] as? String else {
                entry.failure = "Sign in to Claude Code"
                DispatchQueue.main.async { self.finish(.claude, entry) }
                return
            }
            entry.plan = (oauth?["subscriptionType"] as? String).map(Self.planLabel)

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.timeoutInterval = 15

            URLSession.shared.dataTask(with: request) { data, response, error in
                var entry = entry
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error != nil {
                    entry.failure = "Usage unavailable"
                } else if status == 401 || status == 403 {
                    entry.failure = "Sign in to Claude Code"
                } else if let data,
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let parsed = Self.parseClaude(json)
                    entry.windows = parsed.windows
                    entry.scoped = parsed.scoped
                    if entry.windows.isEmpty && entry.scoped.isEmpty {
                        entry.failure = "Usage unavailable"
                    }
                } else {
                    entry.failure = "Usage unavailable"
                }
                DispatchQueue.main.async { self.finish(.claude, entry) }
            }.resume()
        }
    }

    // `limits` is the current, already-normalized view; the older top-level
    // five_hour/seven_day fields are the fallback if it ever disappears.
    private static func parseClaude(
        _ json: [String: Any]
    ) -> (windows: [UsageWindow], scoped: [String: UsageWindow]) {
        var windows: [UsageWindow] = []
        var scoped: [String: UsageWindow] = [:]

        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.intValue
                else { continue }
                let resetsAt = (limit["resets_at"] as? String).flatMap(Self.parseISODate)
                let isSession = kind.contains("session")
                let key = isSession ? "5hr" : "7d"
                let minutes = isSession ? 300 : 10080

                let scopeModel = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                if let scopeModel {
                    scoped[normalize(scopeModel)] = UsageWindow(
                        key: key,
                        name: (isSession ? "Session · " : "Weekly · ") + scopeModel,
                        percent: percent,
                        resetsAt: resetsAt,
                        windowMinutes: minutes
                    )
                } else {
                    windows.append(UsageWindow(
                        key: key,
                        name: isSession ? "Session" : "Weekly · all models",
                        percent: percent,
                        resetsAt: resetsAt,
                        windowMinutes: minutes
                    ))
                }
            }
        }

        if windows.isEmpty {
            for (field, name, key, minutes) in [
                ("five_hour", "Session", "5hr", 300),
                ("seven_day", "Weekly · all models", "7d", 10080),
            ] {
                guard let bucket = json[field] as? [String: Any],
                      let utilization = (bucket["utilization"] as? NSNumber)?.doubleValue
                else { continue }
                windows.append(UsageWindow(
                    key: key,
                    name: name,
                    percent: Int(utilization.rounded()),
                    resetsAt: (bucket["resets_at"] as? String).flatMap(Self.parseISODate),
                    windowMinutes: minutes
                ))
            }
        }

        windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        return (windows, scoped)
    }

    // MARK: Codex

    private func fetchCodex() {
        guard codexProbe == nil, let executable = Self.findExecutable("codex") else {
            var entry = usage[.codex] ?? ProviderUsage()
            entry.failure = "codex CLI not found"
            finish(.codex, entry)
            return
        }
        // A short-lived server of our own, so a usage refresh never disturbs an
        // in-flight conversation on the session's long-lived one.
        let probe = CodexAppServer()
        codexProbe = probe
        do {
            try probe.start(executable: executable, environment: Self.cliEnvironment()) { [weak self] error in
                guard let self else { return }
                guard error == nil else {
                    probe.stop()
                    self.codexProbe = nil
                    var entry = ProviderUsage()
                    entry.failure = "codex app-server unavailable"
                    self.finish(.codex, entry)
                    return
                }
                probe.readRateLimits { [weak self] result, error in
                    guard let self else { return }
                    probe.stop()
                    self.codexProbe = nil
                    var entry = ProviderUsage()
                    if let result, let parsed = Self.parseCodexResponse(result) {
                        entry.plan = parsed.plan
                        entry.windows = parsed.windows
                        entry.scoped = parsed.scoped
                    } else {
                        entry.failure = error ?? "Usage unavailable"
                    }
                    self.finish(.codex, entry)
                }
            }
        } catch {
            codexProbe = nil
            var entry = ProviderUsage()
            entry.failure = "codex app-server unavailable"
            finish(.codex, entry)
        }
    }

    // `rateLimits` is the shared bucket; `rateLimitsByLimitId` adds one entry
    // per separately metered model, named by `limitName`.
    private static func parseCodexResponse(
        _ result: [String: Any]
    ) -> (plan: String?, windows: [UsageWindow], scoped: [String: UsageWindow])? {
        guard let shared = result["rateLimits"] as? [String: Any],
              let base = parseCodexSnapshot(shared)
        else { return nil }

        var scoped: [String: UsageWindow] = [:]
        if let byID = result["rateLimitsByLimitId"] as? [String: [String: Any]] {
            let sharedID = shared["limitId"] as? String
            for (limitID, snapshot) in byID where limitID != sharedID {
                guard let name = snapshot["limitName"] as? String,
                      let parsed = parseCodexSnapshot(snapshot),
                      let window = parsed.windows.first
                else { continue }
                scoped[normalize(name)] = UsageWindow(
                    key: window.key,
                    name: "\(window.name) · \(name)",
                    percent: window.percent,
                    resetsAt: window.resetsAt,
                    windowMinutes: window.windowMinutes
                )
            }
        }
        return (base.plan, base.windows, scoped)
    }

    private static func parseCodexSnapshot(
        _ snapshot: [String: Any]
    ) -> (plan: String?, windows: [UsageWindow])? {
        var windows: [UsageWindow] = []
        for field in ["primary", "secondary"] {
            guard let bucket = snapshot[field] as? [String: Any],
                  let percent = (bucket["usedPercent"] as? NSNumber)?.intValue
            else { continue }
            let minutes = (bucket["windowDurationMins"] as? NSNumber)?.intValue
            let resetsAt = (bucket["resetsAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(UsageWindow(
                key: windowKey(minutes: minutes),
                name: windowName(minutes: minutes),
                percent: percent,
                resetsAt: resetsAt,
                windowMinutes: minutes
            ))
        }
        guard !windows.isEmpty else { return nil }
        windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
        return ((snapshot["planType"] as? String).map(planLabel), windows)
    }

    // MARK: Cursor

    private func fetchCursor() {
        DispatchQueue.global(qos: .utility).async {
            var entry = ProviderUsage(plan: nil)
            guard let token = Keychain.readString(service: "cursor-access-token") else {
                entry.failure = "Sign in to Cursor"
                DispatchQueue.main.async { self.finish(.cursor, entry) }
                return
            }
            var request = URLRequest(
                url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
            )
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 15

            URLSession.shared.dataTask(with: request) { data, response, error in
                var entry = entry
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error != nil {
                    entry.failure = "Usage unavailable"
                } else if status == 401 || status == 403 {
                    entry.failure = "Sign in to Cursor"
                } else if let data,
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let parsed = Self.parseCursor(json) {
                    entry.windows = parsed.windows
                    entry.cursorAutoModels = parsed.autoModels
                } else {
                    entry.failure = "Usage unavailable"
                }
                DispatchQueue.main.async { self.finish(.cursor, entry) }
            }.resume()
        }
    }

    private static func parseCursor(
        _ json: [String: Any]
    ) -> (windows: [UsageWindow], autoModels: Set<String>)? {
        guard let plan = json["planUsage"] as? [String: Any] else { return nil }
        // Both buckets run to the end of the billing cycle, so neither is
        // "shorter" — the selected model decides which one the badge shows.
        let resetsAt = (json["billingCycleEnd"] as? String)
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0 / 1000) }
        func window(_ field: String, key: String, name: String) -> UsageWindow? {
            guard let percent = (plan[field] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(
                key: key,
                name: name,
                percent: Int(percent.rounded()),
                resetsAt: resetsAt,
                windowMinutes: nil
            )
        }
        let windows = [
            window("autoPercentUsed", key: "cursor", name: "Cursor models"),
            window("apiPercentUsed", key: "other", name: "Other models"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        let autoModels = Set((json["autoBucketModels"] as? [String]) ?? [])
        return (windows, autoModels)
    }

    // MARK: Shared helpers

    private static func windowKey(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "used" }
        if minutes < 1440 { return "\(max(1, minutes / 60))hr" }
        return "\(max(1, minutes / 1440))d"
    }

    private static func windowName(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage" }
        if minutes < 1440 { return "Session" }
        if minutes == 10080 { return "Weekly" }
        return "\(max(1, minutes / 1440))-day"
    }

    private static func planLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.capitalized
        }
    }

    private static func parseISODate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func findExecutable(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    private static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }
}

// MARK: - Keychain

// Both tokens live in generic-password items owned by another app, so the
// first read shows the system's "Eave wants to use …" prompt. Denying it is a
// normal outcome, not an error worth surfacing twice — the caller renders it
// as a sign-in hint. Blocking call: never run this on the main thread.
enum Keychain {
    static func readString(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
