import AppKit
import SwiftUI

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
    let session = AgentSession()

    private func updatePopoverSuspend() {
        suspendCollapse = showSettings || showHistory
    }

    // Strong references: the chat panel is not ordered in until first expand,
    // and an un-ordered NSWindow held only weakly gets deallocated.
    var chatPanel: NSPanel?
    var targetWindow: NSWindow?

    var suspendCollapse = false
    var lastExpandAt = Date.distantPast

    // Edge-drag resize state: (mouse position, panel size) at drag start.
    // Screen coordinates, so the math stays stable while the window resizes.
    var resizeStart: (mouse: NSPoint, size: NSSize)?

    // User-chosen panel size, persisted. nil = defaults.
    @Published var panelWidthOverride: CGFloat?
    @Published var panelHeightOverride: CGFloat?

    private var notchWatchTimer: Timer?

    private init() {
        let defaults = UserDefaults.standard
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

    var collapsedFrame: NSRect { frame(for: notchSize) }

    // Resize limits: minimum width is the original default width; minimum
    // height is half the original default height.
    var minPanelWidth: CGFloat { max(notchSize.width + 120, 300) }
    var minPanelHeight: CGFloat { 140 }
    var maxPanelWidth: CGFloat { screen.frame.width - 80 }
    var maxPanelHeight: CGFloat { screen.frame.height * 0.85 }

    var panelWidth: CGFloat {
        min(max(panelWidthOverride ?? minPanelWidth, minPanelWidth), maxPanelWidth)
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
            guard let self, let target = self.targetWindow else { return }
            let inside = target.frame.insetBy(dx: -4, dy: 0).contains(NSEvent.mouseLocation)
            guard inside != self.notchHovering else { return }
            self.notchHovering = inside
            guard inside else { return }
            // Short dwell so flybys toward the menu bar don't open it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if self.notchHovering && !self.expanded {
                    NSLog("NotchAgent: hover-expanding")
                    self.expand(takeKeyboard: false)
                }
            }
        }
    }
}
