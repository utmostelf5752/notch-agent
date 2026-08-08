import Foundation

// JSON-RPC 2.0 client for `codex app-server` (newline-delimited over stdio).
// One long-lived process serves all conversations; AgentSession opens a
// thread per conversation and starts a turn per user message. Approval
// requests arrive as server->client requests and are answered with
// {"decision": "accept" | "acceptForSession" | "decline" | "cancel"}.
// Protocol shapes cross-referenced from t3code's codex adapter and verified
// against codex 0.144 live. Main-thread only.
final class CodexAppServer {
    typealias JSON = [String: Any]

    enum Event {
        case agentDelta(String)
        case itemCompleted(JSON)                 // the "item" payload
        case approvalRequest(kind: ApprovalKind, payload: JSON, respond: (String) -> Void)
        case turnStarted(String)                 // turn id
        case turnCompleted(turnID: String?, failureMessage: String?)
        // cumulativeTotal is thread-cumulative; lastTurnTotal is the latest
        // turn's request size (the current context fill); contextWindow is
        // the model's capacity when the server reports one.
        case tokenUsage(cumulativeTotal: Int, lastTurnTotal: Int?, contextWindow: Int?)
        // Sparse rolling plan-usage update; merge, don't replace.
        case rateLimits(JSON)
        case serverError(String)
    }

    enum ApprovalKind {
        case command
        case fileChange
    }

    var onEvent: ((Event) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextID = 0
    // Completion receives (result, errorMessage) — exactly one is non-nil.
    private var pendingRequests: [Int: (JSON?, String?) -> Void] = [:]
    private var initialized = false
    private var readyCallbacks: [(String?) -> Void] = []
    // Threads opened by this process instance; anything else needs thread/resume.
    private var knownThreads: Set<String> = []

    var isRunning: Bool { process?.isRunning == true }

    // MARK: - Process lifecycle

    func start(
        executable: String,
        environment: [String: String],
        onReady: ((String?) -> Void)? = nil
    ) throws {
        if isRunning {
            if initialized {
                onReady?(nil)
            } else if let onReady {
                readyCallbacks.append(onReady)
            }
            return
        }
        pendingRequests.removeAll()
        knownThreads.removeAll()
        readyCallbacks.removeAll()
        initialized = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["app-server"]
        p.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe() // codex logs to stderr; keep it out of the protocol

        var buffer = Data()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? JSON
                else { continue }
                DispatchQueue.main.async { self?.handleMessage(obj) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            stdout.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.stdinHandle = nil
                self.initialized = false
                let waiting = self.pendingRequests.values
                self.pendingRequests.removeAll()
                waiting.forEach { $0(nil, "codex app-server exited") }
                self.finishReady("codex app-server exited")
            }
        }

        try p.run()
        process = p
        stdinHandle = stdin.fileHandleForWriting
        if let onReady { readyCallbacks.append(onReady) }

        request("initialize", [
            "clientInfo": ["name": "eave", "title": "Eave", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true],
        ]) { [weak self] _, error in
            guard let self else { return }
            guard error == nil else {
                self.finishReady(error)
                return
            }
            self.initialized = true
            self.notify("initialized", nil)
            self.finishReady(nil)
        }
    }

    func stop() {
        guard process?.isRunning == true else { return }
        process?.terminate()
    }

    deinit {
        if process?.isRunning == true { process?.terminate() }
    }

    private func finishReady(_ error: String?) {
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        callbacks.forEach { $0(error) }
    }

    // Fetch every visible model page. Catalog callers use a short-lived
    // server; conversation callers keep their existing long-lived process.
    func listModels(completion: @escaping ([JSON]?, String?) -> Void) {
        collectModels(cursor: nil, accumulated: [], completion: completion)
    }

    private func collectModels(
        cursor: String?,
        accumulated: [JSON],
        completion: @escaping ([JSON]?, String?) -> Void
    ) {
        var params: JSON = ["includeHidden": false, "limit": 100]
        if let cursor { params["cursor"] = cursor }
        request("model/list", params) { [weak self] result, error in
            if let error {
                completion(nil, error)
                return
            }
            let page = (result?["data"] as? [JSON]) ?? []
            let models = accumulated + page
            if let nextCursor = result?["nextCursor"] as? String, !nextCursor.isEmpty {
                self?.collectModels(
                    cursor: nextCursor,
                    accumulated: models,
                    completion: completion
                )
            } else {
                completion(models, nil)
            }
        }
    }

    // Account-wide plan usage: the shared bucket plus one per separately
    // metered model. Cheap enough to run on a throwaway server.
    func readRateLimits(completion: @escaping (JSON?, String?) -> Void) {
        request("account/rateLimits/read", [:], completion: completion)
    }

    // MARK: - Thread / turn API

