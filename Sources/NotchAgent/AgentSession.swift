import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable { case user, assistant, tool, error }
    let id: UUID
    let role: Role
    var text: String
    var icon: String?

    init(role: Role, text: String, icon: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.icon = icon
    }
}

// A persisted conversation, restorable with its provider session ids so it
// can be continued (ChatGPT threads resume via their /c/<id> URL — works
// when signed in; anonymous chats restore as transcript only).
struct ChatArchive: Identifiable, Codable {
    var id = UUID()
    let title: String
    let provider: AgentProvider
    let messages: [ChatMessage]
    let claudeSessionID: String?
    let codexThreadID: String?
    let chatgptThreadID: String?
    let date: Date
}


enum AgentProvider: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case chatgpt

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .chatgpt: return "ChatGPT"
        }
    }

    // ChatGPT-web is chat only; it never touches local files,
    // and its model is whatever the web UI is set to.
    var hasCLIOptions: Bool { self != .chatgpt }

    // value == nil means "the CLI's own default" — no flag is passed.
    // `short` stands alone in the composer pill, so it must identify the
    // model without the provider name next to it.
    var models: [AgentOption] {
        switch self {
        case .claude: return [
            AgentOption(label: "Default", short: "Claude", value: nil),
            AgentOption(label: "Fable 5", short: "Fable 5", value: "claude-fable-5"),
            AgentOption(label: "Opus 4.8", short: "Opus 4.8", value: "claude-opus-4-8"),
            AgentOption(label: "Sonnet 5", short: "Sonnet 5", value: "claude-sonnet-5"),
            AgentOption(label: "Haiku 4.5", short: "Haiku 4.5", value: "claude-haiku-4-5-20251001"),
        ]
        case .codex: return [
            AgentOption(label: "Default", short: "Codex", value: nil),
            AgentOption(label: "GPT-5.6 Terra", short: "5.6 Terra", value: "gpt-5.6-terra"),
            AgentOption(label: "GPT-5.5", short: "GPT-5.5", value: "gpt-5.5"),
            AgentOption(label: "GPT-5.5 Codex", short: "5.5 Codex", value: "gpt-5.5-codex"),
            AgentOption(label: "GPT-5.1 Codex Mini", short: "Codex Mini", value: "gpt-5.1-codex-mini"),
        ]
        case .chatgpt: return []
        }
    }

    // Claude values feed --permission-mode; Codex values feed --sandbox.
    var permissionModes: [AgentOption] {
        switch self {
        case .claude: return [
            AgentOption(label: "Accept Edits", short: "Edits", value: "acceptEdits"),
            AgentOption(label: "Auto", short: "Auto", value: "auto"),
            AgentOption(label: "Bypass Permissions", short: "Bypass", value: "bypassPermissions", dangerous: true),
        ]
        case .codex: return [
            AgentOption(label: "Ask for Approval", short: "Ask", value: nil),
            AgentOption(label: "Approve for Me", short: "Approve", value: "workspace-write"),
            AgentOption(label: "Full Access", short: "Full", value: "danger-full-access", dangerous: true),
        ]
        case .chatgpt: return []
        }
    }
}

// One entry in a model or permission-mode menu. `label` is the menu item,
// `short` is what fits in the composer pill. `dangerous` modes get a warning
// tint on the composer.
struct AgentOption: Identifiable, Equatable {
    let label: String
    let short: String
    let value: String?
    var dangerous: Bool = false
    var id: String { value ?? "default" }
}

// A tool call waiting on the user. The composer morphs into the approval UI
// while one of these is pending; `respond` must be called exactly once.
enum PermissionDecision { case allow, always, deny }

struct PermissionRequest: Identifiable {
    let id = UUID()
    let title: String        // "Claude wants to run a command"
    let detail: String       // the command / file / tool input
    let canAlways: Bool
    let respond: (PermissionDecision) -> Void
}

// Claude's AskUserQuestion tool: one or more questions, each answered by
// picking option(s) or typing a custom answer. Answers are keyed by the full
// question text (the CLI matches them by text, not index).
struct AgentQuestionOption: Identifiable {
    let label: String
    let description: String
    var id: String { label }
}

