import Foundation

// Plan-usage ("how much of my quota is gone") for each provider, which is a
// different thing from the per-chat token counts AgentSession already tracks.
// Each provider reports it its own way:
//
//   Claude — launches the already-authenticated Claude CLI in a short-lived
//            terminal, asks its built-in `/usage` screen, and parses the basic
//            session, weekly, and model-scoped percentages it renders.
//   Codex  — `account/rateLimits/read` on the app-server we already speak, plus
//            an `account/rateLimits/updated` push during turns. Returns one
//            bucket per metered limit id (the shared one, and one per model
//            that meters separately, e.g. Codex Spark).
//   Cursor — no credential-free status surface. Eave deliberately does not
//            read Cursor's Keychain token or browser session just for a meter.
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
    // Set when the provider could not be read. Rendered in Settings instead of bars.
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

    // Turning the setting off drops the cached snapshots from the UI.
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
            guard let executable = Self.findExecutable("claude") else {
                entry.failure = "Claude CLI not found"
                DispatchQueue.main.async { self.finish(.claude, entry) }
                return
            }
            do {
                let parsed = try ClaudeUsageProbe.fetch(
                    executable: executable,
                    environment: Self.cliEnvironment()
                )
                entry.plan = parsed.plan
                entry.windows = parsed.windows
                entry.scoped = parsed.scoped
            } catch let error as ClaudeUsageProbe.ProbeError {
                entry.failure = error.message
            } catch {
                entry.failure = "Claude usage unavailable"
            }
            DispatchQueue.main.async { self.finish(.claude, entry) }
        }
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
        var entry = ProviderUsage()
        entry.failure = "Cursor does not report usage without account access."
        finish(.cursor, entry)
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

// MARK: - Claude CLI usage

// CodexBar demonstrated the privacy-friendly provider strategy this probe uses:
// ask the provider's own authenticated CLI for its rendered status instead of
// reading its OAuth token. This is a deliberately small, Eave-specific process
// runner and parser; see Support/ThirdPartyNotices.txt for attribution.
private enum ClaudeUsageProbe {
    struct Result {
        let plan: String?
        let windows: [UsageWindow]
        let scoped: [String: UsageWindow]
    }

    struct ProbeError: Error {
        let message: String
    }

    static func fetch(executable: String, environment: [String: String]) throws -> Result {
        let directory = AppPaths.supportDirectory.appendingPathComponent(
            "ClaudeUsageProbe", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", executable,
            "--allowed-tools", "",
            "--strict-mcp-config",
            "--session-id", "e5a7c92d-30ca-4d95-9827-b0c199be5ae1",
        ]
        process.currentDirectoryURL = directory
        var cleanEnvironment = environment
        cleanEnvironment.removeValue(forKey: "CLAUDECODE")
        cleanEnvironment.removeValue(forKey: "ANTHROPIC_API_KEY")
        cleanEnvironment["DISABLE_AUTOUPDATER"] = "1"
        process.environment = cleanEnvironment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            throw ProbeError(message: "Claude usage unavailable")
        }