    // Opens (or resumes) a thread, then calls completion with the codex
    // thread id. threadStartParams: cwd/approvalPolicy/sandbox/model.
    func openThread(
        resuming existingThreadID: String?,
        params threadStartParams: JSON,
        completion: @escaping (String?, String?) -> Void
    ) {
        if let existingThreadID, knownThreads.contains(existingThreadID) {
            completion(existingThreadID, nil)
            return
        }
        let finish: (JSON?, String?) -> Void = { [weak self] result, error in
            if let error { completion(nil, error); return }
            guard let id = (result?["thread"] as? JSON)?["id"] as? String else {
                completion(nil, "codex thread/start returned no thread id")
                return
            }
            self?.knownThreads.insert(id)
            completion(id, nil)
        }
        if let existingThreadID {
            var params = threadStartParams
            params["threadId"] = existingThreadID
            request("thread/resume", params) { [weak self] result, error in
                if error != nil {
                    // Stale/unknown thread (e.g. codex home changed): fresh start.
                    self?.request("thread/start", threadStartParams, completion: finish)
                } else {
                    finish(result, nil)
                }
            }
        } else {
            request("thread/start", threadStartParams, completion: finish)
        }
    }

    func startTurn(_ params: JSON, completion: @escaping (String?, String?) -> Void) {
        request("turn/start", params) { result, error in
            if let error { completion(nil, error); return }
            completion((result?["turn"] as? JSON)?["id"] as? String, nil)
        }
    }

    func interruptTurn(threadID: String, turnID: String) {
        request("turn/interrupt", ["threadId": threadID, "turnId": turnID]) { _, _ in }
    }

    // MARK: - JSON-RPC plumbing

    private func request(_ method: String, _ params: JSON?, completion: @escaping (JSON?, String?) -> Void) {
        nextID += 1
        pendingRequests[nextID] = completion
        var msg: JSON = ["jsonrpc": "2.0", "id": nextID, "method": method]
        if let params { msg["params"] = params }
        write(msg)
    }

    private func notify(_ method: String, _ params: JSON?) {
        var msg: JSON = ["jsonrpc": "2.0", "method": method]
        if let params { msg["params"] = params }
        write(msg)
    }

    private func respond(id: Any, result: JSON) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ obj: JSON) {
        guard let stdinHandle,
              var data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        data.append(0x0A)
        stdinHandle.write(data)
    }

    // MARK: - Incoming messages

    private func handleMessage(_ obj: JSON) {
        let method = obj["method"] as? String
        let id = obj["id"]

        // Response to one of our requests.
        if method == nil, let id = id as? Int {
            guard let completion = pendingRequests.removeValue(forKey: id) else { return }
            if let error = obj["error"] as? JSON {
                completion(nil, (error["message"] as? String) ?? "codex request failed")
            } else {
                completion(obj["result"] as? JSON ?? [:], nil)
            }
            return
        }

        guard let method else { return }
        let params = obj["params"] as? JSON ?? [:]

        // Server -> client request (needs a response).
        if let id {
            switch method {
            case "item/commandExecution/requestApproval":
                emitApproval(kind: .command, payload: params, id: id)
            case "item/fileChange/requestApproval":
                emitApproval(kind: .fileChange, payload: params, id: id)
            default:
                // Unsupported capability (login flows, elicitations, …).
                write(["jsonrpc": "2.0", "id": id,
                       "error": ["code": -32601, "message": "unsupported by Eave"]])
            }
            return
        }

        // Notifications.
        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { onEvent?(.agentDelta(delta)) }
        case "item/completed":
            if let item = params["item"] as? JSON { onEvent?(.itemCompleted(item)) }
        case "turn/started":
            if let turnID = ((params["turn"] as? JSON)?["id"]) as? String {
                onEvent?(.turnStarted(turnID))
            }
        case "turn/completed":
            let turn = params["turn"] as? JSON
            let failure = (turn?["error"] as? JSON)?["message"] as? String
            onEvent?(.turnCompleted(turnID: turn?["id"] as? String, failureMessage: failure))
        case "thread/tokenUsage/updated":
            // `total` is cumulative for the whole thread and survives resume
            // (the app-server replays prior turns' usage), so we set rather
            // than add. `last` is this turn only — which, because every turn
            // resends the whole conversation, is also the context fill.
            let usage = params["tokenUsage"] as? JSON
            if let total = (usage?["total"] as? JSON)?["totalTokens"] as? Int {
                let last = (usage?["last"] as? JSON)?["totalTokens"] as? Int
                let window = (usage?["modelContextWindow"] as? Int)
                    ?? (params["modelContextWindow"] as? Int)
                onEvent?(.tokenUsage(cumulativeTotal: total, lastTurnTotal: last, contextWindow: window))
            }
        case "account/rateLimits/updated":
            if let limits = params["rateLimits"] as? JSON { onEvent?(.rateLimits(limits)) }
        case "error":
            if let message = (params["error"] as? JSON)?["message"] as? String {
                onEvent?(.serverError(message))
            }
        default:
            break // deltas we don't render (reasoning, plan, output), status noise
        }
    }

    private func emitApproval(kind: ApprovalKind, payload: JSON, id: Any) {
        onEvent?(.approvalRequest(kind: kind, payload: payload) { [weak self] decision in
            self?.respond(id: id, result: ["decision": decision])
        })
    }
}
