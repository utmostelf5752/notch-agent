import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import IOKit
import IOKit.hid

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

// MARK: - Experimental CoreGraphics/SkyLight hardening

// Private SkyLight SPI used in the experimental branch to make capture harder.
// These may break on future macOS versions, so they are gated behind a setting.
@discardableResult
@_silgen_name("CGSSetWindowSharingState")
private func CGSSetWindowSharingState(
    _ cid: CGSConnectionID, _ wid: UInt32, _ state: Int32
) -> Int32

@discardableResult
@_silgen_name("CGSSetWindowTags")
private func CGSSetWindowTags(
    _ cid: CGSConnectionID, _ wid: UInt32, _ tags: UnsafePointer<UInt32>, _ maxTagSize: Int
) -> Int32

@discardableResult
@_silgen_name("CGSClearWindowTags")
private func CGSClearWindowTags(
    _ cid: CGSConnectionID, _ wid: UInt32, _ tags: UnsafePointer<UInt32>, _ maxTagSize: Int
) -> Int32

@_silgen_name("CGSIsScreenWatcherPresent")
private func CGSIsScreenWatcherPresent() -> Bool

private let kCGSAvoidsCaptureTagBit: UInt32 = 1 << 6

// Feedback style for response completion and multiple-choice answers.
enum FeedbackMode: String, CaseIterable, Identifiable {
    case haptic, capsLock

    var id: String { rawValue }
    var label: String {
        switch self {
        case .haptic: return "Haptic"
        case .capsLock: return "Caps Lock LED"
        }
    }
}

// Controls the Caps Lock LED by toggling the system modifier lock state.
// On modern macOS this is the only reliable way to drive the built-in
// keyboard LED; direct HID output element access is gated for sandboxed/user
// apps. Note: this briefly changes the actual Caps Lock modifier state, so
// it is only suitable as a transient feedback signal.
final class CapsLockLED {
    static let shared = CapsLockLED()

    private var connect: io_connect_t = 0
    var available: Bool { connect != 0 }

