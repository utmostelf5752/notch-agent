import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

// Embedded chatgpt.com provider: the app owns a persistent WKWebView.
// Anonymous text chats use chatgpt.com's signed-out composer. Features that
// require an account, such as attachments, open a real sign-in window (cookies
// persist in the app's own WebKit store); prompts are otherwise injected into
// the hidden web view and the reply is scraped from the DOM.
// Selector set ported from codex-chatgpt-control's dom helpers.
final class ChatGPTWeb: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate, NSWindowDelegate {
    enum AccountStatus: Equatable {
        case checking
        case signedOut
        case signedIn(email: String?)
    }

    enum Event {
        case status(String)
        case thread(String)
        case partial(String)
        case message(String)
        case limit(String, uploadsOnly: Bool)
        case error(String)
        // The message was posted and consumed usage; only reading the reply
        // failed. Must not be reported as "message not sent".
        case replyError(String)
        case done
    }

    static let shared = ChatGPTWeb()

    @Published private(set) var accountStatus: AccountStatus = .checking

    private static let accountStateKey = "chatgptAccountState"
    private static let accountEmailKey = "chatgptAccountEmail"

    private var webView: WKWebView!
    private var hostWindow: NSWindow!
    private var loginWindow: NSWindow?
    private var authPopupWindows: [ObjectIdentifier: (webView: WKWebView, window: NSWindow)] = [:]
    private var completingAuthPopups: Set<ObjectIdentifier> = []
    private var cancelled = false
    private var generation = 0
    private var preparingSignedOutLogin = false
    private var presentLoginAfterFreshLoad = false
    private var freshLoginNavigation: WKNavigation?
    private var mainAuthFlowInProgress = false
    private var awaitingAuthResult = false
    private var authResultChecksRemaining = 0

    // Multi-strategy selectors: chatgpt.com renames data-testid / role attrs
    // periodically. Prefer current attrs, then historical / structural fallbacks.
    private static let sendSelector = "button[data-testid='send-button'], button[data-testid='composer-submit-button'], #composer-submit-button, button[aria-label*='Send'], button[aria-label*='Send message'], form button[type='submit']"
    private static let stopSelector = "button[aria-label*='Stop'], button[data-testid='stop-button'], button[aria-label*='Stop generating'], button[aria-label*='Stop streaming']"

