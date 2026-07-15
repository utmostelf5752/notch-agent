import AppKit
import SwiftUI
import Combine

// Main-thread only. Not @MainActor-annotated so it can be reached from the
// Carbon hotkey callback via DispatchQueue.main without strict-concurrency friction.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var expanded = false
    @Published var notchHovering = false
    @Published var panelIsKey = false
    @Published var pinned = false
    @Published var dropTargeted = false
    // Step groups (collapsed tool activity) the user has expanded.
    @Published var expandedGroups: Set<UUID> = []
    // Popovers are child windows; while one is up the panel resigns key,
    // which must not trigger the click-outside auto-collapse.
    @Published var showSettings = false { didSet { updatePopoverSuspend() } }
    @Published var showHistory = false { didSet { updatePopoverSuspend() } }

    // Stealth mode: the notch renders nothing while a turn runs, alerts and
    // completion compress to a hairline sliver, and the panel becomes a
    // near-black overlay locked to the notch's width. Persisted.
    @Published var stealthMode: Bool {
        didSet {
            UserDefaults.standard.set(stealthMode, forKey: "stealthMode")
            stealthComposerOpen = true
            syncNotchFrame(animated: true)
            if expanded { chatPanel?.setFrame(expandedFrame, display: true) }
        }
    }
    // In stealth the composer is hidden so a short panel stays readable;
    // clicking the history area pulls it up / puts it away.
    @Published var stealthComposerOpen = true

    let session = AgentSession()

    private func updatePopoverSuspend() {
        suspendCollapse = showSettings || showHistory
    }

    // Strong references: the chat panel is not ordered in until first expand,
    // and an un-ordered NSWindow held only weakly gets deallocated.
    var chatPanel: NSPanel?
    var targetWindow: NSWindow?
    var settingsWindow: NSWindow?

    var suspendCollapse = false
    var lastExpandAt = Date.distantPast

    // Edge-drag resize state: (mouse position, panel size) at drag start.
    // Screen coordinates, so the math stays stable while the window resizes.
    var resizeStart: (mouse: NSPoint, size: NSSize)?

    // User-chosen panel size, persisted. nil = defaults.
    @Published var panelWidthOverride: CGFloat?
    @Published var panelHeightOverride: CGFloat?

    private var notchWatchTimer: Timer?

    // Background mode: while the panel is collapsed and a turn is in flight
    // (or waiting on the user), the notch itself grows to show status. The
    // clock ticks the elapsed-time label; the subscriptions resize the target
    // window as the session's state changes.
    @Published var clockTick = Date()
    private var clockTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    // A brief "Done" pill shown after a turn finishes while collapsed, then it
    // dismisses itself. completedStartedAt anchors the draining progress bar.
    @Published var showingCompleted = false
    var completedStartedAt = Date()
    let completedDuration: TimeInterval = 3
    private var completedTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        stealthMode = defaults.bool(forKey: "stealthMode")
        let w = defaults.double(forKey: "panelWidth")
        if w > 0 { panelWidthOverride = CGFloat(w) }
        let h = defaults.double(forKey: "panelHeight")
        if h > 0 { panelHeightOverride = CGFloat(h) }
    }

    // Window margins around the panel content so the drop shadow (if any)
    // and popovers have room inside the borderless window.
    static let panelMargin: CGFloat = 14
    static let panelBottomMargin: CGFloat = 30

    private var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    var hasNotch: Bool { screen.safeAreaInsets.top > 0 }

    private var notchSize: NSSize {
        let s = screen
        if s.safeAreaInsets.top > 0 {
            let left = s.auxiliaryTopLeftArea?.width ?? 0
            let right = s.auxiliaryTopRightArea?.width ?? 0
            return NSSize(width: s.frame.width - left - right, height: s.safeAreaInsets.top)
        }
        // No notch (external display): draw a small fake notch tab as the target.
        return NSSize(width: 220, height: 30)
    }

    var notchHeight: CGFloat { notchSize.height }
    var notchWidth: CGFloat { notchSize.width }

    var collapsedFrame: NSRect { frame(for: notchSize) }

    // Hover activation range: hovering anywhere inside this rect (while idle)
    // hover-expands the panel. It's the current notch window frame, widened
    // horizontally by `activationInset` so the edges are easy to hit, and
    // extended above the screen top by `activationTopOvershoot`. The overshoot
    // matters: when you fling the cursor to the very top the pointer pins to
    // the screen's top row (y == maxY), and NSRect.contains treats the top edge
    // as outside — so without headroom above maxY, that top row never triggers.
    var activationInset: CGFloat = 4
    var activationTopOvershoot: CGFloat = 8
    func activationFrame(for notch: NSRect) -> NSRect {
        let base = notch.insetBy(dx: -activationInset, dy: 0)
        return NSRect(x: base.minX, y: base.minY,
                      width: base.width, height: base.height + activationTopOvershoot)
    }
    var activationFrame: NSRect {
        activationFrame(for: targetWindow?.frame ?? collapsedFrame)
    }

    // MARK: - Background mode (the notch grows while collapsed)

    // Which shape the always-on notch window should take right now. When the
    // panel is expanded it stays idle (the panel covers the notch anyway).
    enum NotchMode: Equatable { case idle, working, permission, question, completed }

    var notchMode: NotchMode {
        if expanded { return .idle }
        if session.pendingPermission != nil { return .permission }
        if session.pendingQuestion != nil { return .question }
        if session.isRunning { return .working }
        if showingCompleted { return .completed }
        return .idle
    }

    // Content size per mode. Working grows sideways into the menu-bar wings;
    // permission/question grow downward into a band below the camera. ChatGPT
    // gets a narrower working strip — it can only chat, so it earns less room
    // and its activity text is allowed to clip.
    private var notchContentSize: NSSize {
        let base = notchSize
        // Stealth: never grow sideways. Working is fully silent (stock notch);
        // alerts and completion only extend 3pt below the cutout so the
        // hairline sliver has visible pixels to land on.
        if stealthMode {
            switch notchMode {
            case .idle, .working:
                return base
            case .permission, .question, .completed:
                return NSSize(width: base.width, height: base.height + 3)
            }
        }
        switch notchMode {
        case .idle:
            return base
        case .working:
            let extra: CGFloat = session.provider == .chatgpt ? 170 : 300
            return NSSize(width: min(base.width + extra, maxPanelWidth), height: base.height + 1)
        case .permission:
            return NSSize(width: min(base.width + 220, maxPanelWidth), height: base.height + 66)
        case .question:
            return NSSize(width: min(base.width + 190, maxPanelWidth), height: base.height + 56)
        case .completed:
            return NSSize(width: min(base.width + 200, maxPanelWidth), height: base.height + 4)
        }
    }

    var notchTargetFrame: NSRect { frame(for: notchContentSize) }

    // Called once at launch after the target window exists. Any change to the
    // session state that affects the notch shape re-syncs the window frame;
    // async so the @Published value has settled before we read notchMode.
    func startBackgroundObservers() {
        let resync: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncNotchFrame(animated: true)
                self.updateClockTimer()
            }
        }
        // isRunning also drives the transient "Done" pill, so it gets its own
        // handler rather than the plain resync.
        session.$isRunning.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.handleRunningChanged() }
        }.store(in: &cancellables)
        session.$pendingPermission.dropFirst().sink { _ in resync() }.store(in: &cancellables)
        session.$pendingQuestion.dropFirst().sink { _ in resync() }.store(in: &cancellables)
        session.$provider.dropFirst().sink { _ in resync() }.store(in: &cancellables)
        $expanded.dropFirst().sink { _ in resync() }.store(in: &cancellables)
    }

    private func handleRunningChanged() {
        if session.isRunning {
            // A new turn cancels any lingering completed pill.
            showingCompleted = false
            completedTimer?.invalidate()
            completedTimer = nil
        } else if !expanded, session.messages.last?.role == .assistant {
            // A real answer landed while collapsed: show the pill, then let it
            // dismiss itself. Stealth holds its sliver a little longer since
            // it's the only completion signal there is.
            showingCompleted = true
            completedStartedAt = Date()
            completedTimer?.invalidate()
            completedTimer = Timer.scheduledTimer(withTimeInterval: stealthMode ? 5 : completedDuration, repeats: false) { [weak self] _ in
                self?.showingCompleted = false
                self?.syncNotchFrame(animated: true)
            }
        }
        syncNotchFrame(animated: true)
        updateClockTimer()
    }

    private func syncNotchFrame(animated: Bool) {
        guard let window = targetWindow else { return }
        let frame = notchTargetFrame
        guard frame != window.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func updateClockTimer() {
        // Stealth shows no elapsed-time label, so nothing needs the tick.
        let ticking = notchMode == .working && !stealthMode
        if ticking, clockTimer == nil {
            clockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.clockTick = Date()
            }
        } else if !ticking {
            clockTimer?.invalidate()
            clockTimer = nil
        }
    }

    // Resize limits: minimum width is the original default width; height has
    // no practical floor — the panel can shrink to barely more than the notch
    // row, with the history scrolling inside whatever room is left.
    var minPanelWidth: CGFloat { max(notchSize.width + 120, 300) }
    var minPanelHeight: CGFloat { notchHeight + 6 }
    var maxPanelWidth: CGFloat { screen.frame.width - 80 }
    var maxPanelHeight: CGFloat { screen.frame.height * 0.85 }

    var panelWidth: CGFloat {
        // Stealth locks the panel to the notch's width so it reads as the
        // notch being taller, not as a floating app.
        if stealthMode { return notchWidth }
        return min(max(panelWidthOverride ?? minPanelWidth, minPanelWidth), maxPanelWidth)
    }
    var panelHeight: CGFloat {
        min(max(panelHeightOverride ?? 280, minPanelHeight), maxPanelHeight)
    }

    var expandedFrame: NSRect {
        frame(for: NSSize(
            width: panelWidth + Self.panelMargin * 2,
            height: panelHeight + Self.panelBottomMargin
        ))
    }

    // Live-apply during an edge drag. Width changes are symmetric because the
    // frame stays centered on the notch; height grows downward because the
    // frame is anchored to the top of the screen.
    func applyPanelResize(width: CGFloat? = nil, height: CGFloat? = nil) {
        if let width { panelWidthOverride = min(max(width, minPanelWidth), maxPanelWidth) }
        if let height { panelHeightOverride = min(max(height, minPanelHeight), maxPanelHeight) }
        chatPanel?.setFrame(expandedFrame, display: true)
    }

    func persistPanelSize() {
        let defaults = UserDefaults.standard
        if let w = panelWidthOverride { defaults.set(Double(w), forKey: "panelWidth") }
        if let h = panelHeightOverride { defaults.set(Double(h), forKey: "panelHeight") }
    }

    private func frame(for size: NSSize) -> NSRect {
        let sf = screen.frame
        return NSRect(
            x: (sf.midX - size.width / 2).rounded(),
            y: sf.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    // Strict toggle: Option+Space always opens or closes, regardless of
    // keyboard focus or pin state.
    func toggle() {
        expanded ? collapse() : expand(takeKeyboard: true)
    }

    // takeKeyboard=false is the hover path: the panel shows but keyboard stays
    // with the app the user was typing in. Clicking the panel makes it key.
    // The panel stays open until Esc / hotkey / click-outside (see
    // installOutsideClickMonitors) — moving the mouse away does NOT close it.
    func expand(takeKeyboard: Bool = true) {
        guard let panel = chatPanel else {
            NSLog("NotchAgent: expand() called but chatPanel is nil")
            return
        }
        if !expanded {
            panel.setFrame(expandedFrame, display: false)
            expanded = true
            lastExpandAt = Date()
            panel.orderFrontRegardless()
            NSLog("NotchAgent: expand(takeKeyboard=\(takeKeyboard)) frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)")
        }
        if takeKeyboard {
            panel.makeKeyAndOrderFront(nil)
            // Opening with typing intent pulls the stealth composer up.
            if stealthMode { stealthComposerOpen = true }
        }
    }

    func collapse() {
        guard expanded else { return }
        NSLog("NotchAgent: collapse()")
        showSettings = false
        showHistory = false
        expanded = false
        // Let the SwiftUI reveal wipe play out, then release the window so
        // keyboard focus returns to whatever app was active before.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.expanded else { return }
            self.chatPanel?.orderOut(nil)
        }
    }

    // Opens (or focuses) the Settings window. Lazily built and reused. The app
    // is an accessory, so activate it too or the window opens unfocused behind
    // whatever the user was in.
    func openSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "NotchAgent Settings"
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView(state: self))
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Clicking anywhere that is not one of our windows collapses the panel
    // (unless pinned). Global monitors cover clicks in other apps; the local
    // monitor covers clicks on our own windows. Neither needs accessibility
    // permission for mouse events.
    func installOutsideClickMonitors() {
        let check: () -> Void = { [weak self] in
            guard let self, self.expanded, !self.pinned, !self.suspendCollapse else { return }
            // Absorb the click that opened the panel.
            guard Date().timeIntervalSince(self.lastExpandAt) > 0.3 else { return }
            let location = NSEvent.mouseLocation
            let insideOurs = NSApp.windows.contains { window in
                window.isVisible
                    && window !== self.targetWindow
                    && window.frame.insetBy(dx: -4, dy: -4).contains(location)
            }
            if !insideOurs { self.collapse() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            DispatchQueue.main.async(execute: check)
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            DispatchQueue.main.async(execute: check)
            return event
        }
    }

    func logGeometry() {
        for (i, s) in NSScreen.screens.enumerated() {
            NSLog("NotchAgent: screen[\(i)] frame=\(NSStringFromRect(s.frame)) safeTop=\(s.safeAreaInsets.top) isMain=\(s == NSScreen.main)")
        }
        NSLog("NotchAgent: hasNotch=\(hasNotch) collapsedFrame=\(NSStringFromRect(collapsedFrame)) expandedFrame=\(NSStringFromRect(expandedFrame))")
        NSLog("NotchAgent: targetWindow visible=\(targetWindow?.isVisible ?? false) frame=\(NSStringFromRect(targetWindow?.frame ?? .zero))")
    }

    // SwiftUI's onHover relies on a tracking area that is unreliable on a
    // window that can never become key, so the notch hover trigger is a
    // plain mouse-position poll instead.
    func startNotchWatch() {
        notchWatchTimer?.invalidate()
        notchWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.targetWindow != nil else { return }
            let inside = self.activationFrame.contains(NSEvent.mouseLocation)
            guard inside != self.notchHovering else { return }
            self.notchHovering = inside
            guard inside else { return }
            // Short dwell so flybys toward the menu bar don't open it. Only the
            // idle notch hover-expands; in a background state (working alert /
            // permission / question) hovering must not steal the click aimed at
            // the notch's own buttons.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if self.notchHovering && !self.expanded && self.notchMode == .idle {
                    NSLog("NotchAgent: hover-expanding")
                    self.expand(takeKeyboard: false)
                }
            }
        }
    }
}
