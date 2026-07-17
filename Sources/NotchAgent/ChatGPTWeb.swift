import AppKit
import UniformTypeIdentifiers
import WebKit

// Embedded chatgpt.com provider: the app owns a persistent WKWebView.
// First use shows a real chatgpt.com sign-in window (cookies persist in the
// app's own WebKit store, so it's one-time); afterwards prompts are injected
// into the hidden web view and the reply is scraped from the DOM.
// Selector set ported from codex-chatgpt-control's dom helpers.
final class ChatGPTWeb: NSObject {
    enum Event {
        case status(String)
        case thread(String)
        case partial(String)
        case message(String)
        case error(String)
        case done
    }

    static let shared = ChatGPTWeb()

    private var webView: WKWebView!
    private var hostWindow: NSWindow!
    private var loginWindow: NSWindow?
    private var cancelled = false
    private var generation = 0

    // Multi-strategy selectors: chatgpt.com renames data-testid / role attrs
    // periodically. Prefer current attrs, then historical / structural fallbacks.
    private static let sendSelector = "button[data-testid='send-button'], button[data-testid='composer-submit-button'], #composer-submit-button, button[aria-label*='Send'], button[aria-label*='Send message'], form button[type='submit']"
    private static let stopSelector = "button[aria-label*='Stop'], button[data-testid='stop-button'], button[aria-label*='Stop generating'], button[aria-label*='Stop streaming']"

    // Shared DOM helpers injected into scrape/inject scripts. Single source of
    // truth for composer + message node resolution so fallbacks stay consistent.
    private static let domHelpersJS = """
    const __visible = (el) => !!(el && el.getClientRects && el.getClientRects().length > 0);
    const __composer = () => {
      const cands = document.querySelectorAll(
        "#prompt-textarea, [data-testid='prompt-textarea'], div[role='textbox'], " +
        "main [contenteditable='true'], [contenteditable='true'], main textarea, form textarea"
      );
      for (const el of cands) { if (__visible(el)) return el; }
      return null;
    };
    const __nodesByStrategies = (strategies) => {
      for (const s of strategies) {
        const nodes = s.fn();
        if (nodes && nodes.length) return { nodes: Array.from(nodes), strategy: s.name };
      }
      return { nodes: [], strategy: "none" };
    };
    const __assistantQuery = () => __nodesByStrategies([
      { name: "data-message-author-role", fn: () => document.querySelectorAll("[data-message-author-role='assistant']") },
      { name: "data-testid-assistant", fn: () => document.querySelectorAll("[data-testid='assistant-message'], [data-testid='conversation-turn-assistant']") },
      { name: "data-turn", fn: () => document.querySelectorAll("[data-turn='assistant'], article[data-turn='assistant']") },
      { name: "aria-assistant", fn: () => document.querySelectorAll("[aria-label*='ChatGPT said'], [data-message-id][data-author='assistant']") }
    ]);
    const __userQuery = () => __nodesByStrategies([
      { name: "data-message-author-role", fn: () => document.querySelectorAll("[data-message-author-role='user']") },
      { name: "data-testid-user", fn: () => document.querySelectorAll("[data-testid='user-message'], [data-testid='conversation-turn-user']") },
      { name: "data-turn", fn: () => document.querySelectorAll("[data-turn='user'], article[data-turn='user']") },
      { name: "aria-user", fn: () => document.querySelectorAll("[aria-label*='You said'], [data-message-id][data-author='user']") }
    ]);
    const __sendButton = () => {
      const sels = [
        "button[data-testid='send-button']",
        "button[data-testid='composer-submit-button']",
        "#composer-submit-button",
        "button[aria-label*='Send']",
        "button[aria-label*='Send message']",
        "form button[type='submit']"
      ];
      for (const s of sels) {
        const el = document.querySelector(s);
        if (el && __visible(el)) return el;
      }
      for (const s of sels) {
        const el = document.querySelector(s);
        if (el) return el;
      }
      return null;
    };
    const __stopButton = () => {
      const sels = [
        "button[aria-label*='Stop']",
        "button[data-testid='stop-button']",
        "button[aria-label*='Stop generating']",
        "button[aria-label*='Stop streaming']"
      ];
      for (const s of sels) {
        const el = document.querySelector(s);
        if (el) return el;
      }
      return null;
    };
    const __probeUI = () => {
      const a = __assistantQuery();
      const u = __userQuery();
      const composer = __composer();
      const send = __sendButton();
      const roleAttrs = document.querySelectorAll("[data-message-author-role]").length;
      const turnAttrs = document.querySelectorAll("[data-turn]").length;
      const hasMain = !!document.querySelector("main");
      // Loaded chat shell with neither role nor turn landmarks → site DOM drift.
      const likelyChanged = hasMain && !composer && roleAttrs === 0 && turnAttrs === 0
        && !document.querySelector("input[type='password'], button[data-testid*='login'], a[href*='login']");
      return {
        composer: !!composer,
        send: !!send,
        assistantStrategy: a.strategy,
        userStrategy: u.strategy,
        assistantCount: a.nodes.length,
        userCount: u.nodes.length,
        roleAttrs,
        turnAttrs,
        likelyChanged
      };
    };
    """