        let writer = input.fileHandleForWriting
        func send(_ text: String, after delay: TimeInterval) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                try? writer.write(contentsOf: Data(text.utf8))
            }
        }
        // Claude's slash-command picker occasionally needs the second Enter;
        // the extra retry is harmless once the usage panel is already open.
        send("/usage\r", after: 2.0)
        send("\r", after: 3.2)
        send("\r", after: 4.2)
        send("\u{1b}", after: 12.0)
        send("/exit\r", after: 12.7)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 14.0) {
            try? writer.close()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 18.0) {
            if process.isRunning { process.terminate() }
        }

        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            throw ProbeError(message: "Claude usage unavailable")
        }
        return try parse(raw)
    }

    static func parse(_ raw: String) throws -> Result {
        let clean = stripTerminalCodes(raw).replacingOccurrences(of: "\r", with: "\n")
        // Cursor-positioning escape codes often sit between words in the TUI
        // ("Current<move>session"). The label patterns below therefore allow
        // zero whitespace rather than relying on a visually spaced string.
        let panel = clean

        guard let session = window(
            labelPattern: #"Current\s*session"#,
            key: "5hr",
            name: "Session",
            minutes: 300,
            in: panel
        ) else {
            let lower = clean.lowercased()
            if lower.contains("login") || lower.contains("sign in") || lower.contains("authentication") {
                throw ProbeError(message: "Sign in to Claude Code")
            }
            throw ProbeError(message: "Claude usage unavailable")
        }

        var windows = [session]
        if let weekly = window(
            labelPattern: #"Current\s*week\s*\(all\s*models\)"#,
            key: "7d",
            name: "Weekly · all models",
            minutes: 10080,
            in: panel
        ) {
            windows.append(weekly)
        }

        var scoped: [String: UsageWindow] = [:]
        let scopedPattern = #"Current\s*week\s*\((?!all\s*models\))([^\)]+)\)"#
        if let regex = try? NSRegularExpression(
            pattern: scopedPattern,
            options: [.caseInsensitive]
        ) {
            let matches = regex.matches(
                in: panel,
                range: NSRange(panel.startIndex..<panel.endIndex, in: panel)
            )
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: panel),
                      let modelRange = Range(match.range(at: 1), in: panel)
                else { continue }
                let model = String(panel[modelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let tail = String(panel[fullRange.lowerBound...].prefix(500))
                if let modelWindow = window(
                    labelPattern: NSRegularExpression.escapedPattern(for: String(panel[fullRange])),
                    key: "7d",
                    name: "Weekly · \(model)",
                    minutes: 10080,
                    in: tail
                ) {
                    scoped[ProviderUsageStore.normalize(model)] = modelWindow
                }
            }
        }

        let plan = firstCapture(
            pattern: #"Claude\s*(Max|Pro|Team|Enterprise|Free)\b"#,
            in: clean
        )
        return Result(plan: plan, windows: windows, scoped: scoped)
    }

    private static func window(
        labelPattern: String,
        key: String,
        name: String,
        minutes: Int,
        in text: String
    ) -> UsageWindow? {
        let pattern = labelPattern + #"[\s\S]{0,500}?([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*(used|left|remaining|available)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let percentRange = Range(match.range(at: 1), in: text),
              let directionRange = Range(match.range(at: 2), in: text),
              let rawPercent = Double(text[percentRange])
        else { return nil }

        let direction = text[directionRange].lowercased()
        let used = direction == "used" ? rawPercent : 100 - rawPercent
        let resetText: String = {
            guard let matchRange = Range(match.range(at: 0), in: text) else { return "" }
            return String(text[matchRange.lowerBound...].prefix(700))
        }()
        let reset = firstCapture(pattern: #"Resets\s*([^\n]+)"#, in: resetText)
        return UsageWindow(
            key: key,
            name: name,
            percent: max(0, min(100, Int(used.rounded()))),
            resetsAt: reset.flatMap { parseReset($0, windowMinutes: minutes) },
            windowMinutes: minutes
        )
    }

    private static func parseReset(_ description: String, windowMinutes: Int) -> Date? {
        var text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var timeZone = TimeZone.current
        if let zoneRange = text.range(of: #"\(([^\)]+)\)"#, options: .regularExpression) {
            let zone = text[zoneRange].dropFirst().dropLast()
            timeZone = TimeZone(identifier: String(zone)) ?? timeZone
            text.removeSubrange(zoneRange)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        for format in ["h:mma", "h:mm a"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text.replacingOccurrences(of: " ", with: "")) {
                let time = calendar.dateComponents(in: timeZone, from: parsed)
                var today = calendar.dateComponents(in: timeZone, from: now)
                today.hour = time.hour
                today.minute = time.minute
                today.second = 0
                if let candidate = calendar.date(from: today) {
                    return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)
                }
            }
        }

        for format in ["MMM d 'at' ha", "MMM d 'at' h:mma"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) {
                let parts = calendar.dateComponents(in: timeZone, from: parsed)
                var candidateParts = DateComponents()
                candidateParts.timeZone = timeZone
                candidateParts.year = calendar.component(.year, from: now)
                candidateParts.month = parts.month
                candidateParts.day = parts.day
                candidateParts.hour = parts.hour
                candidateParts.minute = parts.minute
                if let candidate = calendar.date(from: candidateParts) {
                    let grace = TimeInterval(windowMinutes * 60)
                    return candidate.timeIntervalSince(now) > -grace
                        ? candidate
                        : calendar.date(byAdding: .year, value: 1, to: candidate)
                }
            }
        }
        return nil
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTerminalCodes(_ text: String) -> String {
        var clean = text
        let patterns = [
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}[()][A-Z0-9]",
            "\u{001B}[@-_]",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            clean = regex.stringByReplacingMatches(
                in: clean,
                range: NSRange(clean.startIndex..<clean.endIndex, in: clean),
                withTemplate: ""
            )
        }
        return clean
    }
}