    // Shared DOM helpers injected into scrape/inject scripts. Single source of
    // truth for composer + message node resolution so fallbacks stay consistent.
    private static let domHelpersJS = #"""
    const __visible = (el) => !!(el && el.getClientRects && el.getClientRects().length > 0);
    const __composer = () => {
      const cands = document.querySelectorAll(
        "#prompt-textarea, #mobile-composer-prompt, [data-testid='prompt-textarea'], div[role='textbox'], " +
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
      { name: "data-message-role-visible", fn: () => Array.from(document.querySelectorAll("[data-message-role='assistant']")).filter(n => !n.closest("[hidden]")) },
      { name: "data-message-role", fn: () => document.querySelectorAll("[data-message-role='assistant']") },
      { name: "data-testid-assistant", fn: () => document.querySelectorAll("[data-testid='assistant-message'], [data-testid='conversation-turn-assistant']") },
      { name: "data-turn", fn: () => document.querySelectorAll("[data-turn='assistant'], article[data-turn='assistant']") },
      { name: "aria-assistant", fn: () => document.querySelectorAll("[aria-label*='ChatGPT said'], [data-message-id][data-author='assistant']") }
    ]);
    const __userQuery = () => __nodesByStrategies([
      { name: "data-message-author-role", fn: () => document.querySelectorAll("[data-message-author-role='user']") },
      { name: "data-message-role-visible", fn: () => Array.from(document.querySelectorAll("[data-message-role='user']")).filter(n => !n.closest("[hidden]")) },
      { name: "data-message-role", fn: () => document.querySelectorAll("[data-message-role='user']") },
      { name: "data-testid-user", fn: () => document.querySelectorAll("[data-testid='user-message'], [data-testid='conversation-turn-user']") },
      { name: "data-turn", fn: () => document.querySelectorAll("[data-turn='user'], article[data-turn='user']") },
      { name: "aria-user", fn: () => document.querySelectorAll("[aria-label*='You said'], [data-message-id][data-author='user']") }
    ]);
    const __normalizeMarkdown = (value) => String(value || "")
      .split(String.fromCharCode(160)).join(" ")
      .split("\r\n").join("\n")
      .split("\r").join("\n")
      .split("\n").map(line => line.replace(/[ \t]+$/g, "")).join("\n")
      .replace(/\n{3,}/g, "\n\n")
      .trim();
    const __inlineCode = (value) => {
      const code = String(value || "").replace(/\n+/g, " ").trim();
      if (!code) return "";
      const runs = code.match(/`+/g) || [];
      const fence = "`".repeat(Math.max(1, ...runs.map(run => run.length + 1)));
      const pad = code.startsWith("`") || code.endsWith("`") ? " " : "";
      return fence + pad + code + pad + fence;
    };
    const __codeLanguage = (pre, code) => {
      const values = [
        code && code.getAttribute("data-language"),
        pre && pre.getAttribute("data-language"),
        code && code.className,
        pre && pre.className
      ].filter(value => typeof value === "string" && value.length);
      for (const value of values) {
        const match = value.match(/(?:language-|lang-)([A-Za-z0-9_+#.-]+)/i);
        if (match) return match[1];
        if (/^[A-Za-z0-9_+#.-]{1,24}$/.test(value)) return value;
      }
      return "";
    };
    const __serializeChildren = (el) => Array.from(el.childNodes)
      .map(child => __serializeMarkdownNode(child))
      .join("");
    const __serializeList = (list, ordered) => {
      const items = Array.from(list.children).filter(child => child.tagName === "LI");
      const lines = [];
      items.forEach((item, index) => {
        const nestedLists = Array.from(item.children).filter(child => child.tagName === "UL" || child.tagName === "OL");
        const nestedSet = new Set(nestedLists);
        const body = Array.from(item.childNodes)
          .filter(child => !nestedSet.has(child))
          .map(child => __serializeMarkdownNode(child))
          .join("")
          .replace(/\n{2,}/g, "\n")
          .trim();
        lines.push((ordered ? String(index + 1) + ". " : "- ") + body);
        nestedLists.forEach(nested => {
          const nestedText = __serializeList(nested, nested.tagName === "OL").trimEnd();
          if (nestedText) lines.push(nestedText.split("\n").map(line => "  " + line).join("\n"));
        });
      });
      return lines.length ? lines.join("\n") + "\n\n" : "";
    };
    const __serializeMarkdownNode = (node) => {
      if (!node) return "";
      if (node.nodeType === Node.TEXT_NODE) {
        return String(node.nodeValue || "").replace(/[ \t\n\r]+/g, " ");
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return "";
      const el = node;
      const tag = el.tagName;
      if (["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "BUTTON", "INPUT", "TEXTAREA"].includes(tag)) return "";
      if (el.getAttribute("aria-hidden") === "true") return "";
      if (el.matches("[data-message-attribution], [role='status'], [data-streaming-placeholder]")) return "";
      if (/(?:^|[_\s-])sr-?only(?:[_\s-]|$)/i.test(String(el.className || ""))) return "";

      if (el.matches(".katex, .katex-display")) {
        const annotation = el.querySelector("annotation[encoding='application/x-tex']");
        if (annotation && annotation.textContent) {
          const tex = annotation.textContent.trim();
          return el.matches(".katex-display") ? "\n\n$$" + tex + "$$\n\n" : "$" + tex + "$";
        }
      }

      if (/^H[1-6]$/.test(tag)) {
        const level = Number(tag.slice(1));
        const text = __serializeChildren(el).trim();
        return text ? "#".repeat(level) + " " + text + "\n\n" : "";
      }
      if (tag === "P") {
        const text = __serializeChildren(el).trim();
        return text ? text + "\n\n" : "";
      }
      if (tag === "BR") return "\n";
      if (tag === "HR") return "\n\n---\n\n";
      if (tag === "UL" || tag === "OL") return __serializeList(el, tag === "OL");
      if (tag === "BLOCKQUOTE") {
        const text = __normalizeMarkdown(__serializeChildren(el));
        return text ? text.split("\n").map(line => "> " + line).join("\n") + "\n\n" : "";
      }
      if (tag === "PRE") {
        const codeNode = el.querySelector("code") || el;
        const code = String(codeNode.textContent || "").replace(/\n$/, "");
        if (!code) return "";
        const runs = code.match(/`+/g) || [];
        const fence = "`".repeat(Math.max(3, ...runs.map(run => run.length + 1)));
        const language = __codeLanguage(el, codeNode);
        return "\n\n" + fence + language + "\n" + code + "\n" + fence + "\n\n";
      }
      if (tag === "CODE") return __inlineCode(el.textContent);
      if (tag === "STRONG" || tag === "B") {
        const text = __serializeChildren(el).trim();
        return text ? "**" + text + "**" : "";
      }
      if (tag === "EM" || tag === "I") {
        const text = __serializeChildren(el).trim();
        return text ? "*" + text + "*" : "";
      }
      if (tag === "DEL" || tag === "S") {
        const text = __serializeChildren(el).trim();
        return text ? "~~" + text + "~~" : "";
      }
      if (tag === "A") {
        const text = __serializeChildren(el).trim();
        const href = el.href || el.getAttribute("href") || "";
        if (!text || !href || href.toLowerCase().startsWith("javascript:")) return text;
        return "[" + text + "](" + href.split(")").join("%29") + ")";
      }
      if (tag === "IMG") return el.getAttribute("alt") || "";

      return __serializeChildren(el);
    };
    const __messageContentRoot = (node) => {
      if (!node || !node.querySelector) return null;
      const selector = "[data-message-content], [data-assistant-markdown], .markdown, .prose";
      if (node.matches && node.matches(selector)) return node;
      // Never fall back to the whole assistant turn. Before the response body
      // mounts it contains UI chrome such as “Analyzing image” and the hidden
      // screen-reader attribution “ChatGPT says:”.
      return node.querySelector(selector);
    };
    const __stripAssistantChrome = (value) => {
      let text = __normalizeMarkdown(value);
      const prefixes = [
        /^Analyzing (?:the )?image(?:\.{3}|…)?\s*/i,
        /^ChatGPT (?:says|said):?\s*/i
      ];
      let changed = true;
      while (changed) {
        changed = false;
        for (const prefix of prefixes) {
          const next = text.replace(prefix, "");
          if (next !== text) { text = next; changed = true; }
        }
      }
      return text.trim();
    };
    const __assistantMarkdown = (node) => {
      if (!node) return "";
      const root = __messageContentRoot(node);
      if (!root) return "";
      const plain = __stripAssistantChrome(root.innerText || root.textContent || "");
      try {
        const semantic = __stripAssistantChrome(__serializeMarkdownNode(root));
        return semantic || plain;
      } catch (_) {
        return plain;
      }
    };
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
    const __isStreaming = () => !!__stopButton() || !!document.querySelector("[data-streaming-dot]");
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
    """#

    private override init() {
        super.init()
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: Self.accountStateKey) {
        case "signedIn":
            accountStatus = .signedIn(email: defaults.string(forKey: Self.accountEmailKey))
        case "signedOut":
            accountStatus = .signedOut
        default:
            break
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 800), configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
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

        // Check the persistent WebKit session once at app launch. The last
        // result stays visible immediately while this background refresh runs.
        webView.load(URLRequest(url: URL(string: "https://chatgpt.com/")!))
    }

    // MARK: - Public

    func showAccountWindow() {
        if preparingSignedOutLogin {
            presentLoginAfterFreshLoad = true
            return
        }
        if accountStatus == .signedOut {
            prepareFreshSignedOutLogin(presentWhenReady: true)
            return
        }
        let current = webView.url?.absoluteString ?? ""
        let shouldReload: Bool
        switch accountStatus {
        case .signedOut:
            shouldReload = true
        case .checking:
            shouldReload = !current.hasPrefix("https://chatgpt.com")
                && !Self.isAuthenticationFlowURL(webView.url)
        case .signedIn:
            shouldReload = !current.hasPrefix("https://chatgpt.com")
                || Self.isLogoutURL(webView.url)
        }
        if shouldReload {
            webView.load(Self.freshChatGPTRequest())
        }
        presentLoginWindow()
    }

    func refreshAccountStatus() {
        let current = webView.url?.absoluteString ?? ""
        guard current.hasPrefix("https://chatgpt.com") else {
            if Self.isAuthenticationFlowURL(webView.url) {
                mainAuthFlowInProgress = true
                setAccountStatus(.checking)
            } else {
                webView.load(Self.freshChatGPTRequest())
            }
            return
        }
        if Self.isAuthenticationFlowURL(webView.url) {
            mainAuthFlowInProgress = true
            setAccountStatus(.checking)
            return
        }
        run(#"""
        (() => {
          const visible = node => !!(node && node.getClientRects && node.getClientRects().length);
          const controls = Array.from(document.querySelectorAll("button, a"));
          const signedOut = controls.some(node => {
            if (!visible(node)) return false;
            const label = String(node.getAttribute("aria-label") || node.innerText || node.textContent || "").trim();
            return /^(log in|sign up|sign up for free)$/i.test(label)
              || /\blog in to use\b/i.test(label);
          });
          const composer = document.querySelector(
            "#prompt-textarea, #mobile-composer-prompt, [data-testid='prompt-textarea'], " +
            "div[role='textbox'], main [contenteditable='true'], main textarea"
          );
          const accountNodes = Array.from(document.querySelectorAll(
            "[data-testid*='account'], [data-testid*='profile'], [aria-label*='account' i], " +
            "[aria-label*='profile' i], [title*='account' i], [title*='profile' i]"
          ));
          const accountText = accountNodes.map(node => [
            node.getAttribute("aria-label"), node.getAttribute("title"), node.innerText, node.textContent
          ].filter(Boolean).join(" ")).join("\n");
          const email = accountText.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i)?.[0] || null;
          return JSON.stringify({ signedIn: !!composer && !signedOut, email });
        })()
        """#) { [weak self] result in
            guard let self else { return }
            let info = Self.decode(result) ?? [:]
            if info["signedIn"] as? Bool == true {
                self.mainAuthFlowInProgress = false
                self.awaitingAuthResult = false
                self.authResultChecksRemaining = 0
                let email = (info["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.setAccountStatus(.signedIn(email: email?.isEmpty == false ? email : nil))
            } else if self.awaitingAuthResult && self.authResultChecksRemaining > 0 {
                self.authResultChecksRemaining -= 1
                let remaining = self.authResultChecksRemaining
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if remaining % 2 == 0 {
                        // A late cookie write only takes effect on a fresh
                        // page; the load's didFinish re-runs this check.
                        self.webView.load(Self.freshChatGPTRequest())
                    } else {
                        // Re-probe in place first: slow hydration resolves
                        // without a reload, and reloading restarts it.
                        self.refreshAccountStatus()
                    }
                }
            } else if self.awaitingAuthResult {
                self.awaitingAuthResult = false
                // Sign-in may still be settling server-side. Leave cookies
                // untouched — wiping auth state here logs out a login that
                // actually succeeded; the next load or manual retry will
                // pick the session up if it exists.
                self.setAccountStatus(.signedOut)
            } else if self.mainAuthFlowInProgress {
                self.mainAuthFlowInProgress = false
                self.setAccountStatus(.signedOut)
                self.prepareFreshSignedOutLogin(presentWhenReady: true)
            } else {
                let wasSignedIn: Bool
                if case .signedIn = self.accountStatus {
                    wasSignedIn = true
                } else {
                    wasSignedIn = false
                }
                self.setAccountStatus(.signedOut)
                if wasSignedIn {
                    self.prepareFreshSignedOutLogin(
                        presentWhenReady: self.loginWindow?.isVisible == true
                    )
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView !== self.webView {
            finishAuthPopupIfReturnedToChatGPT(webView)
            return
        }
        if Self.isAuthenticationFlowURL(webView.url) {
            mainAuthFlowInProgress = true
            setAccountStatus(.checking)
            return
        }
        if preparingSignedOutLogin && navigation !== freshLoginNavigation {
            return
        }
        if preparingSignedOutLogin {
            preparingSignedOutLogin = false
            freshLoginNavigation = nil
            if presentLoginAfterFreshLoad {
                presentLoginAfterFreshLoad = false
                presentLoginWindow()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshAccountStatus()
        }
    }

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
        let hasScreenshot = files.contains {
            AppPaths.isScreenshotName($0.lastPathComponent)
        }
        let initialStatus = files.isEmpty
            ? "Opening chatgpt.com"
            : (hasScreenshot ? "Reading screenshot" : "Reading attachment")
        onEvent(.status(initialStatus))

        waitForComposer(gen: gen, deadline: Date().addingTimeInterval(300), loginShown: false, onEvent: onEvent) { [weak self] in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let uploadAndSend = {
                self.hideLoginWindow()
                self.uploadFiles(files, gen: gen, onEvent: onEvent) {
                    self.baselineAndSend(prompt: prompt, gen: gen, onEvent: onEvent)
                }
            }
            if files.isEmpty {
                uploadAndSend()
            } else {
                self.waitForFileUploads(
                    gen: gen,
                    deadline: Date().addingTimeInterval(300),
                    loginShown: false,
                    onEvent: onEvent,
                    then: uploadAndSend
                )
            }
        }
    }

    private func waitForFileUploads(
        gen: Int,
        deadline: Date,
        loginShown: Bool,
        onEvent: @escaping (Event) -> Void,
        then: @escaping () -> Void
    ) {
        guard !cancelled, gen == generation else { return }
        guard Date() < deadline else {
            onEvent(.error("Timed out waiting for ChatGPT sign-in. Pictures and files require a signed-in ChatGPT session."))
            onEvent(.done)
            return
        }
        run(#"""
        (() => {
          const inputs = Array.from(document.querySelectorAll("input[type='file']"))
            .filter(input => input.isConnected && !input.disabled);
          const labels = Array.from(document.querySelectorAll("button, [aria-label], [role='alert'], [role='dialog']"))
            .map(node => String(node.getAttribute("aria-label") || node.innerText || node.textContent || "").trim())
            .filter(Boolean);
          const signedOut = labels.some(label =>
            /^(log in|sign up|sign up for free)$/i.test(label)
          );
          const loginReason = labels.find(label =>
            /(?:add|upload).*(?:file|image).*log in to use/i.test(label)
          ) || "";
          const limitReason = labels.find(label =>
            /(?:file|image|upload|attachment)/i.test(label) &&
            /(?:limit|quota|allowance|free plan|upgrade|try again later|temporarily unavailable|not available)/i.test(label)
          ) || "";
          return JSON.stringify({
            ready: inputs.length > 0 && !signedOut && !loginReason && !limitReason,
            signedOut,
            loginReason,
            limitReason: limitReason.slice(0, 240),
            inputCount: inputs.length
          });
        })()
        """#) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let info = Self.decode(result) ?? [:]
            if info["ready"] as? Bool == true {
                self.refreshAccountStatus()
                then()
                return
            }
            if let reason = info["limitReason"] as? String, !reason.isEmpty {
                onEvent(.limit(reason, uploadsOnly: true))
                onEvent(.done)
                return
            }
            var shown = loginShown
            let needsLogin = info["signedOut"] as? Bool == true
                || (info["loginReason"] as? String)?.isEmpty == false
            if needsLogin, !shown {
                self.setAccountStatus(.signedOut)
                self.presentLoginWindow()
                onEvent(.status("Pictures and files require a ChatGPT account — sign in in the popup"))
                shown = true
            }
            let shownFinal = shown
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.waitForFileUploads(
                    gen: gen,
                    deadline: deadline,
                    loginShown: shownFinal,
                    onEvent: onEvent,
                    then: then
                )
            }
        }
    }

    // Attach files by loading their bytes into the composer-owned file input.
    // ChatGPT keeps stale/hidden inputs elsewhere in the page, so selecting the
    // first input and sleeping can leave the send button disabled forever.
    // Wait for a real attachment preview before moving on or sending the prompt.
    private func uploadFiles(_ files: [URL], gen: Int, onEvent: @escaping (Event) -> Void, then: @escaping () -> Void) {
        guard !cancelled, gen == generation else { return }
        guard let file = files.first else {
            then()
            return
        }
        let rest = Array(files.dropFirst())
        guard let data = try? Data(contentsOf: file), data.count <= 10_000_000 else {
            onEvent(.error("Couldn't attach \(file.lastPathComponent) (unreadable or over 10 MB)."))
            onEvent(.done)
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let js = #"""
        const composer = document.querySelector(
          "#prompt-textarea, [data-testid='prompt-textarea'], div[role='textbox'], main [contenteditable='true'], main textarea"
        );
        const form = composer && composer.closest("form");
        const inputs = Array.from(document.querySelectorAll("input[type='file']"))
          .filter(input => input.isConnected && !input.disabled);
        const score = input => {
          let value = 0;
          if (form && input.closest("form") === form) value += 100;
          if (composer && composer.parentElement && composer.parentElement.contains(input)) value += 60;
          const accept = String(input.accept || "").toLowerCase();
          if (accept.includes("image") || accept.includes("*/*")) value += 20;
          if (input.multiple) value += 5;
          return value;
        };
        inputs.sort((a, b) => score(b) - score(a));
        const input = inputs[0];
        if (!input) return JSON.stringify({ ok: false, reason: "no-input" });

        const root = form || (composer && composer.parentElement) || document.querySelector("main") || document.body;
        const signalCount = () => {
          const nodes = root.querySelectorAll(
            "[data-testid*='attachment'], [data-testid*='file-preview'], [aria-label*='Remove file' i], " +
            "[aria-label*='Remove attachment' i], img[src^='blob:'], img[src^='data:image']"
          );
          return nodes.length;
        };
        const baseline = signalCount();
        const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
        const browserFile = new File([bytes], filename, { type: mimeType });
        const dt = new DataTransfer();
        dt.items.add(browserFile);
        window.__notchAgentUploadProblem = "";
        const rememberUploadProblem = node => {
          const value = String(node && (node.innerText || node.textContent) || "").trim();
          if (!value || value.length > 600) return;
          if (/(?:upload|file|image|attachment)/i.test(value) &&
              /(?:limit|quota|allowance|upgrade|free plan|try again later|temporarily unavailable|not available)/i.test(value)) {
            window.__notchAgentUploadProblem = value.slice(0, 240);
          }
        };
        const uploadObserver = new MutationObserver(records => {
          records.forEach(record => {
            if (record.type === "characterData") {
              rememberUploadProblem(record.target.parentElement || record.target);
            }
            record.addedNodes.forEach(rememberUploadProblem);
          });
        });
        uploadObserver.observe(document.body, { childList: true, subtree: true, characterData: true });
        setTimeout(() => uploadObserver.disconnect(), 35000);
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "files")?.set;
        if (!setter) return JSON.stringify({ ok: false, reason: "no-files-setter" });
        setter.call(input, dt.files);
        const injectedExactFile = Array.from(input.files || [])
          .some(file => file.name === filename && file.size === bytes.length);
        if (!injectedExactFile) return JSON.stringify({ ok: false, reason: "file-input-rejected" });
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
        return JSON.stringify({
          ok: true,
          baseline,
          inputCount: inputs.length,
          score: score(input),
          accept: input.accept || ""
        });
        """#
        runAsync(js, arguments: [
            "base64": data.base64EncodedString(),
            "filename": file.lastPathComponent,
            "mimeType": mime,
        ]) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let info = Self.decode(result) ?? [:]
            guard info["ok"] as? Bool == true else {
                let reason = info["reason"] as? String ?? "upload script failed"
                onEvent(.error("Couldn't attach \(file.lastPathComponent) on chatgpt.com (\(reason))."))
                onEvent(.done)
                return
            }
            self.waitForAttachment(
                file: file,
                baseline: info["baseline"] as? Int ?? 0,
                gen: gen,
                deadline: Date().addingTimeInterval(30),
                onEvent: onEvent
            ) {
                self.uploadFiles(rest, gen: gen, onEvent: onEvent, then: then)
            }
        }
    }

    private func waitForAttachment(
        file: URL,
        baseline: Int,
        gen: Int,
        deadline: Date,
        onEvent: @escaping (Event) -> Void,
        then: @escaping () -> Void
    ) {
        guard !cancelled, gen == generation else { return }
        let expired = Date() >= deadline
        let name = Self.jsonString(file.lastPathComponent) ?? "\"file\""
        let js = """
        (() => {
          const composer = document.querySelector(
            "#prompt-textarea, [data-testid='prompt-textarea'], div[role='textbox'], main [contenteditable='true'], main textarea"
          );
          const root = (composer && composer.closest("form")) ||
            (composer && composer.parentElement) || document.querySelector("main") || document.body;
          const signals = root.querySelectorAll(
            "[data-testid*='attachment'], [data-testid*='file-preview'], [aria-label*='Remove file' i], " +
            "[aria-label*='Remove attachment' i], img[src^='blob:'], img[src^='data:image']"
          ).length;
          const text = String(root.innerText || root.textContent || "");
          const pending = !!root.querySelector(
            "[role='progressbar'], [data-testid*='upload-progress'], [aria-label*='Uploading' i]"
          ) || /uploading|processing file/i.test(text);
          const notices = Array.from(document.querySelectorAll(
            "[role='alert'], [role='dialog'], [aria-live], [data-testid*='toast']"
          ))
            .map(node => String(node.innerText || node.textContent || "").trim())
            .filter(Boolean);
          const uploadLimitReason = window.__notchAgentUploadProblem || notices.find(value =>
            /(?:upload|file|image|attachment)/i.test(value) &&
            /(?:limit|quota|allowance|upgrade|free plan|try again later|temporarily unavailable|not available)/i.test(value)
          ) || "";
          const blockedReason = notices.find(value =>
            /(?:file|image|upload|attachment).*(?:failed|could not|couldn't)/i.test(value)
          ) || "";
          return JSON.stringify({
            // uploadFiles already proved the exact name and byte count were
            // installed in the composer input. React may clear that input as
            // it converts the file into an image-only preview, so the resulting
            // composer-local preview increase is the completion signal here.
            ready: (signals > \(baseline) || text.includes(\(name))) && !pending,
            signals,
            pending,
            uploadLimitReason: uploadLimitReason.slice(0, 240),
            blockedReason: blockedReason.slice(0, 240)
          });
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let info = Self.decode(result) ?? [:]
            if let reason = info["uploadLimitReason"] as? String, !reason.isEmpty {
                onEvent(.limit(reason, uploadsOnly: true))
                onEvent(.done)
                return
            }
            if let reason = info["blockedReason"] as? String, !reason.isEmpty {
                onEvent(.error("ChatGPT cannot attach \(file.lastPathComponent): \(reason)"))
                onEvent(.done)
                return
            }
            if info["ready"] as? Bool == true {
                then()
                return
            }
            if expired {
                onEvent(.error("chatgpt.com never finished attaching \(file.lastPathComponent)."))
                onEvent(.done)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.waitForAttachment(
                    file: file,
                    baseline: baseline,
                    gen: gen,
                    deadline: deadline,
                    onEvent: onEvent,
                    then: then
                )
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
        // Step 1: use the native value setter for React-controlled textareas,
        // fall back to contenteditable insertion, and record message baselines.
        let insertJS = """
        (() => {
          \(Self.domHelpersJS)
          const el = __composer();
          if (!el) return JSON.stringify({s: "no-composer", probe: __probeUI()});
          const P = \(promptJSON);
          window.__notchAgentUsageProblem = "";
          // Only alert/toast/dialog containers count: the user's own echoed
          // prompt and the streamed reply mutate constantly and can mention
          // plans, rates, and limits without any limit being hit.
          const noticeSelector = "[role='alert'], [role='dialog'], [data-testid*='toast']";
          const noticeHost = node => {
            const el = node instanceof Element ? node : (node ? node.parentElement : null);
            if (!el) return null;
            return el.closest(noticeSelector)
              || (el.querySelector ? el.querySelector(noticeSelector) : null);
          };
          const rememberUsageProblem = node => {
            const host = noticeHost(node);
            if (!host) return;
            const value = String(host.innerText || host.textContent || "").trim();
            if (!value || value.length > 600) return;
            if (/(?:usage|quota|credits|requests|plan|rate)/i.test(value) &&
                /(?:limit|reached|exceeded|exhausted|try again|reset|upgrade)/i.test(value)) {
              window.__notchAgentUsageProblem = value.slice(0, 240);
            }
          };
          const usageObserver = new MutationObserver(records => {
            records.forEach(record => {
              if (record.type === "characterData") {
                rememberUsageProblem(record.target.parentElement || record.target);
              }
              record.addedNodes.forEach(rememberUsageProblem);
            });
          });
          usageObserver.observe(document.body, { childList: true, subtree: true, characterData: true });
          setTimeout(() => usageObserver.disconnect(), 30000);
          el.focus();
          if (el instanceof HTMLTextAreaElement || el instanceof HTMLInputElement) {
            const proto = el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
            if (!setter) return JSON.stringify({s: "no-value-setter", probe: __probeUI()});
            setter.call(el, P);
            el.dispatchEvent(new InputEvent("input", {
              bubbles: true,
              inputType: "insertText",
              data: P
            }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
          } else {
            document.execCommand("selectAll", false, null);
            const ok = document.execCommand("insertText", false, P);
            if (!ok || !(el.innerText || el.textContent || "").trim()) {
              el.textContent = P;
              el.dispatchEvent(new InputEvent("input", {
                bubbles: true,
                inputType: "insertText",
                data: P
              }));
            }
          }
          const a = __assistantQuery();
          const u = __userQuery();
          const aLast = a.nodes.length ? __assistantMarkdown(a.nodes[a.nodes.length - 1]) : "";
          return JSON.stringify({
            s: "inserted",
            aBase: a.nodes.length,
            aLast,
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
            let aLast = obj["aLast"] as? String ?? ""
            let uBase = obj["uBase"] as? Int ?? 0
            // Give the composer a beat to enable its send button.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                self.submit(prompt: prompt, gen: gen, aBase: aBase, aLast: aLast, uBase: uBase, onEvent: onEvent)
            }
        }
    }

    // Step 2: click send if a button is found, otherwise synthesize Enter.
    // A disabled button usually means an attachment is still uploading —
    // the composer preview appears before the server upload finishes, so
    // keep retrying for up to ~30s before falling back.
    private func submit(prompt: String, gen: Int, aBase: Int, aLast: String, uBase: Int, attempt: Int = 0, onEvent: @escaping (Event) -> Void) {
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
                    self.submit(prompt: prompt, gen: gen, aBase: aBase, aLast: aLast, uBase: uBase, attempt: attempt + 1, onEvent: onEvent)
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.verifySubmitted(prompt: prompt, gen: gen, aBase: aBase, aLast: aLast, uBase: uBase, onEvent: onEvent)
            }
        }
    }

    // Step 3: confirm the message actually left the composer; if not, report
    // what buttons exist so the failure is self-diagnosing.
    private func verifySubmitted(
        prompt: String,
        gen: Int,
        aBase: Int,
        aLast: String,
        uBase: Int,
        attempt: Int = 0,
        onEvent: @escaping (Event) -> Void
    ) {
        let promptJSON = Self.jsonString(prompt) ?? "\"\""
        let js = """
        (() => {
          \(Self.domHelpersJS)
          const a = __assistantQuery();
          const u = __userQuery();
          const composer = __composer();
          const composerText = composer
            ? String(("value" in composer ? composer.value : composer.innerText || composer.textContent) || "").trim()
            : "";
          const latestUserText = u.nodes.length
            ? String(u.nodes[u.nodes.length - 1].innerText || u.nodes[u.nodes.length - 1].textContent || "").trim()
            : "";
          const composerEmpty = !!composer && composerText.length === 0;
          const collapse = value => __normalizeMarkdown(value).replace(/\\s+/g, " ");
          return JSON.stringify({
            a: a.nodes.length,
            u: u.nodes.length,
            uStrategy: u.strategy,
            streaming: __isStreaming(),
            composerEmpty,
            exactPromptAccepted: u.nodes.length > \(uBase)
              && collapse(latestUserText).includes(collapse(\(promptJSON))),
            acceptedFallback: composerEmpty
              && (__isStreaming() || a.nodes.length > \(aBase) || u.nodes.length > \(uBase)),
            usageLimitReason: window.__notchAgentUsageProblem || "",
            probe: __probeUI()
          });
        })()
        """
        run(js) { [weak self] result in
            guard let self, !self.cancelled, gen == self.generation else { return }
            let obj = Self.decode(result) ?? [:]
            // Unrelated activity in the visible ChatGPT window must never
            // satisfy this transaction: require either the exact prompt as a
            // user node, or the composer WE filled having been consumed plus
            // fresh turn activity (the lightweight UI can keep the accepted
            // turn in a hidden optimistic transcript with no user node).
            let sent = obj["exactPromptAccepted"] as? Bool == true
                || obj["acceptedFallback"] as? Bool == true
            if sent {
                self.pollReply(gen: gen, baseline: aBase, baselineText: aLast, lastText: "", stableCount: 0,
                               deadline: Date().addingTimeInterval(240), onEvent: onEvent)
                return
            }
            // Only a limit that actually blocked the send is a limit; a
            // notice appearing after acceptance must not abort the turn.
            if let reason = obj["usageLimitReason"] as? String, !reason.isEmpty {
                onEvent(.limit(reason, uploadsOnly: false))
                onEvent(.done)
                return
            }
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.verifySubmitted(
                        prompt: prompt,
                        gen: gen,
                        aBase: aBase,
                        aLast: aLast,
                        uBase: uBase,
                        attempt: attempt + 1,
                        onEvent: onEvent
                    )
                }
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
            streaming: __isStreaming(),
            lastAssistant: last ? last.innerText.slice(0, 200) : null,
            lastAssistantTC: last ? last.textContent.slice(0, 200) : null,
            lastAssistantHTML: last ? last.innerHTML.slice(0, 400) : null,
            lastAssistantMarkdown: last ? __assistantMarkdown(last).slice(0, 1200) : null,
            roleAttrs: Array.from(document.querySelectorAll("[data-message-author-role]")).slice(0, 6).map(n => n.getAttribute("data-message-author-role")),
            composer: (() => { const el = __composer(); return el ? el.outerHTML.slice(0, 400) : null; })(),
            fileInputs: Array.from(document.querySelectorAll("input[type='file']")).map(input => ({
              accept: input.accept,
              multiple: input.multiple,
              disabled: input.disabled,
              connected: input.isConnected,
              form: !!input.closest("form")
            })),
            attachmentSignals: Array.from(document.querySelectorAll(
              "[data-testid*='attachment'], [data-testid*='file-preview'], [aria-label*='Remove file' i], " +
              "[aria-label*='Remove attachment' i], img[src^='blob:'], img[src^='data:image']"
            )).slice(0, 12).map(node => ({
              tag: node.tagName,
              testid: node.getAttribute("data-testid"),
              aria: node.getAttribute("aria-label"),
              text: String(node.innerText || node.textContent || "").slice(0, 100)
            })),
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

    private func pollReply(
        gen: Int,
        baseline: Int,
        baselineText: String,
        lastText: String,
        stableCount: Int,
        deadline: Date,
        onEvent: @escaping (Event) -> Void
    ) {
        guard !cancelled, gen == generation else { return }
        guard Date() < deadline else {
            onEvent(.replyError("Timed out waiting for the reply."))
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
            const t = __assistantMarkdown(nodes[i]);
            if (t.length > 0) { text = t; break; }
          }
          if (!text && q.nodes.length) {
            const latest = __assistantMarkdown(q.nodes[q.nodes.length - 1]);
            if (latest && latest !== \(Self.jsonString(baselineText) ?? "\"\"") ) text = latest;
          }
          return JSON.stringify({
            count: q.nodes.length,
            strategy: q.strategy,
            streaming: __isStreaming(),
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
                    self.pollReply(gen: gen, baseline: baseline, baselineText: baselineText, lastText: lastText, stableCount: 0, deadline: deadline, onEvent: onEvent)
                }
                return
            }
            let count = obj["count"] as? Int ?? 0
            let streaming = obj["streaming"] as? Bool ?? false
            let text = obj["text"] as? String ?? ""
            let href = obj["href"] as? String ?? ""
            if (obj["landmarksGone"] as? Bool) == true {
                onEvent(.replyError("ChatGPT UI changed — message landmarks disappeared mid-reply."))
                onEvent(.done)
                return
            }

            // Stream partial text into the panel as it grows.
            if !text.isEmpty && text != lastText {
                onEvent(.partial(text))
            }

            let replied = (count > baseline || text != baselineText) && !text.isEmpty
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
                self.pollReply(gen: gen, baseline: baseline, baselineText: baselineText, lastText: text, stableCount: nextStable, deadline: deadline, onEvent: onEvent)
            }
        }
    }

    // MARK: - Login window

    // OAuth providers such as Sign in with Apple open a separate browsing
    // context and communicate back through window.opener. Without a
    // WKUIDelegate WebKit silently discards that popup. Host it in a child
    // WKWebView created from the supplied configuration so it shares the
    // parent page's process pool, website data store, and authentication flow.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        let popup = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 540, height: 720),
            configuration: configuration
        )
        popup.customUserAgent = self.webView.customUserAgent
        popup.uiDelegate = self
        popup.navigationDelegate = self

        let width = windowFeatures.width.map { CGFloat(truncating: $0) } ?? 540
        let height = windowFeatures.height.map { CGFloat(truncating: $0) } ?? 720
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(width, 460), height: max(height, 620)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatGPT Sign In"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = popup
        window.center()
        authPopupWindows[ObjectIdentifier(popup)] = (popup, window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let entry = authPopupWindows.removeValue(forKey: key) else { return }
        completingAuthPopups.remove(key)
        webView.navigationDelegate = nil
        entry.window.delegate = nil
        entry.window.orderOut(nil)
        entry.window.close()
        reloadMainViewAfterAuthPopup()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }
        if closedWindow === loginWindow {
            mountMainWebViewInHost()
            // Abandoning sign-in with the web view parked on an identity
            // provider would otherwise pin accountStatus at .checking
            // forever: nothing re-navigates, and showAccountWindow declines
            // to reload while .checking on an auth URL.
            if mainAuthFlowInProgress || Self.isAuthenticationFlowURL(webView.url) {
                mainAuthFlowInProgress = false
                webView.load(Self.freshChatGPTRequest())
            }
            return
        }
        guard let match = authPopupWindows.first(where: { $0.value.window === closedWindow }) else { return }
        match.value.webView.uiDelegate = nil
        match.value.webView.navigationDelegate = nil
        authPopupWindows.removeValue(forKey: match.key)
        completingAuthPopups.remove(match.key)
        reloadMainViewAfterAuthPopup()
    }

    private func presentLoginWindow() {
        if loginWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ChatGPT — Eave"
            window.isReleasedWhenClosed = false
            window.delegate = self
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
        mountMainWebViewInHost()
    }

    private func mountMainWebViewInHost() {
        // Re-mount in the invisible host so the page keeps rendering after
        // sign-in completes or the account window is closed.
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        webView.frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        hostWindow.contentView?.addSubview(webView)
    }

    // MARK: - Helpers

    private func clearSignedOutAuthState(completion: @escaping () -> Void) {
        let store = webView.configuration.websiteDataStore
        store.httpCookieStore.getAllCookies { cookies in
            let authCookies = cookies.filter(Self.isTransientAuthCookie)
            guard !authCookies.isEmpty else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            let cookieCleanup = DispatchGroup()
            for cookie in authCookies {
                cookieCleanup.enter()
                store.httpCookieStore.delete(cookie) {
                    cookieCleanup.leave()
                }
            }
            cookieCleanup.notify(queue: .main) {
                completion()
            }
        }
    }

    private func finishAuthPopupIfReturnedToChatGPT(_ popup: WKWebView) {
        guard let host = popup.url?.host?.lowercased(),
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"),
              !Self.isAuthenticationFlowURL(popup.url),
              authPopupWindows[ObjectIdentifier(popup)] != nil else { return }

        let key = ObjectIdentifier(popup)
        guard completingAuthPopups.insert(key).inserted else { return }

        // ChatGPT's callback page can finish its cookie exchange after the
        // navigation itself completes. Keep the popup alive for that work;
        // closing it immediately can strand the main view in a signed-out
        // state even though the identity provider succeeded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.completingAuthPopups.remove(key)
            guard let entry = self.authPopupWindows.removeValue(forKey: key) else { return }
            popup.uiDelegate = nil
            popup.navigationDelegate = nil
            entry.window.delegate = nil
            entry.window.orderOut(nil)
            entry.window.close()
            self.reloadMainViewAfterAuthPopup()
        }
    }

    private func closeAuthPopupWindows() {
        let entries = Array(authPopupWindows.values)
        authPopupWindows.removeAll()
        completingAuthPopups.removeAll()
        for entry in entries {
            entry.webView.uiDelegate = nil
            entry.webView.navigationDelegate = nil
            entry.window.delegate = nil
            entry.window.orderOut(nil)
            entry.window.close()
        }
    }

    private func reloadMainViewAfterAuthPopup() {
        // A popup may close itself before its last cookie write reaches the
        // shared data store. Reload after a short grace period in either the
        // self-close or callback-navigation path.
        awaitingAuthResult = true
        authResultChecksRemaining = 6
        setAccountStatus(.checking)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.webView.load(Self.freshChatGPTRequest())
            self.presentLoginWindow()
        }
    }

    private func prepareFreshSignedOutLogin(presentWhenReady: Bool) {
        if preparingSignedOutLogin {
            presentLoginAfterFreshLoad = presentLoginAfterFreshLoad || presentWhenReady
            return
        }
        preparingSignedOutLogin = true
        presentLoginAfterFreshLoad = presentWhenReady
        mainAuthFlowInProgress = false
        awaitingAuthResult = false
        authResultChecksRemaining = 0
        setAccountStatus(.checking)
        closeAuthPopupWindows()
        hideLoginWindow()
        clearSignedOutAuthState { [weak self] in
            guard let self else { return }
            self.freshLoginNavigation = self.webView.load(Self.freshChatGPTRequest())
        }
    }

    private static func freshChatGPTRequest() -> URLRequest {
        URLRequest(
            url: URL(string: "https://chatgpt.com/")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
    }

    private static func isTransientAuthCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let name = cookie.name.lowercased()
        if domain == "chatgpt.com" || domain.hasSuffix(".chatgpt.com") {
            // The session token IS the sign-in; deleting it logs out a valid
            // session. Only pre-login handshake state is transient.
            if name.contains("session-token") { return false }
            return name.contains("next-auth")
                || name.contains("oauth")
                || name.contains("csrf")
        }
        guard domain == "auth.openai.com"
                || domain.hasSuffix(".auth.openai.com")
                || domain == "auth0.com"
                || domain.hasSuffix(".auth0.com") else { return false }
        return name != "__cf_bm"
            && name != "__cflb"
            && name != "cf_clearance"
    }

    private static func isAuthenticationFlowURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            let path = url.path.lowercased()
            return path.hasPrefix("/api/auth/") || path.hasPrefix("/auth/")
        }
        return host == "auth.openai.com"
            || host.hasSuffix(".auth.openai.com")
            || host == "appleid.apple.com"
            || host.hasSuffix(".appleid.apple.com")
            || host == "accounts.google.com"
            || host == "login.microsoftonline.com"
            || host.hasSuffix(".login.microsoftonline.com")
            || host == "login.live.com"
            || host == "auth0.com"
            || host.hasSuffix(".auth0.com")
    }

    private static func isLogoutURL(_ url: URL?) -> Bool {
        guard let value = url?.absoluteString.lowercased() else { return false }
        return value.contains("logout")
            || value.contains("log-out")
            || value.contains("signout")
            || value.contains("sign-out")
    }

    private func setAccountStatus(_ status: AccountStatus) {
        accountStatus = status
        let defaults = UserDefaults.standard
        switch status {
        case .checking:
            return
        case .signedOut:
            defaults.set("signedOut", forKey: Self.accountStateKey)
            defaults.removeObject(forKey: Self.accountEmailKey)
        case .signedIn(let email):
            defaults.set("signedIn", forKey: Self.accountStateKey)
            if let email, !email.isEmpty {
                defaults.set(email, forKey: Self.accountEmailKey)
            } else {
                defaults.removeObject(forKey: Self.accountEmailKey)
            }
        }
    }

    private func run(_ js: String, completion: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(js) { result, _ in
            completion(result)
        }
    }

    private func runAsync(
        _ js: String,
        arguments: [String: Any],
        completion: @escaping (Any?) -> Void
    ) {
        Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript(
                    js,
                    arguments: arguments,
                    in: nil,
                    contentWorld: .page
                )
                completion(value)
            } catch {
                completion(nil)
            }
        }
    }

    private static func jsonString(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]) else { return nil }
        guard let arr = String(data: data, encoding: .utf8) else { return nil }
        return arr + "[0]"
    }
}