    private static let logPath = "/tmp/eave-led.log"
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        guard let matching = IOServiceMatching(kIOHIDSystemClass) else {
            log("no IOHIDSystem matching dictionary")
            return
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            log("no IOHIDSystem service")
            return
        }
        defer { IOObjectRelease(service) }
        let status = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        log("IOServiceOpen status=\(status) connect=\(connect)")
    }

    func setOn(_ on: Bool) {
        guard connect != 0 else {
            log("setOn skipped, no connection")
            return
        }
        let status = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
        log("setOn=\(on) status=\(status)")
    }

    // Blink the LED the given number of times. Each blink turns the LED on for
    // half the tap interval, then off for the remaining half, so individual
    // blinks are distinct.
    func blink(count: Int, tapInterval: TimeInterval = 0.20) {
        guard available, count > 0 else {
            log("blink unavailable or count=0")
            return
        }
        log("blink count=\(count) tapInterval=\(tapInterval)")
        let onDuration: TimeInterval = 0.15
        for i in 0..<count {
            let start = TimeInterval(i) * tapInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                self.setOn(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + start + onDuration) {
                self.setOn(false)
            }
        }
    }

    private func log(_ message: String) {
        let full = "Eave: CapsLockLED \(message)"
        NSLog(full)
        let line = "\(Self.dateFormatter.string(from: Date())) \(message)\n"
        if let data = line.data(using: .utf8) {
            let fileURL = URL(fileURLWithPath: Self.logPath)
            if FileManager.default.fileExists(atPath: Self.logPath) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

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
    @Published private(set) var toggleShortcut: GlobalShortcut
    @Published private(set) var shortcutRegistrationError: String?
    @Published private(set) var screenshotShortcut: GlobalShortcut
    @Published private(set) var screenshotShortcutRegistrationError: String?
    @Published var feedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(feedbackEnabled, forKey: "feedbackEnabled") }
    }
    @Published var feedbackMode: FeedbackMode {
        didSet { UserDefaults.standard.set(feedbackMode.rawValue, forKey: "feedbackMode") }
    }

    // Installed by AppDelegate after the Carbon event handler is ready. A nil
    // result means the replacement succeeded; a string keeps the existing
    // shortcut active and explains why the requested one was rejected.
    private var shortcutRegistrationHandler: ((GlobalShortcut.Kind, GlobalShortcut) -> String?)?

    // How the notch narrates background activity.
    //   standard — live text, tokens, and buttons around the notch.
    //   compact  — hairline sliver while working/alerting; Done expands into
    //              wings with elapsed time and a draining bottom bar.
    //   stealth  — silent while working; a permission/question announces
    //              itself with a brief 2-sweep dark sliver and then hides;
    //              the panel becomes a near-black overlay at the notch's
    //              width.
    enum NotchStyle: String, CaseIterable { case standard, compact, stealth }

    @Published var notchStyle: NotchStyle {
        didSet {
            if oldValue != notchStyle {
                Telemetry.record("setting_changed", ["key": "notchStyle", "value": notchStyle.rawValue])
            }
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
            if oldValue != panelStyle {
                Telemetry.record("setting_changed", ["key": "panelStyle", "value": panelStyle.rawValue])
            }
            UserDefaults.standard.set(panelStyle.rawValue, forKey: "panelStyle")
            applyPanelBlur()
        }
    }

    // Use the macOS window sharingType API so Eave's windows are excluded from
    // screen recordings and video calls when the user enables this.
    @Published var screenShareProtectionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenShareProtectionEnabled, forKey: "screenShareProtectionEnabled")
            applyScreenShareProtection()
        }
    }

    // When enabled, detect common meeting/screen-sharing apps and automatically
    // collapse the panel, close settings, and enter stealth. This is a heuristic
    // because macOS has no public API for "screen sharing is active".
    @Published var autoHideOnScreenShare: Bool {
        didSet {
            UserDefaults.standard.set(autoHideOnScreenShare, forKey: "autoHideOnScreenShare")
            if autoHideOnScreenShare {
                startScreenShareWatch()
            } else {
                stopScreenShareWatch()
            }
        }
    }

    // Experimental branch: use private SkyLight SPI to set the sharing state and
    // avoids-capture tag directly. May be ignored by ScreenCaptureKit on macOS 15+.
    @Published var coreGraphicsHardeningEnabled: Bool {
        didSet {
            guard oldValue != coreGraphicsHardeningEnabled else { return }
            UserDefaults.standard.set(coreGraphicsHardeningEnabled, forKey: "coreGraphicsHardeningEnabled")
            if coreGraphicsHardeningEnabled {
                applyCoreGraphicsHardening()
            } else {
                clearCoreGraphicsHardening()
            }
        }
    }

    // Registers a hook in ~/.cursor/hooks.json so Cursor's Propose Only mode
    // can ask before running anything. Reflects the file, not a preference:
    // the install is what makes it work, so the file is the source of truth.
    @Published var cursorApprovalsEnabled: Bool = CursorApprovals.isInstalled {
        didSet {
            guard oldValue != cursorApprovalsEnabled else { return }
            do {
                if cursorApprovalsEnabled {
                    try CursorApprovals.install()
                } else {
                    try CursorApprovals.uninstall()
                }
            } catch {
                cursorApprovalsFailure = error.localizedDescription
                cursorApprovalsEnabled = CursorApprovals.isInstalled
                return
            }
            cursorApprovalsFailure = nil
        }
    }

    @Published var cursorApprovalsFailure: String?

    func applyPanelBlur() {
        guard let panel = chatPanel, panel.windowNumber > 0 else { return }
        let radius: Int32 = panelStyle == .clear ? 3 : 0
        CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), UInt32(panel.windowNumber), radius)
    }

    func applyScreenShareProtection() {
        for window in NSApp.windows {
            applyScreenShareProtection(to: window)
        }
    }

    private func applyScreenShareProtection(to window: NSWindow) {
        window.sharingType = screenShareProtectionEnabled ? .none : .readOnly
        if coreGraphicsHardeningEnabled {
            applyCoreGraphicsHardening(to: window)
        }
    }

    // Experimental: call the private SkyLight sharing-state and window-tag APIs.
    func applyCoreGraphicsHardening() {
        for window in NSApp.windows {
            applyCoreGraphicsHardening(to: window)
        }
    }

    private func applyCoreGraphicsHardening(to window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        let cid = CGSDefaultConnectionForThread()
        let wid = UInt32(window.windowNumber)
        let sharingState: Int32 = screenShareProtectionEnabled ? 0 : 1
        CGSSetWindowSharingState(cid, wid, sharingState)
        var tags: [UInt32] = [kCGSAvoidsCaptureTagBit, 0]
        if screenShareProtectionEnabled {
            CGSSetWindowTags(cid, wid, &tags, MemoryLayout<UInt32>.size * 2)
        } else {
            CGSClearWindowTags(cid, wid, &tags, MemoryLayout<UInt32>.size * 2)
        }
    }

    // Called when the user turns aggressive CG hardening off. Reverses the
    // private SkyLight changes so the windows fall back to the public sharingType.
    private func clearCoreGraphicsHardening() {
        for window in NSApp.windows {
            clearCoreGraphicsHardening(to: window)
        }
    }

    private func clearCoreGraphicsHardening(to window: NSWindow) {
        guard window.windowNumber > 0 else { return }
        let cid = CGSDefaultConnectionForThread()
        let wid = UInt32(window.windowNumber)
        let sharingState: Int32 = screenShareProtectionEnabled ? 0 : 1
        CGSSetWindowSharingState(cid, wid, sharingState)
        var tags: [UInt32] = [kCGSAvoidsCaptureTagBit, 0]
        CGSClearWindowTags(cid, wid, &tags, MemoryLayout<UInt32>.size * 2)
    }

    // Keep Eave out of the Window menu and the Cmd+` window cycle. The app is
    // already an LSUIElement accessory, so it does not appear in Cmd+Tab.
    func applyWindowDiscretion() {
        for window in NSApp.windows {
            applyWindowDiscretion(to: window)
        }
    }

    private func applyWindowDiscretion(to window: NSWindow) {
        window.isExcludedFromWindowsMenu = true
        // The Settings window must never be .transient: a transient window
        // auto-hides whenever this accessory app is inactive, which is exactly
        // the "focus shifts but Settings never appears" bug. A become-visible
        // observer runs this on every window, so guard here too — not just at
        // creation — or it gets re-added each time Settings is shown.
        guard window !== settingsWindow else { return }
        var behavior = window.collectionBehavior
        behavior.insert(.transient)
        window.collectionBehavior = behavior
    }

    // MARK: - Screen-share auto-hide

    private var screenShareWatchTimer: Timer?
    private static let screenShareAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
        "com.hnc.Discord",
        "com.obsproject.obs-studio",
        "com.apple.QuickTimePlayerX",
    ]

    private func startScreenShareWatch() {
        screenShareWatchTimer?.invalidate()
        screenShareWatchTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkScreenShare()
        }
        checkScreenShare()
    }

    private func stopScreenShareWatch() {
        screenShareWatchTimer?.invalidate()
        screenShareWatchTimer = nil
    }

    private func checkScreenShare() {
        guard autoHideOnScreenShare else { return }
        let running = NSWorkspace.shared.runningApplications
        let heuristicDetected = running.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return Self.screenShareAppBundleIDs.contains(bundleID) && !app.isTerminated
        }
        let watcherDetected = coreGraphicsHardeningEnabled ? CGSIsScreenWatcherPresent() : false
        if heuristicDetected || watcherDetected {
            DispatchQueue.main.async { [weak self] in self?.enterSharingStealth() }
        }
    }

    private func enterSharingStealth() {
        guard autoHideOnScreenShare else { return }
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.close()
        }
        if expanded { collapse() }
        if !stealthMode { toggleStealth() }
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
    let completedDuration: TimeInterval = 5
    private var completedTimer: Timer?

    // Stealth announces a pending permission/question with a sliver that
    // sweeps exactly twice (1s per sweep) and then hides again — the notch
    // returns to stock size until the alert is answered.
    @Published var stealthAlertSliverVisible = false
    var stealthAlertStartedAt = Date()
    private var stealthAlertTimer: Timer?

    // Silent screenshot turn: the auto-send shortcut fires a turn without any
    // visible notch background activity, exactly like stealth mode.
    var silentTurn = false
    // Screenshot multiple-choice turn: the response is parsed for A/B/C/D or
    // 1/2/3/4 and the haptic fires that many times instead of once.
    var multipleChoiceTurn = false

    private init() {
        let defaults = UserDefaults.standard
        // A crash leaves the approval marker behind, which would make the hook
        // block every Cursor call until it times out. Nothing is in flight at
        // launch, so clear it.
        CursorApprovals.endSession()
        toggleShortcut = GlobalShortcut(defaults: defaults)
        // The original default was Cmd+Option+Space, which conflicts with
        // Finder's "Search with Spotlight" window. Move any saved copy of that
        // shortcut to the new Ctrl+Option+Space default once.
        let oldScreenshotDefault = GlobalShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | cmdKey),
            keyLabel: "Space"
        )
        var loadedScreenshotShortcut = GlobalShortcut(defaults: defaults, kind: .screenshot)
        if !defaults.bool(forKey: "eave.didMigrateScreenshotShortcutToCtrlOptSpace"),
           loadedScreenshotShortcut == oldScreenshotDefault {
            loadedScreenshotShortcut = GlobalShortcut(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey | optionKey),
                keyLabel: "Space"
            )
            loadedScreenshotShortcut.persist(to: defaults, kind: .screenshot)
            defaults.set(true, forKey: "eave.didMigrateScreenshotShortcutToCtrlOptSpace")
        }
        screenshotShortcut = loadedScreenshotShortcut
        // Migrate the old haptic-only setting to the general feedback setting.
        if let value = defaults.object(forKey: "feedbackEnabled") as? Bool {
            feedbackEnabled = value
        } else if let legacy = defaults.object(forKey: "hapticFeedbackEnabled") as? Bool {
            feedbackEnabled = legacy
            defaults.set(legacy, forKey: "feedbackEnabled")
        } else {
            feedbackEnabled = true
        }
        if let raw = defaults.string(forKey: "feedbackMode"), let mode = FeedbackMode(rawValue: raw) {
            feedbackMode = mode
        } else {
            feedbackMode = .haptic
        }
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
        screenShareProtectionEnabled = defaults.bool(forKey: "screenShareProtectionEnabled")
        autoHideOnScreenShare = defaults.bool(forKey: "autoHideOnScreenShare")
        coreGraphicsHardeningEnabled = defaults.bool(forKey: "coreGraphicsHardeningEnabled")
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidBecomeVisibleNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            self.applyWindowDiscretion(to: window)
            self.applyScreenShareProtection(to: window)
        }
        cancellables.insert(AnyCancellable { NotificationCenter.default.removeObserver(observer) })
    }

    func installShortcutRegistrationHandler(_ handler: @escaping (GlobalShortcut.Kind, GlobalShortcut) -> String?) {
        shortcutRegistrationHandler = handler
        let (resolvedToggle, toggleError) = resolveInitialShortcut(.toggle, shortcut: toggleShortcut, handler: handler)
        if resolvedToggle != toggleShortcut {
            resolvedToggle.persist(to: .standard, kind: .toggle)
        }
        toggleShortcut = resolvedToggle
        shortcutRegistrationError = toggleError
        let (resolvedScreenshot, screenshotError) = resolveInitialShortcut(.screenshot, shortcut: screenshotShortcut, handler: handler)
        if resolvedScreenshot != screenshotShortcut {
            resolvedScreenshot.persist(to: .standard, kind: .screenshot)
        }
        screenshotShortcut = resolvedScreenshot
        screenshotShortcutRegistrationError = screenshotError
    }

    private func resolveInitialShortcut(
        _ kind: GlobalShortcut.Kind,
        shortcut: GlobalShortcut,
        handler: (GlobalShortcut.Kind, GlobalShortcut) -> String?
    ) -> (shortcut: GlobalShortcut, error: String?) {
        if let error = handler(kind, shortcut) {
            if shortcut != kind.defaultShortcut,
               handler(kind, kind.defaultShortcut) == nil {
                return (kind.defaultShortcut, "\(shortcut.displayName) was unavailable, so the shortcut was reset to \(kind.defaultShortcut.displayName).")
            } else {
                return (shortcut, error)
            }
        }
        return (shortcut, nil)
    }

    func setToggleShortcut(_ shortcut: GlobalShortcut) {
        let (newShortcut, error) = setShortcut(shortcut, kind: .toggle)
        toggleShortcut = newShortcut
        shortcutRegistrationError = error
        if error == nil {
            newShortcut.persist(to: .standard, kind: .toggle)
        }
    }

    func setScreenshotShortcut(_ shortcut: GlobalShortcut) {
        let (newShortcut, error) = setShortcut(shortcut, kind: .screenshot)
        screenshotShortcut = newShortcut
        screenshotShortcutRegistrationError = error
        if error == nil {
            newShortcut.persist(to: .standard, kind: .screenshot)
        }
    }

    private func setShortcut(
        _ shortcut: GlobalShortcut,
        kind: GlobalShortcut.Kind
    ) -> (shortcut: GlobalShortcut, error: String?) {
        let current = kind == .toggle ? toggleShortcut : screenshotShortcut
        guard shortcut != current else { return (current, nil) }
        guard let handler = shortcutRegistrationHandler else {
            return (current, "The global shortcut service is not ready.")
        }
        if let error = handler(kind, shortcut) {
            return (current, "\(error) Your previous shortcut is still active.")
        }
        return (shortcut, nil)
    }

    // Feedback signal that an assistant response has finished. The mode
    // chooses between a trackpad haptic and a Caps Lock LED blink.
    func performFeedback() {
        guard feedbackEnabled else { return }
        if feedbackMode == .capsLock, CapsLockLED.shared.available {
            // Caps Lock blinks once.
            CapsLockLED.shared.blink(count: 1, tapInterval: 0.20)
        } else {
            // Haptic taps the trackpad twice — a single .alignment tap is too
            // faint to notice, so a double tap reads clearly as "done."
            let performer = NSHapticFeedbackManager.defaultPerformer
            performer.perform(.alignment, performanceTime: .now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                performer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    // Multiple-choice screenshot turn: parse the assistant's answer for A/B/C/D
    // or 1/2/3/4 and produce feedback for each choice. A=1 pulse, B=2 pulses,
    // etc., with a pause between choices so they can be distinguished.
    func performMultipleChoiceFeedback(for text: String) {
        guard feedbackEnabled else { return }
        let answers = Self.multipleChoiceAnswers(from: text)
        guard !answers.isEmpty else { return }
        let tapInterval: TimeInterval = 0.35
        let groupPause: TimeInterval = 1.20
        let useLED = feedbackMode == .capsLock && CapsLockLED.shared.available
        var delay: TimeInterval = 0
        for (index, answer) in answers.enumerated() {
            for tapIndex in 0..<answer {
                let pulseStart = delay + TimeInterval(tapIndex) * tapInterval
                if useLED {
                    let onDuration: TimeInterval = 0.15
                    DispatchQueue.main.asyncAfter(deadline: .now() + pulseStart) {
                        CapsLockLED.shared.setOn(true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + pulseStart + onDuration) {
                        CapsLockLED.shared.setOn(false)
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + pulseStart) {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
            }
            delay += TimeInterval(answer) * tapInterval
            if index < answers.count - 1 {
                delay += groupPause
            }
        }
    }

    private static func multipleChoiceAnswers(from text: String) -> [Int] {
        let map: [String: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4,
            "1": 1, "2": 2, "3": 3, "4": 4,
        ]
        let upper = text.uppercased()
        let pattern = #"(?<!\w)([A-D1-4])(?!\w)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: upper, options: [], range: NSRange(upper.startIndex..., in: upper))
        return matches.compactMap { match in
            let answer = (upper as NSString).substring(with: match.range(at: 1))
            return map[answer]
        }
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
        NSLog("Eave: repositioned for display \(nextID) frame=\(NSStringFromRect(next.frame))")
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
        let window = targetWindow?.frame ?? collapsedFrame
        // Permission and question hang a button band below the camera row.
        // Hovering there must not expand the panel out from under a click aimed
        // at Deny / Allow / Answer, so in those states hover activation shrinks
        // to the notch strip itself and the band stays purely clickable.
        switch notchMode {
        case .permission, .question:
            let width = notchWidth + activationInset * 2
            return NSRect(
                x: window.midX - width / 2,
                y: window.maxY - notchHeight,
                width: width,
                height: notchHeight + activationTopOvershoot
            )
        default:
            return activationFrame(for: window)
        }
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
        // Silent screenshot turn: hide all background activity in the notch.
        if session.isRunning { return silentTurn ? .idle : .working }
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
        // Compact: hairline for working/alerts; Done grows into wings like
        // standard so "Done", elapsed time, and the drain sliver can fit.
        if notchStyle == .compact {
            switch notchMode {
            case .idle:
                return base
            case .completed:
                return NSSize(width: min(base.width + 200, maxPanelWidth), height: base.height + 6)
            default:
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
            return NSSize(width: min(base.width + 200, maxPanelWidth), height: base.height + 6)
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
        } else {
            if let last = session.messages.last, last.role == .assistant {
                if silentTurn {
                    // Screenshot turns: classify the response based on content.
                    multipleChoiceTurn = !Self.multipleChoiceAnswers(from: last.text).isEmpty
                    if multipleChoiceTurn {
                        performMultipleChoiceFeedback(for: last.text)
                    } else {
                        // Normal response to a screenshot: steady Caps Lock LED for 1 second.
                        CapsLockLED.shared.setOn(true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            CapsLockLED.shared.setOn(false)
                        }
                    }
                } else {
                    performFeedback()
                }
                if !expanded, !silentTurn, !multipleChoiceTurn {
                    showingCompleted = true
                    completedStartedAt = Date()
                    completedTimer?.invalidate()
                    completedTimer = Timer.scheduledTimer(withTimeInterval: stealthMode ? 2 : completedDuration, repeats: false) { [weak self] _ in
                        self?.showingCompleted = false
                        self?.syncNotchFrame(animated: true)
                    }
                }
            }
            // A silent / multiple-choice turn ends when the session stops running.
            silentTurn = false
            multipleChoiceTurn = false
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

    // Strict toggle: the configured shortcut always opens or closes, regardless of
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
            NSLog("Eave: expand() called but chatPanel is nil")
            return
        }
        if !expanded {
            panel.setFrame(expandedFrame, display: false)
            expanded = true
            lastExpandAt = Date()
            panel.orderFrontRegardless()
            applyPanelBlur()
            NSLog("Eave: expand(takeKeyboard=\(takeKeyboard)) frame=\(NSStringFromRect(panel.frame)) visible=\(panel.isVisible)")
        }
        if takeKeyboard {
            panel.makeKeyAndOrderFront(nil)
            // Opening with typing intent pulls the stealth composer up.
            if stealthMode { stealthComposerOpen = true }
        }
    }

    func collapse() {
        guard expanded else { return }
        NSLog("Eave: collapse()")
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
    enum SettingsTab: Hashable { case general, appearance, privacy, agents, about }

    @Published var settingsTab: SettingsTab = .general

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Eave Settings"
            win.isReleasedWhenClosed = false
            // Deliberately NOT .transient: a transient window auto-hides
            // whenever the accessory app is inactive, which produced the
            // "focus shifts but no Settings window appears" bug. Follow the
            // active Space and float over fullscreen apps instead.
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            win.isExcludedFromWindowsMenu = true
            let host = NSHostingView(rootView: SettingsView(state: self))
            // AppKit does not resize the window to fit SwiftUI content, so a
            // fixed height silently clipped the lower half of the settings.
            // Size to what the content wants, capped to the screen.
            host.layoutSubtreeIfNeeded()
            let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
            let height = min(max(host.fittingSize.height, 260), screenHeight - 120)
            win.setContentSize(NSSize(width: 340, height: height))
            win.contentView = host
            win.center()
            // Reopen the notch panel when Settings closes, if it was open.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: win, queue: .main
            ) { [weak self] _ in
                guard let self, self.reopenPanelAfterSettings else { return }
                self.reopenPanelAfterSettings = false
                self.expand(takeKeyboard: true)
            }
            settingsWindow = win
            // applyWindowDiscretion is skipped on purpose — it re-inserts the
            // .transient behavior we just avoided. The window is already kept
            // out of the Windows menu above.
            applyScreenShareProtection(to: win)
        }
        // The panel sits at .statusBar level, above the settings window, so
        // collapse it while Settings is up and restore it on close.
        reopenPanelAfterSettings = expanded
        if expanded { collapse() }
        // Recover a window stranded off-screen by a since-disconnected display
        // (it would order front where nothing is visible), then force it
        // forward — an accessory app can't rely on activate() alone to raise
        // and key the window.
        if let win = settingsWindow {
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(win.frame) }
            if !onScreen { win.center() }
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
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
            NSLog("Eave: screen[\(i)] frame=\(NSStringFromRect(s.frame)) safeTop=\(s.safeAreaInsets.top) isMain=\(s == NSScreen.main)")
        }
        NSLog("Eave: hasNotch=\(hasNotch) collapsedFrame=\(NSStringFromRect(collapsedFrame)) expandedFrame=\(NSStringFromRect(expandedFrame))")
        NSLog("Eave: targetWindow visible=\(targetWindow?.isVisible ?? false) frame=\(NSStringFromRect(targetWindow?.frame ?? .zero))")
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
            // Short dwell so flybys toward the menu bar don't open it. Every
            // state hover-expands; permission and question protect their own
            // buttons by narrowing activationFrame to the notch strip rather
            // than by opting out of hover.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                if self.notchHovering && !self.expanded {
                    NSLog("Eave: hover-expanding")
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
