import Foundation

// Headless `cursor-agent -p` has no approval channel: anything needing
// permission is rejected by the CLI itself before we ever see it, which is why
// Propose Only silently auto-denied. Cursor's hooks are the only way in, and
// only in one direction — a hook can veto, it cannot grant an approval the CLI
// lacks. So Propose Only launches Cursor with --force (the CLI approves
// everything) and this gate becomes the real gate: a preToolUse hook that
// blocks until the user answers in the notch.
//
// Cursor reads hooks from a fixed set of paths (~/.cursor/hooks.json, or the
// project's own .cursor/hooks.json) — it ignores CURSOR_CONFIG_DIR, and local
// plugin dirs are gated behind a server flag. The user file is the only
// non-invasive option, so the install merges into it rather than owning it.
enum CursorApprovals {
    // MARK: - Paths

    static let directory: URL = {
        let directory = AppPaths.supportDirectory
            .appendingPathComponent("CursorApprovals", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static var requestsDirectory: URL { directory.appendingPathComponent("requests", isDirectory: true) }
    private static var responsesDirectory: URL { directory.appendingPathComponent("responses", isDirectory: true) }
    private static var stagingDirectory: URL { directory.appendingPathComponent("staging", isDirectory: true) }
    private static var activeMarker: URL { directory.appendingPathComponent("active") }
    static var scriptURL: URL { directory.appendingPathComponent("cursor-approval-hook.sh") }

    static var hooksConfigURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    private static var backupURL: URL {
        hooksConfigURL.deletingLastPathComponent().appendingPathComponent("hooks.json.eave-backup")
    }

    // Cursor runs the hook command through a shell, so the guard clause keeps a
    // leftover registration harmless after Eave is deleted: no script, no-op.
    private static var hookCommand: String {
        "if [ -x '\(scriptURL.path)' ]; then /bin/sh '\(scriptURL.path)'; fi"
    }

    // One event covers every tool. beforeShellExecution alone would miss file
    // edits — Cursor has no before-edit hook, only afterFileEdit, which is too
    // late to veto.
    private static let hookEvent = "preToolUse"

    // MARK: - Install / uninstall

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let entries = readHookEntries()
        else { return false }
        return entries.contains { ($0["command"] as? String)?.contains(scriptURL.path) == true }
    }

    static func install() throws {
        try writeScript()
        var config = readConfig() ?? [:]
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        var entries = hooks[hookEvent] as? [[String: Any]] ?? []
        entries.removeAll { ($0["command"] as? String)?.contains(scriptURL.path) == true }
        // Cursor kills the hook at this timeout; the script gives up earlier so
        // the user gets our deny message rather than a bare timeout.
        entries.append(["command": hookCommand, "timeout": 3600])
        hooks[hookEvent] = entries
        config["hooks"] = hooks
        if config["version"] == nil { config["version"] = 1 }
        try writeConfig(config, backupFirst: true)
    }

    static func uninstall() throws {
        guard var config = readConfig() else { return }
        guard var hooks = config["hooks"] as? [String: Any],
              var entries = hooks[hookEvent] as? [[String: Any]]
        else { return }
        entries.removeAll { ($0["command"] as? String)?.contains(scriptURL.path) == true }
        if entries.isEmpty {
            hooks.removeValue(forKey: hookEvent)
        } else {
            hooks[hookEvent] = entries
        }
        config["hooks"] = hooks
        try writeConfig(config, backupFirst: false)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static func readConfig() -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksConfigURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func readHookEntries() -> [[String: Any]]? {
        (readConfig()?["hooks"] as? [String: Any])?[hookEvent] as? [[String: Any]]
    }

    private static func writeConfig(_ config: [String: Any], backupFirst: Bool) throws {
        let directory = hooksConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The user's file usually already has entries from other tools. Keep a
        // one-time copy of what it looked like before Eave touched it.
        if backupFirst,
           FileManager.default.fileExists(atPath: hooksConfigURL.path),
           !FileManager.default.fileExists(atPath: backupURL.path) {
            try? FileManager.default.copyItem(at: hooksConfigURL, to: backupURL)
        }
        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: hooksConfigURL, options: .atomic)
    }

    private static func writeScript() throws {
        for url in [requestsDirectory, responsesDirectory, stagingDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )
    }

    // Plain sh so it runs the same whether Cursor invokes it from a login shell
    // or not. Silence means "carry on" to Cursor, which is what makes the
    // no-active-session path safe for the user's own Cursor runs.
    private static var script: String {
        """
        #!/bin/sh
        # Installed by Eave to route Cursor tool approvals to its permission
        # prompt. Harmless when Eave is not running: it exits silently, which
        # Cursor treats as "allow".
        DIR="\(directory.path)"
        INPUT=$(cat)

        # Eave marks a session active only while it is driving a Cursor turn
        # that needs approvals. Every other Cursor session passes straight
        # through.
        [ -f "$DIR/active" ] || exit 0

        REQ=$(mktemp "$DIR/staging/XXXXXXXXXX" 2>/dev/null) || exit 0
        printf '%s' "$INPUT" > "$REQ" 2>/dev/null || exit 0
        ID=$(basename "$REQ")
        mv "$REQ" "$DIR/requests/$ID" 2>/dev/null || exit 0

        # Fail closed. If Eave crashed or quit mid-turn, the CLI is running
        # with --force and nothing else would stop this call.
        i=0
        while [ $i -lt 3000 ]; do
            if [ -f "$DIR/responses/$ID" ]; then
                cat "$DIR/responses/$ID"
                rm -f "$DIR/responses/$ID"
                exit 0
            fi
            if [ ! -f "$DIR/active" ]; then break; fi
            sleep 0.2
            i=$((i + 1))
        done
        rm -f "$DIR/requests/$ID"
        echo '{"permission":"deny","agentMessage":"Eave did not approve this call."}'
        """
    }

    // MARK: - Session gate

    struct Request {
        let id: String
        let toolName: String
        let input: [String: Any]

        // Reads and searches are the half of Propose Only that should never
        // interrupt: they cannot change anything.
        var isReadOnly: Bool {
            ["read", "glob", "grep", "ls", "list", "search", "codebase_search", "notebookread"]
                .contains(toolName.lowercased())
        }

        var summary: String {
            let keys = ["command", "file_path", "path", "pattern", "query", "url"]
            let detail = keys.compactMap { input[$0] as? String }.first { !$0.isEmpty }
            guard let detail else { return toolName }
            return "\(toolName) · \(detail)"
        }

        var detailText: String {
            if let command = input["command"] as? String, !command.isEmpty { return command }
            if let data = try? JSONSerialization.data(
                withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return toolName
        }
    }

    private static var pollTimer: Timer?
    private static var handler: ((Request) -> Void)?

    static var isSessionActive: Bool { pollTimer != nil }

    // Called when a Cursor turn starts in Propose Only. The handler runs on the
    // main queue for each tool call that needs a decision.
    static func beginSession(handler: @escaping (Request) -> Void) {
        endSession()
        for url in [requestsDirectory, responsesDirectory, stagingDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        clearPending()
        self.handler = handler
        try? Data().write(to: activeMarker)
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in drainRequests() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    static func endSession() {
        pollTimer?.invalidate()
        pollTimer = nil
        handler = nil
        try? FileManager.default.removeItem(at: activeMarker)
        clearPending()
    }

    static func respond(_ id: String, allow: Bool, message: String? = nil) {
        var payload: [String: Any] = ["permission": allow ? "allow" : "deny"]
        if let message, !allow { payload["agentMessage"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: responsesDirectory.appendingPathComponent(id), options: .atomic)
    }

    private static func clearPending() {
        for url in [requestsDirectory, responsesDirectory, stagingDirectory] {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            )) ?? []
            for file in contents { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func drainRequests() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: requestsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            try? FileManager.default.removeItem(at: file)
            // The hook writes one JSON object; a truncated read means the file
            // was mid-rename, and the hook will time out rather than hang.
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                respond(file.lastPathComponent, allow: false, message: "Unreadable approval request.")
                continue
            }
            let request = Request(
                id: file.lastPathComponent,
                toolName: object["tool_name"] as? String ?? "a tool",
                input: object["tool_input"] as? [String: Any] ?? [:]
            )
            if request.isReadOnly {
                respond(request.id, allow: true)
                continue
            }
            handler?(request)
        }
    }
}
