import Foundation

// Remotely-updatable DOM selectors for the ChatGPT web provider. chatgpt.com
// renames its data-testid / role attributes periodically, and a rename breaks
// every installed copy at once. The selector set below can be replaced by
// committing remote/chatgpt-selectors.json to main — running apps fetch it
// from raw.githubusercontent.com on launch and every 6 hours, so a selector
// fix reaches users without a release or an app update.
//
// Safety: a fetched config is used only if validate() passes (ASCII-only, no
// quote/backslash/control characters, so nothing can escape the generated JS
// string literals) and the compiled-in `builtin` set below always remains the
// fallback. Fetch failures are silent.
struct ChatGPTSelectors: Codable, Equatable {
    struct Strategy: Codable, Equatable {
        var name: String
        var selector: String
        // Skip nodes inside a [hidden] ancestor. Mirrors the historical
        // "-visible" strategy variants.
        var excludeHidden: Bool?
    }

    var version: Int
    var composer: String
    var send: [String]
    var stop: [String]
    var assistant: [Strategy]
    var user: [Strategy]

    // Must stay in sync with remote/chatgpt-selectors.json — the remote file
    // starts as an exact copy of this.
    static let builtin = ChatGPTSelectors(
        version: 1,
        composer: "#prompt-textarea, #mobile-composer-prompt, [data-testid='prompt-textarea'], div[role='textbox'], main [contenteditable='true'], [contenteditable='true'], main textarea, form textarea",
        send: [
            "button[data-testid='send-button']",
            "button[data-testid='composer-submit-button']",
            "#composer-submit-button",
            "button[aria-label*='Send']",
            "button[aria-label*='Send message']",
            "form button[type='submit']",
        ],
        stop: [
            "button[aria-label*='Stop']",
            "button[data-testid='stop-button']",
            "button[aria-label*='Stop generating']",
            "button[aria-label*='Stop streaming']",
        ],
        assistant: [
            Strategy(name: "data-message-author-role", selector: "[data-message-author-role='assistant']"),
            Strategy(name: "data-message-role-visible", selector: "[data-message-role='assistant']", excludeHidden: true),
            Strategy(name: "data-message-role", selector: "[data-message-role='assistant']"),
            Strategy(name: "data-testid-assistant", selector: "[data-testid='assistant-message'], [data-testid='conversation-turn-assistant']"),
            Strategy(name: "data-turn", selector: "[data-turn='assistant'], article[data-turn='assistant']"),
            Strategy(name: "aria-assistant", selector: "[aria-label*='ChatGPT said'], [data-message-id][data-author='assistant']"),
        ],
        user: [
            Strategy(name: "data-message-author-role", selector: "[data-message-author-role='user']"),
            Strategy(name: "data-message-role-visible", selector: "[data-message-role='user']", excludeHidden: true),
            Strategy(name: "data-message-role", selector: "[data-message-role='user']"),
            Strategy(name: "data-testid-user", selector: "[data-testid='user-message'], [data-testid='conversation-turn-user']"),
            Strategy(name: "data-turn", selector: "[data-turn='user'], article[data-turn='user']"),
            Strategy(name: "aria-user", selector: "[aria-label*='You said'], [data-message-id][data-author='user']"),
        ]
    )

    // MARK: - Active config

    // Read from the main thread when scrape/inject scripts are built; only
    // ever reassigned on the main thread by refresh().
    private(set) static var current: ChatGPTSelectors = loadCached() ?? builtin

    private static let remoteURL = URL(
        string: "https://raw.githubusercontent.com/utmostelf5752/notch-agent/main/remote/chatgpt-selectors.json"
    )!

    private static let cacheURL: URL = {
        let dir = AppPaths.supportDirectory.appendingPathComponent("RemoteConfig", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chatgpt-selectors.json")
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

    private static func refresh() {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, _ in
            session.finishTasksAndInvalidate()
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let fetched = try? JSONDecoder().decode(ChatGPTSelectors.self, from: data),
                  validate(fetched) else { return }
            try? data.write(to: cacheURL)
            DispatchQueue.main.async {
                if fetched != current {
                    current = fetched
                    NSLog("Eave: ChatGPT selectors updated to remote version \(fetched.version)")
                }
            }
        }.resume()
    }

    private static func loadCached() -> ChatGPTSelectors? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(ChatGPTSelectors.self, from: data),
              validate(cached) else { return nil }
        return cached
    }

    // Rejects anything that could escape the generated JS string literals or
    // is obviously malformed. Selectors are plain ASCII CSS using only single
    // quotes; double quotes, backslashes, and control characters have no
    // legitimate use here.
    private static func validate(_ config: ChatGPTSelectors) -> Bool {
        func ok(_ s: String, maxLength: Int = 500) -> Bool {
            !s.isEmpty && s.count <= maxLength && s.allSatisfy { char in
                char.isASCII && !char.isNewline && char != "\"" && char != "\\"
                    && (char.asciiValue ?? 0) >= 0x20
            }
        }
        func ok(_ strategies: [Strategy]) -> Bool {
            !strategies.isEmpty && strategies.count <= 20 && strategies.allSatisfy {
                ok($0.name, maxLength: 50) && ok($0.selector)
            }
        }
        return ok(config.composer, maxLength: 1000)
            && !config.send.isEmpty && config.send.count <= 20 && config.send.allSatisfy { ok($0) }
            && !config.stop.isEmpty && config.stop.count <= 20 && config.stop.allSatisfy { ok($0) }
            && ok(config.assistant) && ok(config.user)
    }

    // MARK: - JS generation

    // The selector-dependent portion of ChatGPTWeb's shared DOM helpers.
    // Values are spliced as JSON literals (with validate() as the backstop),
    // so config text can never break out of the script.
    static func runtimeJS(_ config: ChatGPTSelectors) -> String {
        func json<T: Encodable>(_ value: T) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return text
        }
        return """
        const __composerSelector = \(json(config.composer));
        const __composer = () => {
          const cands = document.querySelectorAll(__composerSelector);
          for (const el of cands) { if (__visible(el)) return el; }
          return null;
        };
        const __strategyFns = (list) => list.map(s => ({ name: s.name, fn: () => {
          let nodes = Array.from(document.querySelectorAll(s.selector));
          if (s.excludeHidden) nodes = nodes.filter(n => !n.closest("[hidden]"));
          return nodes;
        }}));
        const __assistantQuery = () => __nodesByStrategies(__strategyFns(\(json(config.assistant))));
        const __userQuery = () => __nodesByStrategies(__strategyFns(\(json(config.user))));
        const __sendButtonSels = \(json(config.send));
        const __sendButton = () => {
          for (const s of __sendButtonSels) {
            const el = document.querySelector(s);
            if (el && __visible(el)) return el;
          }
          for (const s of __sendButtonSels) {
            const el = document.querySelector(s);
            if (el) return el;
          }
          return null;
        };
        const __stopButtonSels = \(json(config.stop));
        const __stopButton = () => {
          for (const s of __stopButtonSels) {
            const el = document.querySelector(s);
            if (el) return el;
          }
          return null;
        };
        """
    }
}
