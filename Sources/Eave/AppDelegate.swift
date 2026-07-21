import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

// Borderless panel that can take keyboard focus without activating the app,
// so typing works while the previous app stays "active" (Spotlight-style).
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// The always-on notch window never becomes key, so without this a click on one
// of its SwiftUI buttons (Deny / Allow / Answer in background mode) is consumed
// just to bring the window forward and the button doesn't fire until a second
// click. Accepting first mouse makes a single click act immediately.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct HotKeyID {
        static let toggle: UInt32 = 1
        static let screenshot: UInt32 = 2
    }
    private var toggleHotKeyRef: EventHotKeyRef?
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var statusItem: NSStatusItem?
    private var runningObserver: AnyCancellable?
    private var shortcutObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Our windows must never participate in window tabbing; also silences
        // "Cannot index window tabs due to missing main bundle identifier".
        NSWindow.allowsAutomaticWindowTabbing = false
        let state = AppState.shared
        setUpTargetWindow(state: state)
        setUpChatPanel(state: state)
        state.applyWindowDiscretion()
        state.applyScreenShareProtection()
        setUpStatusItem(state: state)
        setUpMainMenu()
        installHotKey(state: state)
        installKeyMonitor()
        installSignalTriggers()
        state.startNotchWatch()
        state.installOutsideClickMonitors()
        state.installScreenObservers()
        state.startBackgroundObservers()
        state.logGeometry()
        _ = Updater.shared
        ChatGPTSelectors.startRefreshing()
        Telemetry.start(settingsSnapshot: {
            [
                "notch_style": AppState.shared.notchStyle.rawValue,
                "panel_style": AppState.shared.panelStyle.rawValue,
                "provider": AppState.shared.session.provider.rawValue,
                "screen_share_protection": String(AppState.shared.screenShareProtectionEnabled),
            ]
        })
    }

    // An accessory app has no menu bar, but key equivalents still route
    // through NSApp.mainMenu — without this Edit menu, Cmd+A/C/V/X/Z are dead.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Eave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // Debug hooks: `kill -USR1 <pid>` toggles the panel. `kill -USR2 <pid>`
    // executes commands from /tmp/eave-cmd (one per line):
    //   provider:<claude|codex|cursor|chatgpt>   switch provider
    //   send:<text>                       send a message
    //   msgs                              write transcript to /tmp/eave-msgs.txt
    //   dump                              write ChatGPT web view state to /tmp/eave-dom.txt
    //   newchat                           archive current chat and start fresh
    //   chats                             write history list to /tmp/eave-chats.txt
    //   restore:<index>                   reopen a past chat from the history list
    //   cfg                               write current provider settings to /tmp/eave-settings.txt
    //   update                            run a user-initiated Sparkle update check
    //   model:<id|default>                set the current provider's model
    // With no command file, USR2 just logs geometry.
    private var signalSources: [DispatchSourceSignal] = []
    private func installSignalTriggers() {
        for (sig, handler) in [
            (SIGUSR1, { AppState.shared.toggle() }),
            (SIGUSR2, { AppDelegate.handleDebugCommands() }),
        ] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
    }

    private static func handleDebugCommands() {
        let paths = ["/tmp/eave-cmd", "/tmp/notchagent-cmd"]
        guard let path = paths.first(where: FileManager.default.fileExists(atPath:)) else {
            AppState.shared.logGeometry()
            return
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            AppState.shared.logGeometry()
            return
        }
        try? FileManager.default.removeItem(atPath: path)
        let session = AppState.shared.session
        for line in raw.split(separator: "\n") {
            let cmd = line.trimmingCharacters(in: .whitespaces)
            if cmd.hasPrefix("provider:"), let p = AgentProvider(rawValue: String(cmd.dropFirst(9))) {
                session.provider = p
            } else if cmd.hasPrefix("send:") {
                AppState.shared.expand(takeKeyboard: false)
                session.send(String(cmd.dropFirst(5)))
            } else if cmd == "msgs" {
                let out = session.messages
                    .map { "[\($0.role)] \($0.text)" }
                    .joined(separator: "\n---\n")
                try? out.write(toFile: "/tmp/eave-msgs.txt", atomically: true, encoding: .utf8)
            } else if cmd == "dump" {
                ChatGPTWeb.shared.dumpState(to: "/tmp/eave-dom.txt")
            } else if cmd == "newchat" {
                session.reset()
            } else if cmd == "cfg" {
                let p = session.provider
                let out = """
                provider=\(p.rawValue)
                model=\(session.modelChoice[p] ?? "-")
                mode=\(session.modeChoice[p] ?? "-")
                effort=\(session.effortChoice[p] ?? "-")
                fast=\(session.fastModeChoice[p].map(String.init) ?? "-")
                cwd=\(session.workingDirectory.path)
                """
                try? out.write(toFile: "/tmp/eave-settings.txt", atomically: true, encoding: .utf8)
            } else if cmd == "chats" {
                let out = session.pastChats.enumerated().map { idx, chat in
                    "\(idx): [\(chat.provider.rawValue)] \(chat.title)"
                        + " claude=\(chat.claudeSessionID ?? "-")"
                        + " codex=\(chat.codexThreadID ?? "-")"
                        + " chatgpt=\(chat.chatgptThreadID ?? "-")"
                        + " cursor=\(chat.cursorSessionID ?? "-")"
                        + " cwd=\(chat.workingDirectory ?? "-")"
                }.joined(separator: "\n")
                try? out.write(toFile: "/tmp/eave-chats.txt", atomically: true, encoding: .utf8)
            } else if cmd.hasPrefix("restore:"),
                      let idx = Int(cmd.dropFirst(8)),
                      session.pastChats.indices.contains(idx) {
                AppState.shared.expand(takeKeyboard: false)
                session.restore(session.pastChats[idx])
            } else if cmd == "screenshot:full" {
                ScreenshotCapture.capture(.fullScreen)
            } else if cmd == "screenshot:window" {
                ScreenshotCapture.capture(.activeAppWindow)
            } else if cmd.hasPrefix("resize:") {
                let parts = cmd.dropFirst(7).split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 {
                    AppState.shared.applyPanelResize(width: CGFloat(parts[0]), height: CGFloat(parts[1]))
                }
            } else if cmd == "geom" {
                let s = AppState.shared
                let out = """
                panelWidth=\(s.panelWidth) panelHeight=\(s.panelHeight)
                min=\(s.minPanelWidth)x\(s.minPanelHeight) max=\(s.maxPanelWidth)x\(s.maxPanelHeight)
                expandedFrame=\(NSStringFromRect(s.expandedFrame))
                windowFrame=\(NSStringFromRect(s.chatPanel?.frame ?? .zero))
                """
                try? out.write(toFile: "/tmp/eave-geom.txt", atomically: true, encoding: .utf8)
            } else if cmd.hasPrefix("model:") {
                let value = String(cmd.dropFirst(6))
                if value == "default" {
                    session.modelChoice.removeValue(forKey: session.provider)
                } else {
                    session.modelChoice[session.provider] = value
                }
            } else if cmd.hasPrefix("mode:") {
                let value = String(cmd.dropFirst(5))
                if value == "default" {
                    session.modeChoice.removeValue(forKey: session.provider)
                } else {
                    session.modeChoice[session.provider] = value
                }
            } else if cmd == "allow" {
                session.respondPermission(.allow)
            } else if cmd == "always" {
                session.respondPermission(.always)
            } else if cmd == "deny" {
                session.respondPermission(.deny)
            } else if cmd.hasPrefix("answer:") {
                session.answerQuestion(String(cmd.dropFirst(7)))
            } else if cmd == "settings" {
                AppState.shared.openSettings()
            } else if cmd == "update" {
                Updater.shared.checkForUpdates()
            } else if cmd == "collapse" {
                AppState.shared.collapse()
            } else if cmd == "expand" {
                AppState.shared.expand(takeKeyboard: false)
            } else if cmd.hasPrefix("stealth:") {
                AppState.shared.notchStyle = cmd.dropFirst(8) == "on" ? .stealth : .standard
            } else if cmd.hasPrefix("style:"),
                      let style = AppState.NotchStyle(rawValue: String(cmd.dropFirst(6))) {
                AppState.shared.notchStyle = style
            } else if cmd.hasPrefix("glass:") {
                // Kept for compatibility: on = the clear pane, off = black.
                AppState.shared.panelStyle = cmd.dropFirst(6) == "on" ? .clear : .black
            } else if cmd.hasPrefix("panel:"),
                      let style = AppState.PanelStyle(rawValue: String(cmd.dropFirst(6))) {
                AppState.shared.panelStyle = style
            } else if cmd.hasPrefix("fake:") {
                // Simulate a completed turn without a CLI, to exercise the
                // background-mode UI (working strip, completion signal).
                let text = String(cmd.dropFirst(5))
                session.isRunning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    session.messages.append(ChatMessage(role: .assistant, text: text))
                    session.isRunning = false
                }
            } else if cmd == "pending" {
                var out = "expanded=\(AppState.shared.expanded)\n"
                out += "running=\(session.isRunning)\n"
                if let p = session.pendingPermission {
                    out += "permission: \(p.title) | \(p.detail) | always=\(p.canAlways)\n"
                }
                if let q = session.pendingQuestion {
                    let question = q.current
                    out += "question(\(q.index + 1)/\(q.questions.count)): [\(question.header)] "
                        + "\(question.question) multi=\(question.multiSelect) "
                        + "options=\(question.options.map(\.label).joined(separator: "; "))\n"
                }
                if session.pendingPermission == nil && session.pendingQuestion == nil {
                    out += "pending: none\n"
                }
                try? out.write(toFile: "/tmp/eave-state.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    private func setUpStatusItem(state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        Self.configureStatusButton(item.button, running: false)

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let hint = NSMenuItem(title: Self.menuHint(toggle: state.toggleShortcut), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let version = NSMenuItem(title: "Version \(Updater.shared.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Eave", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        runningObserver = state.session.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                // Silent screenshot turns keep the status bar appearance idle
                // so there is no visible "working" indicator anywhere.
                let silent = state.silentTurn
                Self.configureStatusButton(self?.statusItem?.button, running: running && !silent)
            }
        shortcutObserver = state.$toggleShortcut
            .receive(on: DispatchQueue.main)
            .sink { toggle in
                hint.title = Self.menuHint(toggle: toggle)
            }
    }

    private static func configureStatusButton(_ button: NSStatusBarButton?, running: Bool) {
        guard let button else { return }
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        image?.accessibilityDescription = running ? "Eave (working)" : "Eave"
        button.image = image
        button.contentTintColor = running ? .controlAccentColor : nil
        button.toolTip = running ? "Eave is working" : "Eave"
    }

    private static func menuHint(toggle: GlobalShortcut) -> String {
        "Press \(toggle.displayName) or hover notch"
    }

    // Full-screen screenshots fade the status button without removing its
    // status item, which avoids reflowing the menu bar or changing Spaces.
    @discardableResult
    func setStatusItemAlpha(_ alpha: CGFloat) -> CGFloat {
        let previous = statusItem?.button?.alphaValue ?? 1
        statusItem?.button?.alphaValue = alpha
        return previous
    }

    @objc private func togglePanel() {
        AppState.shared.toggle()
    }

    @objc private func openSettings() {
        AppState.shared.openSettings()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // Always-visible click target sitting exactly over the notch. Borderless
    // NSWindow never becomes key, so it can't steal keyboard focus.
    private func setUpTargetWindow(state: AppState) {
        let window = NSWindow(
            contentRect: state.collapsedFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovable = false
        window.contentView = FirstMouseHostingView(rootView: NotchTargetView(state: state, session: state.session))
        window.setFrame(state.collapsedFrame, display: true)
        window.orderFrontRegardless()
        state.targetWindow = window
    }

    private func setUpChatPanel(state: AppState) {
        let panel = NotchPanel(
            contentRect: state.expandedFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient]
        panel.isExcludedFromWindowsMenu = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        let hosting = NSHostingView(
            rootView: ChatRootView(state: state, session: state.session)
        )
        // The window frame is owned by AppState's resize math. Without this,
        // the hosting view constrains the window to the content's minimum
        // size, and shrinking past it makes AppKit re-expand the frame
        // rightward instead of clamping.
        hosting.sizingOptions = []
        panel.contentView = hosting
        state.chatPanel = panel
        // Not ordered in until first expand.
    }

    func windowDidBecomeKey(_ notification: Notification) {
        AppState.shared.panelIsKey = true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Keep the in-progress conversation across restarts.
        AppState.shared.session.archiveCurrentIfNeeded()
        Telemetry.flushBeforeQuit()
    }

    // Losing key status alone no longer collapses the panel (the outside-click
    // monitors decide that) — it only drops the input focus state.
    func windowDidResignKey(_ notification: Notification) {
        AppState.shared.panelIsKey = false
    }

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let state = AppState.shared
            // A pending approval captures Return (allow) and Escape (deny).
            if state.expanded, state.session.pendingPermission != nil {
                if event.keyCode == 36 { // Return
                    state.session.respondPermission(.allow)
                    return nil
                }
                if event.keyCode == 53 { // Escape
                    state.session.respondPermission(.deny)
                    return nil
                }
            }
            if event.keyCode == 53, state.expanded { // Escape
                state.collapse()
                return nil
            }
            if event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers {
                if chars == "q" {
                    NSApp.terminate(nil)
                    return nil
                }
                if chars == "w", state.expanded {
                    state.collapse()
                    return nil
                }
            }
            return event
        }
    }

    // Carbon hotkey: works globally without accessibility permission.
    private func installHotKey(state: AppState) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard result == noErr else { return noErr }
            DispatchQueue.main.async {
                switch hotKeyID.id {
                case HotKeyID.toggle:
                    AppState.shared.toggle()
                case HotKeyID.screenshot:
                    AppDelegate.handleScreenshotHotKey()
                default:
                    break
                }
            }
            return noErr
        }, 1, &eventType, nil, &hotKeyHandlerRef)

        state.installShortcutRegistrationHandler { [unowned self] kind, shortcut in
            replaceHotKey(kind: kind, shortcut: shortcut)
        }
    }

    /// Registers the new shortcut before releasing the old one, so a conflict
    /// can never leave the user without their previously working shortcut.
    private func replaceHotKey(kind: GlobalShortcut.Kind, shortcut: GlobalShortcut) -> String? {
        let hotKeyIDValue: UInt32
        var oldRef: EventHotKeyRef?
        switch kind {
        case .toggle:
            hotKeyIDValue = HotKeyID.toggle
            oldRef = toggleHotKeyRef
        case .screenshot:
            hotKeyIDValue = HotKeyID.screenshot
            oldRef = screenshotHotKeyRef
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x45415645), id: hotKeyIDValue) // 'EAVE'
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &replacement
        )
        guard status == noErr, let replacement else {
            NSLog("Eave: failed to register \(kind) shortcut \(shortcut.displayName), status=\(status)")
            if status == eventHotKeyExistsErr {
                return "\(shortcut.displayName) is already used by macOS or another app."
            }
            return "\(shortcut.displayName) could not be registered (error \(status))."
        }
        if let oldRef { UnregisterEventHotKey(oldRef) }
        switch kind {
        case .toggle: toggleHotKeyRef = replacement
        case .screenshot: screenshotHotKeyRef = replacement
        }
        NSLog("Eave: registered \(kind) shortcut \(shortcut.displayName)")
        return nil
    }

    private static func handleScreenshotHotKey() {
        let state = AppState.shared
        guard !state.session.isRunning else { return }
        // Screenshot turns are meant to be invisible: switch to stealth notch
        // and a clear glass panel before the capture.
        state.notchStyle = .stealth
        state.panelStyle = .clear
        let prompt = """
            First, determine whether the image shows a multiple-choice question with up to four answer choices. \
            If it does, identify the correct choice(s). The choices are ordered from first to fourth. \
            If they are already labeled with letters or numbers, use those labels. \
            Otherwise, count from the top: the first choice is A (or 1), the second is B (or 2), \
            the third is C (or 3), and the fourth is D (or 4). \
            Reply with ONLY the letter or number of each correct choice, separated by commas. \
            If only one choice is correct, reply with only that single letter or number. \
            If the image is NOT a multiple-choice question, respond normally to what is shown.
            """
        ScreenshotCapture.capture(.fullScreen, state: state, prompt: prompt)
    }
}
