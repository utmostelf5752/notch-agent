import AppKit
import SwiftUI
import Combine

// SkyLight SPI: Gaussian-blurs whatever is behind a window's translucent
// pixels. Every NSVisualEffectView material is far too frosted for a clear
// pane — this is the only way to get a genuine ~3pt glass blur. Fully
// transparent pixels (the window margins) stay unblurred.
private typealias CGSConnectionID = UInt32
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID
@discardableResult
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(
    _ cid: CGSConnectionID, _ wid: UInt32, _ radius: Int32
) -> Int32

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

    // How the notch narrates background activity.
    //   standard — live text, tokens, and buttons around the notch.
    //   compact  — every state is the same hairline sliver under the notch,
    //              colored by what's happening; done sweeps 3 times and stops.
    //   stealth  — silent while working; a permission/question announces
    //              itself with a brief 2-sweep dark sliver and then hides;
    //              the panel becomes a near-black overlay at the notch's
    //              width.
    enum NotchStyle: String, CaseIterable { case standard, compact, stealth }

    @Published var notchStyle: NotchStyle {
        didSet {
            UserDefaults.standard.set(notchStyle.rawValue, forKey: "notchStyle")
            stealthComposerOpen = true
            syncNotchFrame(animated: true)
            applyPanelBlur()
            if expanded { chatPanel?.setFrame(expandedFrame, display: true) }
        }
    }

    var stealthMode: Bool { notchStyle == .stealth }

    // What the expanded panel is made of.
    //   black — solid, the original look.
    //   smoke — dark frosted glass: an NSVisualEffectView diffuses what's
    //           behind the window under a smoked tint.
    //   clear — a genuinely clear pane: the faint CGS blur and near-no tint.
    // Smoke uses NSVisualEffectView rather than the CGS blur because the CGS
    // radius applies to the window's whole rectangle and lags reveal/resize
    // animations. Stealth honors only the clear pane (drawn without its rim
    // there); smoke falls back to the near-black overlay in stealth.
    enum PanelStyle: String, CaseIterable { case black, smoke, clear }

    @Published var panelStyle: PanelStyle {
        didSet {
            UserDefaults.standard.set(panelStyle.rawValue, forKey: "panelStyle")
            applyPanelBlur()
        }
    }

    func applyPanelBlur() {
        guard let panel = chatPanel, panel.windowNumber > 0 else { return }
        let radius: Int32 = panelStyle == .clear ? 3 : 0
        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), UInt32(panel.windowNumber), radius)
    }

    // The eye button toggles stealth without forgetting whether the user was
    // on standard or compact before.
    private var styleBeforeStealth: NotchStyle = .standard
    func toggleStealth() {
        if stealthMode {
            notchStyle = styleBeforeStealth
        } else {
            styleBeforeStealth = notchStyle
            notchStyle = .stealth
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
    // The panel was open when Settings opened, so reopen it once Settings closes.
    private var reopenPanelAfterSettings = false

    var suspendCollapse = false
    var lastExpandAt = Date.distantPast

    // Push-to-close: while the panel is open, shoving the cursor into the top
    // edge between the flanking icons closes it. Armed only once the cursor has
    // left the zone since opening, so a hover-expand (which leaves the cursor
    // right there) doesn't immediately close again.
    var topCloseArmed = false

    // Edge-drag resize state: (mouse position, panel size) at drag start.
    // Screen coordinates, so the math stays stable while the window resizes.
    var resizeStart: (mouse: NSPoint, size: NSSize)?

    // User-chosen panel size, persisted. nil = defaults.
    @Published var panelWidthOverride: CGFloat?
    @Published var panelHeightOverride: CGFloat?

    private var notchWatchTimer: Timer?

    // Display the notch/panel are currently anchored to. Updated when screens
    // rearrange or the cursor moves onto a different notched display.
    private var anchoredDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

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

    // Stealth announces a pending permission/question with a sliver that
    // sweeps exactly twice (1s per sweep) and then hides again — the notch
    // returns to stock size until the alert is answered.
    @Published var stealthAlertSliverVisible = false
    var stealthAlertStartedAt = Date()
    private var stealthAlertTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "notchStyle"), let style = NotchStyle(rawValue: raw) {
            notchStyle = style
        } else {
            // Migrate the earlier boolean stealth preference.
            notchStyle = defaults.bool(forKey: "stealthMode") ? .stealth : .standard
        }
        if let raw = defaults.string(forKey: "panelStyle"), let style = PanelStyle(rawValue: raw) {
            panelStyle = style
        } else if defaults.string(forKey: "panelStyle") == "frost" {
            // Frost was removed; smoke is the closest survivor.
            panelStyle = .smoke
        } else {
            // Migrate the earlier boolean glass preference.
            panelStyle = defaults.bool(forKey: "glassPanel") ? .clear : .black
        }
        let w = defaults.double(forKey: "panelWidth")
        if w > 0 { panelWidthOverride = CGFloat(w) }
        let h = defaults.double(forKey: "panelHeight")
        if h > 0 { panelHeightOverride = CGFloat(h) }
    }

    // Window margins around the panel content so the drop shadow (if any)
    // and popovers have room inside the borderless window.
    static let panelMargin: CGFloat = 14
    static let panelBottomMargin: CGFloat = 30

    private var screen: NSScreen { resolveScreen() }

    var hasNotch: Bool { screen.safeAreaInsets.top > 0 }

    // Prefer a notched screen under the cursor, then the previously anchored
    // notched screen (if it still exists), then any notched screen, then the
    // screen under the cursor / main. External-only setups get a fake tab.
    private func resolveScreen() -> NSScreen {
        let screens = NSScreen.screens
        precondition(!screens.isEmpty, "NSScreen.screens is empty")
        let mouse = NSEvent.mouseLocation
        let notched = screens.filter { $0.safeAreaInsets.top > 0 }

        if let hit = notched.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        if let id = anchoredDisplayID,
           let kept = notched.first(where: { $0.displayID == id }) {
            return kept
        }
        if let first = notched.first { return first }
        return screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? screens[0]
    }

    // Reposition when displays are added/removed/rearranged, and when the
    // cursor moves onto a different notched screen.
    func installScreenObservers() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.repositionForActiveScreen(force: true)
            }
        }
        repositionForActiveScreen(force: true)
    }

    private func repositionForActiveScreen(force: Bool) {
        let next = resolveScreen()
        let nextID = next.displayID
        guard force || anchoredDisplayID != nextID else { return }
        anchoredDisplayID = nextID

        // Clamp a persisted size that no longer fits the new display.
        if let w = panelWidthOverride {
            panelWidthOverride = min(max(w, minPanelWidth), maxPanelWidth)
        }
        if let h = panelHeightOverride {
            panelHeightOverride = min(max(h, minPanelHeight), maxPanelHeight)
        }

        syncNotchFrame(animated: false)
        if expanded {
            chatPanel?.setFrame(expandedFrame, display: true)
            applyPanelBlur()
        }
        NSLog("NotchAgent: repositioned for display \(nextID) frame=\(NSStringFromRect(next.frame))")
    }

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

    // Outward flare at the notch's top corners for the standard and compact
    // looks. Stealth stays stock-shaped — its whole point is to be
    // indistinguishable from the bare notch.
    var notchTopRadius: CGFloat { notchStyle == .stealth ? 0 : 10 }

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

    // The open panel's top-edge close target: the camera-cutout-width gap along
    // the top strip, between the left (history/settings) and right (pin/new)
    // icon clusters. Only the last couple of pixels before the screen edge —
    // the cursor must be shoved all the way to the top, so merely sitting
    // inside the notch doesn't close the panel. Extended above the screen top
    // by activationTopOvershoot so the pinned top row (y == maxY) counts as
    // inside — same reason as activationFrame's overshoot.
    var topCloseZone: NSRect {
        guard let frame = chatPanel?.frame else { return .zero }
        let width = notchWidth
        let edgeDepth: CGFloat = 2
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.maxY - edgeDepth,
            width: width,
            height: edgeDepth + activationTopOvershoot
        )
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
        var size = rawNotchContentSize
        // Room for the outward top-corner flares on either side of the body.
        size.width += notchTopRadius * 2
        return size
    }

    private var rawNotchContentSize: NSSize {
        let base = notchSize
        // Stealth: never grow sideways, and working is fully silent (stock
        // notch). Alerts extend 3pt below the cutout only while their
        // 2-sweep announcement is on screen; completion holds its sliver.
        if stealthMode {
            switch notchMode {
            case .idle, .working:
                return base
            case .permission, .question:
                return stealthAlertSliverVisible
                    ? NSSize(width: base.width, height: base.height + 3)
                    : base
            case .completed:
                return NSSize(width: base.width, height: base.height + 3)
            }
        }
        // Compact: every background state is a sliver, so the notch only ever
        // grows the 3pt the hairline needs.
        if notchStyle == .compact, notchMode != .idle {
            return NSSize(width: base.width, height: base.height + 3)
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
        // Alerts also drive the stealth announcement sliver's lifecycle.
        let alertResync: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateStealthAlertSliver()
                self.syncNotchFrame(animated: true)
                self.updateClockTimer()
            }
        }
        session.$pendingPermission.dropFirst().sink { _ in alertResync() }.store(in: &cancellables)
        session.$pendingQuestion.dropFirst().sink { _ in alertResync() }.store(in: &cancellables)
        session.$provider.dropFirst().sink { _ in resync() }.store(in: &cancellables)
        $expanded.dropFirst().sink { _ in resync() }.store(in: &cancellables)
    }

    // Restarts the 2-sweep announcement whenever a new alert lands (a new
    // question in a multi-question request re-announces too), and clears it
    // the moment the alert is answered.
    private func updateStealthAlertSliver() {
        let active = session.pendingPermission != nil || session.pendingQuestion != nil
        stealthAlertTimer?.invalidate()
        stealthAlertTimer = nil
        guard active else {
            stealthAlertSliverVisible = false
            return
        }
        stealthAlertStartedAt = Date()
        stealthAlertSliverVisible = true
        stealthAlertTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.stealthAlertSliverVisible = false
            self?.syncNotchFrame(animated: true)
        }
    }

    private func handleRunningChanged() {
        if session.isRunning {
            // A new turn cancels any lingering completed pill.
            showingCompleted = false
            completedTimer?.invalidate()
            completedTimer = nil
        } else if !expanded, session.messages.last?.role == .assistant {
            // A real answer landed while collapsed: show the pill, then let it
            // dismiss itself. Stealth's 2-sweep announcement takes 2s, so the
            // mode ends exactly when the sweeps do.
            showingCompleted = true
            completedStartedAt = Date()
            completedTimer?.invalidate()
            completedTimer = Timer.scheduledTimer(withTimeInterval: stealthMode ? 2 : completedDuration, repeats: false) { [weak self] _ in
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
        // Only standard shows an elapsed-time label that needs the tick.
        let ticking = notchMode == .working && notchStyle == .standard
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
            applyPanelBlur()
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
            // Reopen the notch panel when Settings closes, if it was open.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self] _ in
                guard let self, self.reopenPanelAfterSettings else { return }
                self.reopenPanelAfterSettings = false
                self.expand(takeKeyboard: true)
            }
            settingsWindow = win
        }
        // The panel sits at .statusBar level, above the settings window, so
        // collapse it while Settings is up and restore it on close.
        reopenPanelAfterSettings = expanded
        if expanded { collapse() }
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
            let mouse = NSEvent.mouseLocation

            // Follow the cursor onto another notched display (or recover after
            // a screen arrangement change the notification missed).
            self.repositionForActiveScreen(force: false)

            // While open: pushing into the top-edge gap between the icons closes
            // the panel. Only after the cursor has left that zone at least once
            // since opening (topCloseArmed) — otherwise a hover-expand, which
            // leaves the cursor sitting in the zone, would slam it shut again.
            if self.expanded {
                if self.topCloseZone.contains(mouse) {
                    if self.topCloseArmed, !self.pinned, !self.suspendCollapse {
                        // Mark as hovering so the collapse doesn't instantly
                        // hover-expand: the transition guard below only fires on
                        // a fresh outside->inside move.
                        self.notchHovering = true
                        self.collapse()
                    }
                } else {
                    self.topCloseArmed = true
                }
                return
            }
            self.topCloseArmed = false

            let inside = self.activationFrame.contains(mouse)
            guard inside != self.notchHovering else { return }
            self.notchHovering = inside
            guard inside else { return }
            // Short dwell so flybys toward the menu bar don't open it. Idle and
            // working states hover-expand; permission / question states keep
            // hover disabled so it cannot steal a click aimed at the notch's
            // own buttons. Stealth has no notch buttons, so it hover-expands in
            // every state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if self.notchHovering && !self.expanded
                    && (self.notchMode == .idle || self.notchMode == .working || self.stealthMode) {
                    NSLog("NotchAgent: hover-expanding")
                    self.expand(takeKeyboard: false)
                }
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}