    private override init() {
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        // Safari UA: chatgpt.com and its SSO providers reject the default
        // WKWebView agent string.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

        // A windowless WKWebView is treated as invisible and chatgpt.com then
        // never commits streamed reply text to the DOM (empty <p> nodes). Keep
        // the web view mounted in a 2x2, near-transparent, click-through
        // window so the page always renders.
        let host = NSWindow(
            contentRect: NSRect(x: 4, y: 4, width: 2, height: 2),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isOpaque = false
        host.backgroundColor = .clear
        host.alphaValue = 0.02
        host.ignoresMouseEvents = true
        host.level = .normal
        host.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        host.contentView?.addSubview(webView)
        host.orderFrontRegardless()
        hostWindow = host
    }

    // MARK: - Public

    func send(_ prompt: String, thread: String?, files: [URL] = [], onEvent: @escaping (Event) -> Void) {
        cancelled = false
        generation += 1
        let gen = generation

        let target = thread.map { "https://chatgpt.com/c/\($0)" } ?? "https://chatgpt.com/"
        let current = webView.url?.absoluteString ?? ""
        let onTarget: Bool
        if let thread {
            onTarget = current.contains(thread)
        } else {
            onTarget = current.hasPrefix("https://chatgpt.com") && !current.contains("/c/")
        }
        if !onTarget, let url = URL(string: target) {
            webView.load(URLRequest(url: url))
        }
        onEvent(.status("Opening chatgpt.com"))

        waitForComposer(gen: gen, deadline: Date().addingTimeInterval(300), loginShown: false, onEvent: onEvent) { [weak self] in
            guard let self, !self.cancelled, gen == self.generation else { return }
            self.hideLoginWindow()
            self.uploadFiles(files, gen: gen, onEvent: onEvent) {
                self.baselineAndSend(prompt: prompt, gen: gen, onEvent: onEvent)
            }
        }
    }

    // Attach files by loading their bytes into a synthetic File and pushing it
    // through chatgpt.com's hidden <input type="file">.
    private func uploadFiles(_ files: [URL], gen: Int, onEvent: @escaping (Event) -> Void, then: @escaping () -> Void) {
        guard !cancelled, gen == generation else { return }
        guard let file = files.first else {
            then()
            return
        }
        let rest = Array(files.dropFirst())
        guard let data = try? Data(contentsOf: file), data.count <= 10_000_000 else {
            onEvent(.error("Skipped \(file.lastPathComponent) (unreadable or over 10 MB)."))
            uploadFiles(rest, gen: gen, onEvent: onEvent, then: then)
            return
        }
        onEvent(.status("Attaching \(file.lastPathComponent)"))
        let name = Self.jsonString(file.lastPathComponent) ?? "\"file\""
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let js = """
        (() => {
          const input = document.querySelector("input[type='file']");
          if (!input) return "no-input";
          const bytes = Uint8Array.from(atob("\(data.base64EncodedString())"), c => c.charCodeAt(0));
          const file = new File([bytes], \(name), { type: "\(mime)" });
          const dt = new DataTransfer();
          dt.items.add(file);
          input.files = dt.files;
          input.dispatchEvent(new Event("change", { bubbles: true }));
          return "ok";
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            if (result as? String) != "ok" {
                onEvent(.error("chatgpt.com exposed no file input — \(file.lastPathComponent) skipped."))
            }
            // Give the upload a moment to register before the next one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.uploadFiles(rest, gen: gen, onEvent: onEvent, then: then)
            }
        }
    }

    func cancel() {
        cancelled = true
        generation += 1
        run("""
        (() => { \(Self.domHelpersJS) const b = __stopButton(); if (b) b.click(); })()
        """) { _ in }
    }

    // MARK: - Steps

    private func waitForComposer(gen: Int, deadline: Date, loginShown: Bool, onEvent: @escaping (Event) -> Void, then: @escaping () -> Void) {
        guard !cancelled, gen == generation else { return }
        guard Date() < deadline else {
            // Final probe so timeouts distinguish sign-in stalls from DOM drift.
            self.run("""
            (() => { \(Self.domHelpersJS) return JSON.stringify(__probeUI()); })()
            """) { probeResult in
                let probe = Self.decode(probeResult) ?? [:]
                if (probe["likelyChanged"] as? Bool) == true {
                    onEvent(.error("ChatGPT UI changed — timed out and no composer/message landmarks matched known selectors."))
                } else if loginShown {
                    onEvent(.error("Timed out waiting for sign-in."))
                } else {
                    onEvent(.error("Timed out waiting for chatgpt.com to load."))
                }
                onEvent(.done)
            }
            return
        }
        run("""
        (() => {
          \(Self.domHelpersJS)
          const ready = !!__composer();
          return JSON.stringify({ ready, probe: __probeUI() });
        })()
        """) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let obj = Self.decode(result) ?? [:]
            if (obj["ready"] as? Bool) == true {
                then()
                return
            }
            // Do not fail-fast on probe.likelyChanged here — the shell can
            // mount <main> before the composer hydrates. Probe is decisive
            // only on timeout / post-action failures.
            var shown = loginShown
            // Page loaded but no composer: assume sign-in (or interstitial)
            // is needed and show the window so the user can deal with it.
            if !shown, self.webView.estimatedProgress > 0.9 {
                self.presentLoginWindow()
                onEvent(.status("Waiting for sign-in — check the ChatGPT window"))
                shown = true
            }
            let shownFinal = shown
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.waitForComposer(gen: gen, deadline: deadline, loginShown: shownFinal, onEvent: onEvent, then: then)
            }
        }
    }

    private func baselineAndSend(prompt: String, gen: Int, onEvent: @escaping (Event) -> Void) {
        guard let promptJSON = Self.jsonString(prompt) else {
            onEvent(.error("Could not encode prompt."))
            onEvent(.done)
            return
        }
        // Step 1: insert the prompt (execCommand first; direct DOM fallback)
        // and record message baselines.
        let insertJS = """
        (() => {
          \(Self.domHelpersJS)
          const el = __composer();
          if (!el) return JSON.stringify({s: "no-composer", probe: __probeUI()});
          const P = \(promptJSON);
          el.focus();
          document.execCommand("selectAll", false, null);
          const ok = document.execCommand("insertText", false, P);
          const text = (el.innerText ?? el.value ?? "").trim();
          if (!ok || text.length === 0) {
            if ("value" in el) {
              el.value = P;
            } else {
              el.textContent = P;
            }
            el.dispatchEvent(new InputEvent("input", { bubbles: true, data: P }));
          }
          const a = __assistantQuery();
          const u = __userQuery();
          return JSON.stringify({
            s: "inserted",
            aBase: a.nodes.length,
            uBase: u.nodes.length,
            aStrategy: a.strategy,
            uStrategy: u.strategy
          });
        })()
        """
        run(insertJS) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            guard let obj = Self.decode(result), obj["s"] as? String == "inserted" else {
                let probe = (Self.decode(result)?["probe"] as? [String: Any]) ?? [:]
                if (probe["likelyChanged"] as? Bool) == true {
                    onEvent(.error("ChatGPT UI changed — could not find the message box (composer landmarks missing)."))
                } else {
                    onEvent(.error("Could not find the message box. chatgpt.com's UI may have changed."))
                }
                onEvent(.done)
                return
            }
            let aBase = obj["aBase"] as? Int ?? 0
            let uBase = obj["uBase"] as? Int ?? 0
            // Give the composer a beat to enable its send button.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.submit(gen: gen, aBase: aBase, uBase: uBase, onEvent: onEvent)
            }
        }
    }

    // Step 2: click send if a button is found, otherwise synthesize Enter.
    // A disabled button usually means an attachment is still uploading —
    // retry for up to ~30s before falling back.
    private func submit(gen: Int, aBase: Int, uBase: Int, attempt: Int = 0, onEvent: @escaping (Event) -> Void) {
        let js = """
        (() => {
          \(Self.domHelpersJS)
          const btn = __sendButton();
          if (btn && !btn.disabled) { btn.click(); return "clicked"; }
          if (btn && btn.disabled) return "disabled";
          const el = __composer();
          if (!el) return "no-composer";
          for (const type of ["keydown", "keypress", "keyup"]) {
            el.dispatchEvent(new KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true }));
          }
          return "enter";
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            if (result as? String) == "disabled" && attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                    self.submit(gen: gen, aBase: aBase, uBase: uBase, attempt: attempt + 1, onEvent: onEvent)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.verifySubmitted(gen: gen, aBase: aBase, uBase: uBase, onEvent: onEvent)
            }
        }
    }

    // Step 3: confirm the message actually left the composer; if not, report
    // what buttons exist so the failure is self-diagnosing.
    private func verifySubmitted(gen: Int, aBase: Int, uBase: Int, onEvent: @escaping (Event) -> Void) {
        let js = """
        (() => {
          \(Self.domHelpersJS)
          const u = __userQuery();
          return JSON.stringify({
            u: u.nodes.length,
            uStrategy: u.strategy,
            streaming: !!__stopButton(),
            probe: __probeUI()
          });
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let obj = Self.decode(result) ?? [:]
            // Strict: only a new user message node or active streaming counts
            // as sent — an empty composer can be a hidden fallback element.
            let sent = (obj["u"] as? Int ?? 0) > uBase
                || (obj["streaming"] as? Bool ?? false)
            if sent {
                self.pollReply(gen: gen, baseline: aBase, lastText: "", stableCount: 0,
                               deadline: Date().addingTimeInterval(240), onEvent: onEvent)
                return
            }
            let probe = obj["probe"] as? [String: Any] ?? [:]
            let diagJS = """
            (() => {
              \(Self.domHelpersJS)
              return JSON.stringify({
                buttons: Array.from(document.querySelectorAll("main button, form button"))
                  .slice(0, 14)
                  .map(b => (b.getAttribute("data-testid") || b.getAttribute("aria-label") || "?") + (b.disabled ? "(off)" : "")),
                probe: __probeUI()
              });
            })()
            """
            self.run(diagJS) { diag in
                let info = Self.decode(diag) ?? [:]
                let buttons = info["buttons"] ?? "[]"
                let p = info["probe"] as? [String: Any] ?? probe
                if (p["likelyChanged"] as? Bool) == true || (p["send"] as? Bool) == false {
                    onEvent(.error("ChatGPT UI changed — couldn't press send. Buttons seen: \(buttons); assistant=\(p["assistantStrategy"] ?? "?"); user=\(p["userStrategy"] ?? "?")"))
                } else {
                    onEvent(.error("Couldn't press send — chatgpt.com's UI may have changed. Buttons seen: \(buttons)"))
                }
                onEvent(.done)
            }
        }
    }

    private static func decode(_ result: Any?) -> [String: Any]? {
        guard let raw = result as? String, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // Debug: dump page state for offline inspection (triggered via SIGUSR2).
    func dumpState(to path: String) {
        let js = """
        (() => {
          \(Self.domHelpersJS)
          const a = __assistantQuery();
          const last = a.nodes.length ? a.nodes[a.nodes.length - 1] : null;
          return JSON.stringify({
            href: location.href,
            title: document.title,
            probe: __probeUI(),
            assistantCount: a.nodes.length,
            assistantStrategy: a.strategy,
            userCount: __userQuery().nodes.length,
            streaming: !!__stopButton(),
            lastAssistant: last ? last.innerText.slice(0, 200) : null,
            lastAssistantTC: last ? last.textContent.slice(0, 200) : null,
            lastAssistantHTML: last ? last.innerHTML.slice(0, 400) : null,
            roleAttrs: Array.from(document.querySelectorAll("[data-message-author-role]")).slice(0, 6).map(n => n.getAttribute("data-message-author-role")),
            composer: (() => { const el = __composer(); return el ? el.outerHTML.slice(0, 400) : null; })(),
            buttons: Array.from(document.querySelectorAll("main button, form button")).slice(0, 20)
              .map(b => ({ testid: b.getAttribute("data-testid"), aria: b.getAttribute("aria-label"), disabled: b.disabled }))
          }, null, 1);
        })()
        """
        run(js) { result in
            let out = (result as? String) ?? "no result (web view not loaded?)"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func pollReply(gen: Int, baseline: Int, lastText: String, stableCount: Int, deadline: Date, onEvent: @escaping (Event) -> Void) {
        guard !cancelled, gen == generation else { return }
        guard Date() < deadline else {
            onEvent(.error("Timed out waiting for the reply."))
            onEvent(.done)
            return
        }
        // The reply is the last NON-EMPTY assistant node past the baseline —
        // chatgpt.com can append empty placeholder assistant nodes after the
        // real one, which would otherwise stall completion forever.
        let js = """
        (() => {
          \(Self.domHelpersJS)
          const q = __assistantQuery();
          const nodes = q.nodes.slice(\(baseline));
          let text = "";
          for (let i = nodes.length - 1; i >= 0; i--) {
            const t = (nodes[i].innerText || "").trim();
            if (t.length > 0) { text = t; break; }
          }
          return JSON.stringify({
            count: q.nodes.length,
            strategy: q.strategy,
            streaming: !!__stopButton(),
            text,
            href: location.href,
            landmarksGone: q.strategy === "none" && !__composer() && !!document.querySelector("main")
          });
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.pollReply(gen: gen, baseline: baseline, lastText: lastText, stableCount: 0, deadline: deadline, onEvent: onEvent)
                }
                return
            }
            let count = obj["count"] as? Int ?? 0
            let streaming = obj["streaming"] as? Bool ?? false
            let text = obj["text"] as? String ?? ""
            let href = obj["href"] as? String ?? ""
            if (obj["landmarksGone"] as? Bool) == true {
                onEvent(.error("ChatGPT UI changed — message landmarks disappeared mid-reply."))
                onEvent(.done)
                return
            }

            // Stream partial text into the panel as it grows.
            if !text.isEmpty && text != lastText {
                onEvent(.partial(text))
            }

            let replied = count > baseline && !text.isEmpty
            let stable = replied && text == lastText && !streaming
            let nextStable = stable ? stableCount + 1 : 0

            // Two consecutive stable polls (~1.4s) = generation finished.
            if nextStable >= 2 {
                if let range = href.range(of: "/c/") {
                    let id = href[range.upperBound...].split(separator: "?")[0]
                    if !id.isEmpty { onEvent(.thread(String(id))) }
                }
                onEvent(.message(text))
                onEvent(.done)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.pollReply(gen: gen, baseline: baseline, lastText: text, stableCount: nextStable, deadline: deadline, onEvent: onEvent)
            }
        }
    }

    // MARK: - Login window

    private func presentLoginWindow() {
        if loginWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ChatGPT — NotchAgent"
            window.isReleasedWhenClosed = false
            window.center()
            loginWindow = window
        }
        webView.removeFromSuperview()
        webView.frame = loginWindow?.contentView?.bounds ?? webView.frame
        webView.autoresizingMask = [.width, .height]
        loginWindow?.contentView?.addSubview(webView)
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
    }

    private func hideLoginWindow() {
        guard let window = loginWindow, window.isVisible else { return }
        window.orderOut(nil)
        // Re-mount in the invisible host so the page keeps rendering.
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        hostWindow.contentView?.addSubview(webView)
    }

    // MARK: - Helpers

    private func run(_ js: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(js) { result, _ in
            completion(result)
        }
    }

    private static func jsonString(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]) else { return nil }
        guard let arr = String(data: data, encoding: .utf8) else { return nil }
        return arr + "[0]"
    }
}
