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

    // ChatGPT-web is chat only; it never touches local files.
    var supportsAutoEdit: Bool { self != .chatgpt }
}

// Drives a coding-agent CLI in headless mode. Both providers speak JSONL over
// stdout and thread the conversation with a session/thread id:
//   claude -p <prompt> --output-format stream-json --verbose [--resume <id>]
//   codex exec [resume <id>] --json --skip-git-repo-check <prompt>
// Main-thread only: all mutations are dispatched to main.
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false
    @Published var autoEdit = false
    @Published var draft = ""
    @Published var provider: AgentProvider = .claude
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

        let executable: String?
        let args: [String]
        switch provider {
        case .claude:
            executable = claudePath
            var a = ["-p", text, "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            if let claudeSessionID { a += ["--resume", claudeSessionID] }
            if autoEdit { a += ["--permission-mode", "acceptEdits"] }
            args = a
        case .codex:
            executable = codexPath
            var a = ["exec"]
            if let codexThreadID { a += ["resume", codexThreadID] }
            a += ["--json", "--skip-git-repo-check"]
            if autoEdit { a += ["-s", "workspace-write"] }
            a.append(text)
            args = a
        case .chatgpt:
            return // handled above
        }

        guard let executable else {
            messages.append(ChatMessage(role: .error, text: "\(provider.rawValue) CLI not found on PATH."))
            return
        }
        isRunning = true

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        // GUI apps inherit a minimal PATH; both CLIs need node and friends.
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let activeProvider = provider
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
                DispatchQueue.main.async {
                    switch activeProvider {
                    case .claude: self?.handleClaudeEvent(obj)
                    case .codex: self?.handleCodexEvent(obj)
                    case .chatgpt: break // not process-based
                    }
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.appendError(msg.isEmpty
                        ? "\(activeProvider.rawValue) exited with status \(proc.terminationStatus)"
                        : msg)
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            isRunning = false
            appendError("Failed to launch \(provider.rawValue): \(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
        if provider == .chatgpt {
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
        case "result":
            // Resumed runs get a fresh session id; always track the latest.
            if let id = event["session_id"] as? String { claudeSessionID = id }
        default:
            break
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

    // MARK: - Codex exec --json events

    private func handleCodexEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "thread.started":
            if let id = event["thread_id"] as? String { codexThreadID = id }
        case "item.completed":
            guard let item = event["item"] as? [String: Any] else { return }
            switch item["type"] as? String {
            case "agent_message":
                if let t = item["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    appendAssistant(t)
                }
            case "command_execution":
                let cmd = item["command"] as? String ?? "a command"
                appendTool("Running \(String(cmd.prefix(60)))", icon: "terminal")
            case "file_change":
                let paths = ((item["changes"] as? [[String: Any]]) ?? [])
                    .compactMap { $0["path"] as? String }
                    .map { ($0 as NSString).lastPathComponent }
                    .joined(separator: ", ")
                appendTool("Editing \(paths.isEmpty ? "files" : paths)", icon: "pencil")
            case "web_search":
                appendTool("Searching \(String((item["query"] as? String ?? "the web").prefix(50)))", icon: "globe")
            case "mcp_tool_call":
                appendTool("Using \(item["tool"] as? String ?? "a tool")", icon: "wrench.fill")
            case "error":
                if let m = item["message"] as? String { appendError(m) }
            default:
                break // reasoning, todo_list, item.started/updated noise
            }
        case "turn.failed":
            if let error = event["error"] as? [String: Any],
               let m = error["message"] as? String {
                appendError(m)
            }
        case "error":
            if let m = event["message"] as? String { appendError(m) }
        default:
            break
        }
    }

    // MARK: - Message helpers

    private func appendAssistant(_ text: String) {
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += "\n\n" + text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    // Streaming: grow the trailing assistant bubble token by token.
    private func appendAssistantDelta(_ text: String) {
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    // Streaming: replace the trailing assistant bubble with the full text.
    private func setStreamingAssistant(_ text: String) {
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