struct AgentQuestion {
    let header: String
    let question: String
    let options: [AgentQuestionOption]
    let multiSelect: Bool
}

struct QuestionRequest {
    let questions: [AgentQuestion]
    var index = 0
    var answers: [String: String] = [:]
    let respond: ([String: String]) -> Void

    var current: AgentQuestion { questions[index] }
}

// Drives a coding-agent CLI in headless mode. Both providers speak JSONL over
// stdout and thread the conversation with a session/thread id:
//   claude -p <prompt> --output-format stream-json --verbose [--resume <id>]
//   codex exec [resume <id>] --json --skip-git-repo-check <prompt>
// Main-thread only: all mutations are dispatched to main.
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false {
        didSet {
            if !isRunning {
                if let started = turnStartedAt { lastTurnDuration = Date().timeIntervalSince(started) }
                turnStartedAt = nil
            }
        }
    }
    @Published var draft = ""
    // Background-mode telemetry: when the current turn began, and a running
    // character count of streamed output (a cheap, provider-agnostic token
    // estimate ~= chars/4). Both reset at the start of each turn. lastTurnDuration
    // is frozen when the turn ends so the completed pill can show the final time.
    @Published var turnStartedAt: Date?
    @Published var turnChars = 0
    @Published var lastTurnDuration: TimeInterval = 0
    @Published var provider: AgentProvider = .claude
    // Missing key = provider default (no flag). Keyed per provider so
    // switching between Claude and Codex remembers each one's choices.
    @Published var modelChoice: [AgentProvider: String] = [
        .claude: "claude-sonnet-5",
        .codex: "gpt-5.6-terra",
    ]
    @Published var modeChoice: [AgentProvider: String] = [
        .claude: "auto",
    ]
    @Published var pendingPermission: PermissionRequest?
    @Published var pendingQuestion: QuestionRequest?
    // Question-sheet UI state. Lives here rather than in @State because the
    // CLT toolchain can't expand SwiftUI's State macro (see build.sh).
    @Published var questionSelection: Set<String> = []
    @Published var questionDraft = ""
    @Published var attachments: [URL] = []
    @Published var pastChats: [ChatArchive] = []

    private static let chatsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chats.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.chatsURL),
           let chats = try? JSONDecoder().decode([ChatArchive].self, from: data) {
            pastChats = chats
        }
    }

    private func persistChats() {
        if let data = try? JSONEncoder().encode(pastChats) {
            try? data.write(to: Self.chatsURL, options: .atomic)
        }
    }
    @Published var workingDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/code")

    private var claudeSessionID: String?
    private var codexThreadID: String?
    private var chatgptThreadID: String?
    private var process: Process?
    private var claudeStdin: FileHandle?
    private let codexServer = CodexAppServer()
    private var codexActiveTurnID: String?
    private lazy var claudePath: String? = Self.findExecutable("claude")
    private lazy var codexPath: String? = Self.findExecutable("codex")

    private static func findExecutable(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    func send(_ text: String) {
        guard !isRunning else { return }
        turnStartedAt = Date()
        turnChars = 0
        let files = attachments
        attachments = []

        var display = text
        if !files.isEmpty {
            display += "\nAttached: " + files.map(\.lastPathComponent).joined(separator: ", ")
        }
        messages.append(ChatMessage(role: .user, text: display))

        if provider == .chatgpt {
            sendViaChatGPTWeb(text, files: files)
            return
        }

        // CLI agents have filesystem tools: hand them the paths.
        var text = text
        if !files.isEmpty {
            text += "\n\nAttached files (read them if relevant):\n" + files.map(\.path).joined(separator: "\n")
        }

        switch provider {
        case .claude: sendViaClaude(text)
        case .codex: sendViaCodex(text)
        case .chatgpt: break // handled above
        }
    }

    // GUI apps inherit a minimal PATH; both CLIs need node and friends.
    private static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    // MARK: - Claude (stream-json + stdio control protocol)

    // One process per turn. The user message goes in over stdin as stream-json
    // and stdin stays open so `--permission-prompt-tool stdio` can ask us for
    // tool permissions (control_request/can_use_tool -> control_response).
    private func sendViaClaude(_ text: String) {
        guard let claudePath else {
            appendError("claude CLI not found on PATH.")
            return
        }
        isRunning = true

        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose", "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if let claudeSessionID { args += ["--resume", claudeSessionID] }
        if let model = modelChoice[.claude] { args += ["--model", model] }
        if let mode = modeChoice[.claude] {
            args += ["--permission-mode", mode]
            if mode == "bypassPermissions" { args.append("--allow-dangerously-skip-permissions") }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        p.environment = Self.cliEnvironment()

        let stdin = Pipe()
        let out = Pipe()
        let err = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                DispatchQueue.main.async { self?.handleClaudeEvent(obj) }
            }
        }

        // Drain stderr continuously: hooks and plugins are chatty enough to
        // fill the pipe buffer, which would block the CLI before it says
        // anything on stdout. Keep the tail for the failure message.
        var errData = Data()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errData.append(data)
            if errData.count > 65_536 { errData.removeFirst(errData.count - 65_536) }
        }

        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                self.claudeStdin = nil
                self.pendingPermission = nil
                self.pendingQuestion = nil
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.appendError(msg.isEmpty
                        ? "claude exited with status \(proc.terminationStatus)"
                        : msg)
                }
            }
        }

        do {
            try p.run()
            process = p
            claudeStdin = stdin.fileHandleForWriting
            writeClaudeLine([
                "type": "user",
                "message": ["role": "user", "content": [["type": "text", "text": text]]],
            ])
        } catch {
            isRunning = false
            appendError("Failed to launch claude: \(error.localizedDescription)")
        }
    }

    private func writeClaudeLine(_ obj: [String: Any]) {
        guard let claudeStdin,
              var data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        data.append(0x0A)
        try? claudeStdin.write(contentsOf: data)
    }

    private func writeClaudeControlResponse(_ requestID: String, _ inner: [String: Any]) {
        writeClaudeLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": inner],
        ])
    }

    // MARK: - Codex (app-server JSON-RPC)

    private func sendViaCodex(_ text: String) {
        guard let codexPath else {
            appendError("codex CLI not found on PATH.")
            return
        }
        isRunning = true

        if !codexServer.isRunning {
            do {
                try codexServer.start(executable: codexPath, environment: Self.cliEnvironment())
            } catch {
                isRunning = false
                appendError("Failed to launch codex app-server: \(error.localizedDescription)")
                return
            }
        }
        codexServer.onEvent = { [weak self] event in self?.handleCodexServerEvent(event) }

        let mode = Self.codexModeConfig(modeChoice[.codex])
        var threadParams: [String: Any] = [
            "cwd": workingDirectory.path,
            "approvalPolicy": mode.approvalPolicy,
            "sandbox": mode.sandbox,
        ]
        if let model = modelChoice[.codex] { threadParams["model"] = model }

        codexServer.openThread(resuming: codexThreadID, params: threadParams) { [weak self] threadID, error in
            guard let self else { return }
            if let error {
                self.isRunning = false
                self.appendError(error)
                return
            }
            guard let threadID else { return }
            self.codexThreadID = threadID

            var turnParams: [String: Any] = [
                "threadId": threadID,
                "approvalPolicy": mode.approvalPolicy,
                "sandboxPolicy": ["type": mode.sandboxPolicyType],
                "input": [["type": "text", "text": text]],
            ]
            if let model = self.modelChoice[.codex] { turnParams["model"] = model }
            self.codexServer.startTurn(turnParams) { [weak self] turnID, error in
                guard let self else { return }
                if let error {
                    self.isRunning = false
                    self.appendError(error)
                    return
                }
                self.codexActiveTurnID = turnID
            }
        }
    }

    // Mode value (from permissionModes) -> app-server thread/turn config.
    // Mapping mirrors t3code: Ask = untrusted/read-only, Approve for Me =
    // on-request/workspace-write, Full Access = never/danger-full-access.
    private static func codexModeConfig(
        _ value: String?
    ) -> (approvalPolicy: String, sandbox: String, sandboxPolicyType: String) {
        switch value {
        case "workspace-write": return ("on-request", "workspace-write", "workspaceWrite")
        case "danger-full-access": return ("never", "danger-full-access", "dangerFullAccess")
        default: return ("untrusted", "read-only", "readOnly")
        }
    }

    private func handleCodexServerEvent(_ event: CodexAppServer.Event) {
        switch event {
        case .agentDelta(let text):
            appendAssistantDelta(text)
        case .itemCompleted(let item):
            handleCodexItem(item)
        case .turnStarted(let turnID):
            codexActiveTurnID = turnID
        case .turnCompleted(let failureMessage):
            isRunning = false
            codexActiveTurnID = nil
            pendingPermission = nil
            if let failureMessage { appendError(failureMessage) }
        case .serverError(let message):
            appendError(message)
        case .approvalRequest(let kind, let payload, let respond):
            presentCodexApproval(kind: kind, payload: payload, respond: respond)
        }
    }

    private func handleCodexItem(_ item: [String: Any]) {
        switch item["type"] as? String {
        case "agentMessage":
            if let t = item["text"] as? String,
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setStreamingAssistant(t)
            }
        case "commandExecution":
            let cmd = item["command"] as? String ?? "a command"
            appendTool("Running \(String(cmd.prefix(60)))", icon: "terminal")
        case "fileChange":
            let paths = ((item["changes"] as? [[String: Any]]) ?? [])
                .compactMap { $0["path"] as? String }
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
            appendTool("Editing \(paths.isEmpty ? "files" : paths)", icon: "pencil")
        case "webSearch":
            appendTool("Searching \(String((item["query"] as? String ?? "the web").prefix(50)))", icon: "globe")
        case "mcpToolCall":
            appendTool("Using \(item["tool"] as? String ?? "a tool")", icon: "wrench.fill")
        default:
            break // userMessage echo, reasoning, plan, todoList
        }
    }

    private func presentCodexApproval(
        kind: CodexAppServer.ApprovalKind,
        payload: [String: Any],
        respond: @escaping (String) -> Void
    ) {
        let title: String
        let detail: String
        switch kind {
        case .command:
            title = "Codex wants to run a command"
            detail = payload["command"] as? String ?? ""
        case .fileChange:
            title = "Codex wants to edit files"
            detail = payload["reason"] as? String
                ?? payload["grantRoot"] as? String
                ?? "Apply proposed file changes"
        }
        pendingPermission = PermissionRequest(title: title, detail: detail, canAlways: true) { decision in
            switch decision {
            case .allow: respond("accept")
            case .always: respond("acceptForSession")
            case .deny: respond("decline")
            }
        }
    }

    // MARK: - Permission / question responses (UI entry points)

    func respondPermission(_ decision: PermissionDecision) {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        let summary = String(request.detail.prefix(60))
        appendTool(decision == .deny ? "Denied: \(summary)" : "Allowed: \(summary)", icon: "shield")
        request.respond(decision)
    }

    func answerQuestion(_ answer: String) {
        guard var qr = pendingQuestion else { return }
        questionSelection = []
        questionDraft = ""
        qr.answers[qr.current.question] = answer
        messages.append(ChatMessage(role: .user, text: answer))
        if qr.index + 1 < qr.questions.count {
            qr.index += 1
            pendingQuestion = qr
        } else {
            pendingQuestion = nil
            qr.respond(qr.answers)
        }
    }

    func cancel() {
        // A pending approval must be answered before tearing the turn down,
        // otherwise the CLI side is left hanging on the request.
        if let request = pendingPermission {
            pendingPermission = nil
            request.respond(.deny)
        }
        pendingQuestion = nil
        switch provider {
        case .claude:
            process?.terminate()
        case .codex:
            if let codexThreadID, let codexActiveTurnID {
                codexServer.interruptTurn(threadID: codexThreadID, turnID: codexActiveTurnID)
            }
            isRunning = false
        case .chatgpt:
            ChatGPTWeb.shared.cancel()
            isRunning = false
        }
    }

    func reset() {
        cancel()
        archiveCurrentIfNeeded()
        messages.removeAll()
        attachments.removeAll()
        claudeSessionID = nil
        codexThreadID = nil
        chatgptThreadID = nil
    }

    func restore(_ chat: ChatArchive) {
        cancel()
        archiveCurrentIfNeeded()
        pastChats.removeAll { $0.id == chat.id }
        messages = chat.messages
        provider = chat.provider
        claudeSessionID = chat.claudeSessionID
        codexThreadID = chat.codexThreadID
        chatgptThreadID = chat.chatgptThreadID
        persistChats()
    }

    func deleteChat(_ id: UUID) {
        pastChats.removeAll { $0.id == id }
        persistChats()
    }

    func archiveCurrentIfNeeded() {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let title = messages.first(where: { $0.role == .user })
            .map { String($0.text.prefix(60)) } ?? "Untitled"
        pastChats.insert(ChatArchive(
            title: title,
            provider: provider,
            messages: messages,
            claudeSessionID: claudeSessionID,
            codexThreadID: codexThreadID,
            chatgptThreadID: chatgptThreadID,
            date: Date()
        ), at: 0)
        if pastChats.count > 20 { pastChats.removeLast(pastChats.count - 20) }
        persistChats()
    }

    // MARK: - ChatGPT embedded web view (ChatGPTWeb.swift)

    private func sendViaChatGPTWeb(_ text: String, files: [URL]) {
        isRunning = true
        ChatGPTWeb.shared.send(text, thread: chatgptThreadID, files: files) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .status(let t):
                    self.appendTool(t, icon: "globe")
                case .thread(let id):
                    self.chatgptThreadID = id
                case .partial(let t), .message(let t):
                    self.setStreamingAssistant(t)
                case .error(let m):
                    self.appendError(m)
                case .done:
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: - Claude stream-json events

    private func handleClaudeEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if claudeSessionID == nil { claudeSessionID = event["session_id"] as? String }
        case "stream_event":
            // Token-level deltas from --include-partial-messages.
            guard let ev = event["event"] as? [String: Any],
                  ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            appendAssistantDelta(t)
        case "assistant":
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let t = block["text"] as? String,
                      !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return t
            }
            if !texts.isEmpty {
                // The full message replaces whatever the deltas accumulated,
                // so streaming never double-prints.
                setStreamingAssistant(texts.joined(separator: "\n\n"))
            }
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let display = Self.claudeToolDisplay(name: name, input: block["input"] as? [String: Any])
                appendTool(display.text, icon: display.icon)
            }
        case "control_request":
            guard let requestID = event["request_id"] as? String,
                  let request = event["request"] as? [String: Any] else { return }
            handleClaudeControlRequest(requestID, request)
        case "result":
            // Resumed runs get a fresh session id; always track the latest.
            if let id = event["session_id"] as? String { claudeSessionID = id }
            // The turn is over; closing stdin lets the process exit.
            try? claudeStdin?.close()
            claudeStdin = nil
        default:
            break
        }
    }

    // The CLI blocks on these until we write a control_response line.
    private func handleClaudeControlRequest(_ requestID: String, _ request: [String: Any]) {
        guard request["subtype"] as? String == "can_use_tool" else {
            writeClaudeLine([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": requestID,
                             "error": "unsupported control request"],
            ])
            return
        }
        let toolName = request["tool_name"] as? String ?? "a tool"
        let input = request["input"] as? [String: Any] ?? [:]

        if toolName == "AskUserQuestion" {
            presentClaudeQuestions(input, requestID: requestID)
            return
        }

        let display = Self.permissionSummary(
            toolName: toolName,
            displayName: request["display_name"] as? String,
            input: input
        )
        let suggestions = request["permission_suggestions"]
        pendingPermission = PermissionRequest(
            title: display.title,
            detail: display.detail,
            canAlways: suggestions != nil
        ) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .allow:
                self.writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": input])
            case .always:
                var inner: [String: Any] = ["behavior": "allow", "updatedInput": input]
                if let suggestions { inner["updatedPermissions"] = suggestions }
                self.writeClaudeControlResponse(requestID, inner)
            case .deny:
                self.writeClaudeControlResponse(
                    requestID,
                    ["behavior": "deny", "message": "User declined tool execution."]
                )
            }
        }
    }

    private static func permissionSummary(
        toolName: String,
        displayName: String?,
        input: [String: Any]
    ) -> (title: String, detail: String) {
        func str(_ key: String) -> String? { input[key] as? String }
        func fileName(_ path: String?) -> String? {
            path.map { ($0 as NSString).lastPathComponent }
        }
        switch toolName {
        case "Bash":
            return ("Claude wants to run a command", str("command") ?? "")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ("Claude wants to edit \(fileName(str("file_path")) ?? "a file")",
                    str("file_path") ?? "")
        case "Read", "NotebookRead":
            return ("Claude wants to read \(fileName(str("file_path")) ?? "a file")",
                    str("file_path") ?? "")
        case "WebFetch", "WebSearch":
            return ("Claude wants to browse the web", str("url") ?? str("query") ?? "")
        default:
            let compact = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ("Claude wants to use \(displayName ?? toolName)", String(compact.prefix(300)))
        }
    }

    private func presentClaudeQuestions(_ input: [String: Any], requestID: String) {
        let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
            AgentQuestion(
                header: q["header"] as? String ?? "Question",
                question: q["question"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    AgentQuestionOption(
                        label: $0["label"] as? String ?? "",
                        description: $0["description"] as? String ?? ""
                    )
                },
                multiSelect: q["multiSelect"] as? Bool ?? false
            )
        }
        guard !questions.isEmpty else {
            writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": input])
            return
        }
        pendingQuestion = QuestionRequest(questions: questions) { [weak self] answers in
            var updated = input
            updated["answers"] = answers
            self?.writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": updated])
        }
    }

    // Human-readable activity line per tool call: an SF Symbol plus a verb,
    // e.g. "Editing Views.swift", "Running swift build", "Looking at your screen".
    private static func claudeToolDisplay(name: String, input: [String: Any]?) -> (icon: String, text: String) {
        func detail(_ keys: [String]) -> String? {
            keys.compactMap { input?[$0] as? String }.first { !$0.isEmpty }
        }
        func fileName(_ path: String?) -> String? {
            path.map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Read", "NotebookRead":
            return ("doc.text", "Reading \(fileName(detail(["file_path"])) ?? "a file")")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ("pencil", "Editing \(fileName(detail(["file_path"])) ?? "a file")")
        case "Bash":
            return ("terminal", "Running \(String(detail(["command"])?.prefix(60) ?? "a command"))")
        case "Grep", "Glob", "LS":
            return ("magnifyingglass", "Searching \(String(detail(["pattern", "path"])?.prefix(40) ?? "the project"))")
        case "WebSearch", "WebFetch":
            return ("globe", "Browsing \(String(detail(["url", "query"])?.prefix(50) ?? "the web"))")
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return ("checklist", "Updating the plan")
        case "Task", "Agent":
            return ("person.2", "Running a subagent")
        default:
            let lower = name.lowercased()
            if lower.contains("screenshot") || lower.contains("computer") || lower.contains("zoom") {
                return ("camera.viewfinder", "Looking at your screen")
            }
            if lower.contains("click") || lower.contains("type") || lower.contains("key") || lower.contains("scroll") {
                return ("cursorarrow.click.2", "Controlling the screen")
            }
            let d = detail(["command", "file_path", "pattern", "path", "url", "description", "query"])
            return ("wrench.fill", d.map { "\(name) · \(String($0.prefix(50)))" } ?? name)
        }
    }

    // MARK: - Message helpers

    // Streaming: grow the trailing assistant bubble token by token.
    private func appendAssistantDelta(_ text: String) {
        turnChars += text.count
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    // Streaming: replace the trailing assistant bubble with the full text.
    private func setStreamingAssistant(_ text: String) {
        turnChars = max(turnChars, text.count)
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text = text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    private func appendTool(_ text: String, icon: String = "wrench.fill") {
        messages.append(ChatMessage(role: .tool, text: text, icon: icon))
    }

    private func appendError(_ text: String) {
        // Codex emits the same failure as both an `error` and a `turn.failed`.
        if messages.last?.role == .error, messages.last?.text == text { return }
        messages.append(ChatMessage(role: .error, text: text))
    }
}
