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
    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem?
    private var runningObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Our windows must never participate in window tabbing; also silences
        // "Cannot index window tabs due to missing main bundle identifier".
        NSWindow.allowsAutomaticWindowTabbing = false
        let state = AppState.shared
        setUpTargetWindow(state: state)
        setUpChatPanel(state: state)
        setUpStatusItem(state: state)
        setUpMainMenu()
        installHotKey()
        installKeyMonitor()
        installSignalTriggers()
        state.startNotchWatch()
        state.installOutsideClickMonitors()
        state.startBackgroundObservers()
        state.logGeometry()
    }

    // An accessory app has no menu bar, but key equivalents still route
    // through NSApp.mainMenu — without this Edit menu, Cmd+A/C/V/X/Z are dead.
    private func setUpMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit NotchAgent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
    // executes commands from /tmp/notchagent-cmd (one per line):
    //   provider:<claude|codex|chatgpt>   switch provider
    //   send:<text>                       send a message
    //   msgs                              write transcript to /tmp/notchagent-msgs.txt
    //   dump                              write ChatGPT web view state to /tmp/notchagent-dom.txt
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
        let path = "/tmp/notchagent-cmd"
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
                try? out.write(toFile: "/tmp/notchagent-msgs.txt", atomically: true, encoding: .utf8)
            } else if cmd == "dump" {
                ChatGPTWeb.shared.dumpState(to: "/tmp/notchagent-dom.txt")
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
                try? out.write(toFile: "/tmp/notchagent-geom.txt", atomically: true, encoding: .utf8)
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
            } else if cmd == "collapse" {
                AppState.shared.collapse()
            } else if cmd == "expand" {
                AppState.shared.expand(takeKeyboard: false)
            } else if cmd.hasPrefix("stealth:") {
                AppState.shared.stealthMode = cmd.dropFirst(8) == "on"
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
                try? out.write(toFile: "/tmp/notchagent-state.txt", atomically: true, encoding: .utf8)
            }
        }
    }

    private func setUpStatusItem(state: AppState) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusImage(running: false)

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let hint = NSMenuItem(title: "Hover the notch or press ⌥Space", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit NotchAgent", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        runningObserver = state.session.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.statusItem?.button?.image = Self.statusImage(running: running)
            }
    }

    private static func statusImage(running: Bool) -> NSImage? {
        let name = running ? "sparkles" : "sparkle"
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: running ? "NotchAgent (working)" : "NotchAgent"
        )
        image?.isTemplate = true
        return image
    }

    @objc private func togglePanel() {
        AppState.shared.toggle()
    }

    @objc private func openSettings() {
        AppState.shared.openSettings()
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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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
    private func installHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppState.shared.toggle() }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4E474E54), id: 1) // 'NGNT'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
