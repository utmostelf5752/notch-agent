import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Shared drop handler: appends dropped file URLs to the session's attachments.
@discardableResult
func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
    var accepted = false
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        accepted = true
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            DispatchQueue.main.async {
                AppState.shared.session.addAttachments([url])
            }
        }
    }
    return accepted
}

enum ScreenshotTarget: Equatable {
    case fullScreen
    case activeAppWindow

    var fileLabel: String {
        switch self {
        case .fullScreen: return "full"
        case .activeAppWindow: return "window"
        }
    }
}

// Shared by the attachment menu and the app's signal-driven debug harness so
// the exact production capture path can be exercised without UI automation.
enum ScreenshotCapture {
    static func capture(_ target: ScreenshotTarget, state: AppState = .shared) {
        let path = AppPaths.screenshotsDirectory
            .appendingPathComponent(
                "notchagent-screenshot-\(target.fileLabel)-\(UUID().uuidString).jpg"
            ).path
        var args = ["-x", "-t", "jpg"]
        var fadedWindows: [(window: NSWindow, alpha: CGFloat)] = []
        var statusItemAlpha: CGFloat?

        switch target {
        case .activeAppWindow:
            guard let windowID = frontmostExternalWindowID() else {
                state.session.messages.append(ChatMessage(
                    role: .error,
                    text: "Screenshot failed — no open window was found in the active app."
                ))
                return
            }
            args += ["-l", String(windowID)]
        case .fullScreen:
            state.suspendCollapse = true
            // Keep our all-Spaces windows ordered and the panel key. Ordering
            // them out can reactivate an app on another Space before capture.
            fadedWindows = NSApp.windows
                .filter(\.isVisible)
                .map { ($0, $0.alphaValue) }
            fadedWindows.forEach { $0.window.alphaValue = 0 }
            statusItemAlpha = (NSApp.delegate as? AppDelegate)?.setStatusItemAlpha(0)
        }
        args.append(path)

        let restoreAppChrome = {
            guard target == .fullScreen else { return }
            fadedWindows.forEach { $0.window.alphaValue = $0.alpha }
            if let statusItemAlpha {
                (NSApp.delegate as? AppDelegate)?.setStatusItemAlpha(statusItemAlpha)
            }
            state.suspendCollapse = false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                restoreAppChrome()
                if FileManager.default.fileExists(atPath: path) {
                    state.session.addAttachments([URL(fileURLWithPath: path)])
                } else {
                    state.session.messages.append(ChatMessage(
                        role: .error,
                        text: "Screenshot failed — grant Screen Recording permission to NotchAgent in System Settings > Privacy."
                    ))
                }
            }
        }

        let launchCapture = {
            do {
                try process.run()
            } catch {
                restoreAppChrome()
                state.session.messages.append(ChatMessage(
                    role: .error,
                    text: "Screenshot failed — \(error.localizedDescription)"
                ))
            }
        }
        if target == .fullScreen {
            // Give WindowServer a frame to apply the transparent app chrome.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: launchCapture)
        } else {
            // Window capture is isolated from overlapping windows by id.
            launchCapture()
        }
    }

    // Prefer the frontmost application's first normal window. If opening one
    // of our controls made any NotchAgent instance frontmost, the z-ordered
    // fallback finds the first normal window behind all NotchAgent processes.
    private static func frontmostExternalWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        func isNotchAgent(_ pid: pid_t, info: [String: Any]) -> Bool {
            if pid == ProcessInfo.processInfo.processIdentifier { return true }
            let normalize: (String) -> String = {
                $0.lowercased().filter(\.isLetter)
            }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if normalize(owner) == "notchagent" { return true }
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            if normalize(app.localizedName ?? "") == "notchagent" { return true }
            if normalize(app.executableURL?.lastPathComponent ?? "") == "notchagent" { return true }
            let ownBundleID = Bundle.main.bundleIdentifier ?? "com.jagruth.notchagent"
            return app.bundleIdentifier == ownBundleID
                || app.bundleIdentifier == "com.jagruth.notchagent"
        }

        func firstWindow(ownedBy requiredPID: pid_t?) -> CGWindowID? {
            for info in list {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      !isNotchAgent(pid, info: info),
                      requiredPID == nil || pid == requiredPID,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let number = info[kCGWindowNumber as String] as? UInt32
                else { continue }
                return CGWindowID(number)
            }
            return nil
        }

        if let frontmostPID,
           let windowID = firstWindow(ownedBy: frontmostPID) {
            return windowID
        }
        return firstWindow(ownedBy: nil)
    }
}

// The notch silhouette: rounded bottom corners, and optionally top corners
// that flare outward — the top edge is topRadius wider per side than the
// body and curves down into it, the same fillet the physical notch has
// against the menu bar. topRadius 0 is the plain stock rectangle.
struct NotchShape: Shape {
    var radius: CGFloat
    var topRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + topRadius
        let right = rect.maxX - topRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        if topRadius > 0 {
            p.addQuadCurve(
                to: CGPoint(x: right, y: rect.minY + topRadius),
                control: CGPoint(x: right, y: rect.minY)
            )
        }
        p.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        p.addQuadCurve(
            to: CGPoint(x: right - radius, y: rect.maxY),
            control: CGPoint(x: right, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY - radius),
            control: CGPoint(x: left, y: rect.maxY)
        )
        if topRadius > 0 {
            p.addLine(to: CGPoint(x: left, y: rect.minY + topRadius))
            p.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.minY),
                control: CGPoint(x: left, y: rect.minY)
            )
        }
        p.closeSubpath()
        return p
    }
}

// The diffusion layer of the frosted materials: a behind-window
// NSVisualEffectView. Unlike the CGS window blur (a radius on the whole
// window rectangle), this is an ordinary layer — it clips to the panel
// shape, tracks resizes, and rides the reveal mask like any other view,
// and its materials add the saturation boost the CGS blur lacks.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var appearance: NSAppearance.Name

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.appearance = NSAppearance(named: appearance)
    }
}

// The always-on click target drawn over the physical notch. While the panel
// is collapsed it doubles as "background mode": the notch grows sideways to
// narrate the running turn (activity + elapsed/tokens) and grows downward into
// an alert band when the agent needs a permission or an answer. The camera
// cutout stays clear — working content lives in the wings on either side, and
// alerts sit in a band below the camera row.
// Hover state lives on AppState (mouse poll) because SwiftUI onHover is
// unreliable on a window that can never become key.
struct NotchTargetView: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: AgentSession

    private let accent = Color(red: 10/255, green: 132/255, blue: 1)
    private let amber = Color(red: 232/255, green: 182/255, blue: 76/255)
    private let questionBlue = Color(red: 125/255, green: 184/255, blue: 1)
    private let green = Color(red: 52/255, green: 211/255, blue: 153/255)

    var body: some View {
        ZStack {
            // Transparent until there's something to show: an idle notch (and a
            // silent stealth-working one) is exactly notch-sized, so a black fill
            // is invisible against the hardware notch in person but its rounded
            // bottom corners poke out as black nubs in screenshots. Only paint
            // the backing once the window has grown to hold content.
            NotchShape(radius: radius, topRadius: state.notchTopRadius)
                .fill(showsBackground ? Color.black : Color.clear)
            content
        }
        // Dragging a file onto the notch attaches it and opens the panel.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            let accepted = acceptDroppedFiles(providers)
            if accepted { state.expand(takeKeyboard: true) }
            return accepted
        }
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.4), value: state.notchMode)
    }

    // Whether the notch backing should be painted: only when the window has
    // grown past the bare notch. A notch-sized black fill is invisible in
    // person but its rounded bottom corners poke out in screenshots, so
    // stealth stays unpainted while working and after its announcement
    // sliver has hidden.
    private var showsBackground: Bool {
        switch state.notchMode {
        case .idle: return false
        case .working: return !state.stealthMode
        case .permission, .question:
            return !state.stealthMode || state.stealthAlertSliverVisible
        case .completed: return true
        }
    }

    private var radius: CGFloat {
        // Stealth mimics the bare hardware notch, so it keeps the stock 8.
        if state.notchStyle == .stealth { return 8 }
        if state.notchStyle == .compact { return 10 }
        switch state.notchMode {
        case .idle: return 10
        case .working, .completed: return 14
        case .permission, .question: return 20
        }
    }

    @ViewBuilder private var content: some View {
        switch state.notchStyle {
        case .stealth:
            stealthContent
        case .compact:
            compactContent
        case .standard:
            switch state.notchMode {
            case .idle: idleContent
            case .working: workingContent
            case .completed: completedContent
            case .permission: alertBand(
                title: "Permission needed", tint: amber,
                detail: session.pendingPermission?.detail ?? "",
                trailing: AnyView(permissionButtons))
            case .question: alertBand(
                title: "Needs your answer", tint: questionBlue,
                detail: session.pendingQuestion?.current.question ?? "",
                trailing: AnyView(answerButton))
            }
        }
    }

    // MARK: Compact — every background state is the same sweeping hairline
    // under the notch; only the color says what's happening. White = working,
    // amber = permission, blue = question; green sweeps 3 times on done and
    // the notch snaps back (the completed timer expires with the third sweep).
    @ViewBuilder private var compactContent: some View {
        switch state.notchMode {
        case .idle: idleContent
        case .working: compactSliver(.white)
        case .permission: compactSliver(amber)
        case .question: compactSliver(questionBlue)
        case .completed: compactSliver(green, sweeps: 3, anchor: state.completedStartedAt)
        }
    }

    // One sweep per second: a bright band travels the dim track left to right.
    // sweeps anchors time to `anchor` and runs exactly N sweeps — the band
    // then parks at the right, or the whole sliver vanishes with
    // hidesWhenDone; nil sweeps forever.
    private func compactSliver(
        _ color: Color, sweeps: Int? = nil, anchor: Date = .distantPast, hidesWhenDone: Bool = false
    ) -> some View {
        TimelineView(.animation) { ctx in
            let t = sweeps != nil
                ? ctx.date.timeIntervalSince(anchor)
                : ctx.date.timeIntervalSinceReferenceDate
            let stopped = sweeps.map { t >= Double($0) } ?? false
            let progress = stopped ? 1.0 : max(0, t).truncatingRemainder(dividingBy: 1)
            GeometryReader { geo in
                let bandWidth = geo.size.width * 0.4
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.22))
                    Capsule()
                        .fill(color.opacity(0.9))
                        .frame(width: bandWidth)
                        .offset(x: (geo.size.width + bandWidth) * progress - bandWidth)
                }
                .clipShape(Capsule())
            }
            .frame(height: 2)
            .padding(.horizontal, 22)
            .opacity(hidesWhenDone && stopped ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { state.expand(takeKeyboard: true) }
    }

    // MARK: Stealth — nothing at all while idle or working. Alerts and
    // completion both announce themselves the same way: a near-black sliver
    // sweeps twice and disappears. The whole area stays a click target
    // throughout.
    @ViewBuilder private var stealthContent: some View {
        switch state.notchMode {
        case .idle, .working:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { state.expand(takeKeyboard: true) }
        case .permission, .question:
            if state.stealthAlertSliverVisible {
                compactSliver(
                    Color(white: 0.25), sweeps: 2,
                    anchor: state.stealthAlertStartedAt, hidesWhenDone: true)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { state.expand(takeKeyboard: true) }
            }
        case .completed:
            compactSliver(
                Color(white: 0.25), sweeps: 2,
                anchor: state.completedStartedAt, hidesWhenDone: true)
        }
    }

    // MARK: Idle — the original hover-sparkle click target.
    private var idleContent: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(state.notchHovering ? 0.85 : 0))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 3)
            .animation(.easeOut(duration: 0.15), value: state.notchHovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { state.expand(takeKeyboard: true) }
    }

    // MARK: Working — activity in the left wing, tokens/time in the right,
    // camera-width gap kept clear in the middle.
    private var workingContent: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: activity.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                Text(activity.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 15)
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: state.notchWidth) // camera safe zone

            HStack(spacing: 6) {
                LiveDot(color: accent)
                if session.provider != .chatgpt {
                    Text(tokenText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("·").foregroundStyle(.white.opacity(0.3))
                }
                Text(elapsedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .fixedSize()
            .padding(.trailing, 15)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.expand(takeKeyboard: true) }
    }

    // MARK: Completed — a brief "Done" pill with a draining bar that dismisses
    // itself. Same wing layout as working; a green check replaces the activity.
    private var completedContent: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(green)
                    Text("Done")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(green)
                }
                .padding(.leading, 15)
                .frame(maxWidth: .infinity, alignment: .leading)

                Color.clear.frame(width: state.notchWidth)

                HStack(spacing: 6) {
                    Text(tokenText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(completedTimeText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .fixedSize()
                .padding(.trailing, 15)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            drainBar
                .padding(.horizontal, 15)
                .padding(.bottom, 3)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.expand(takeKeyboard: true) }
    }

    // Thin bar that empties over the pill's lifetime, mirroring the countdown to
    // auto-dismiss. TimelineView drives it without @State.
    private var drainBar: some View {
        TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(state.completedStartedAt)
            let p = max(0, min(1, 1 - elapsed / state.completedDuration))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(green).frame(width: geo.size.width * p)
                }
            }
            .frame(height: 2)
        }
    }

    // MARK: Alert band — permission or question, below the camera row.
    private func alertBand(title: String, tint: Color, detail: String, trailing: AnyView) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.notchHeight) // camera row
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var permissionButtons: some View {
        HStack(spacing: 6) {
            Button { session.respondPermission(.deny) } label: {
                Text("Deny")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(red: 224/255, green: 122/255, blue: 106/255))
                    .padding(.vertical, 5).padding(.horizontal, 9)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            Button { session.respondPermission(.allow) } label: {
                Text("Allow")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 5).padding(.horizontal, 11)
                    .background(Capsule().fill(amber))
            }
            .buttonStyle(.plain)
        }
    }

    // Multiple choice needs the real UI, so Answer just opens the panel.
    private var answerButton: some View {
        Button { state.expand(takeKeyboard: true) } label: {
            HStack(spacing: 3) {
                Text("Answer")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 5).padding(.horizontal, 11)
            .background(Capsule().fill(accent))
        }
        .buttonStyle(.plain)
    }

    // MARK: Derived labels

    private var activity: (icon: String, text: String) {
        guard let last = session.messages.last else { return ("sparkle", "Starting") }
        switch last.role {
        case .tool: return (last.icon ?? "wrench.fill", last.text)
        case .assistant: return ("text.alignleft", "Responding")
        default: return ("sparkle", "Thinking")
        }
    }

    private var tokenText: String {
        let toks = session.turnChars / 4
        if toks < 1000 { return "\(toks) tok" }
        return String(format: "%.1fk tok", Double(toks) / 1000)
    }

    private var elapsedText: String {
        guard let start = session.turnStartedAt else { return "0:00" }
        let s = max(0, Int(state.clockTick.timeIntervalSince(start)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private var completedTimeText: String {
        let s = max(0, Int(session.lastTurnDuration))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// A softly pulsing dot — the only motion in the working strip, standing in for
// the old spinner. TimelineView drives it so it needs no @State (unavailable
// in this build; see AgentSession).
struct LiveDot: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * 2.6) + 1) / 2
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(0.45 + 0.55 * phase)
                .shadow(color: color.opacity(0.6), radius: 3)
        }
    }
}

struct ChatRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var session: AgentSession
    @ObservedObject private var chatgptWeb = ChatGPTWeb.shared
    @FocusState private var inputFocused: Bool

    private let cornerRadius: CGFloat = 24
    private let accent = Color(red: 10/255, green: 132/255, blue: 1)

    // Stealth shrinks the whole panel UI: the panel is locked to the notch's
    // width there, so smaller text and controls buy back real room.
    private var s: CGFloat { state.stealthMode ? 0.85 : 1 }

    var body: some View {
        Group {
            VStack(spacing: 0) {
                Color.clear.frame(height: state.notchHeight + 2)
                messagesList
                    // The composer floats over the chat: its translucent box
                    // lets messages show through as they scroll underneath, and
                    // the safe-area inset stops the scroll's end above it so the
                    // last message is never trapped behind the box.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            questionSheet
                            // A pending approval overrides the stealth hide —
                            // the composer is where the Deny/Allow buttons live.
                            if !state.stealthMode || state.stealthComposerOpen || session.pendingPermission != nil {
                                composer
                            }
                        }
                    }
            }
            .animation(.easeOut(duration: 0.2), value: state.stealthComposerOpen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Only stealth dims: translucent glyphs that let what's behind the
            // pane show through them. Every normal mode keeps content at full
            // strength, whatever the material.
            .opacity(state.stealthMode ? 0.45 : 1)
            .background(panelBackdrop)
            .clipShape(NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius))
            .overlay(alignment: .top) { topStrip.opacity(state.stealthMode ? 0.4 : 1) }
            .overlay {
                if state.dropTargeted {
                    NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius)
                        .fill(Color.black.opacity(0.82))
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 18))
                                Text("drop to attach")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.7))
                        }
                        .allowsHitTesting(false)
                }
            }
            // Stealth is colorless: one desaturation pass turns every accent —
            // send blue, permission amber, error red — to greyscale.
            // 0.9999, not 1: at exactly 1 SwiftUI removes the saturation effect
            // layer entirely, and on the stealth→normal transition that teardown
            // leaves the AppKit-backed views (text field, menus) and some text
            // unrendered until the panel is reopened. Keeping the effect active
            // in both states sidesteps it; 0.9999 is visually identical to 1.
            .saturation(state.stealthMode ? 0 : 0.9999)
            // Reveal, not movement: the content is laid out in place and a
            // top-anchored mask wipes downward over it, so the panel appears to
            // be uncovered rather than to slide. Stealth folds out the same way.
            .mask {
                GeometryReader { geo in
                    NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius)
                        .frame(height: state.expanded ? geo.size.height : 0)
                }
            }
            // Resize handles sit AFTER the mask so they aren't clipped to the panel
            // shape — they intentionally straddle the visible edge, extending out
            // into the window's transparent margin. Width is locked to the notch in
            // stealth, so the side/corner handles only exist when not stealth.
            .overlay(alignment: .leading) { if !state.stealthMode { sideResizeHandle(sign: -1) } }
            .overlay(alignment: .trailing) { if !state.stealthMode { sideResizeHandle(sign: 1) } }
            .overlay(alignment: .bottom) { bottomResizeHandle }
            .overlay(alignment: .bottomLeading) { if !state.stealthMode { cornerResizeHandle(sign: -1) } }
            .overlay(alignment: .bottomTrailing) { if !state.stealthMode { cornerResizeHandle(sign: 1) } }
            .padding(.horizontal, AppState.panelMargin)
            .padding(.bottom, AppState.panelBottomMargin)
            // Install the drop target after every overlay and outer margin so
            // files can be released anywhere across the complete panel UI.
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $state.dropTargeted) { providers in
                acceptDroppedFiles(providers)
            }
            .preferredColorScheme(.dark)
            .animation(
                state.expanded
                    ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
                    : .easeInOut(duration: 0.25),
                value: state.expanded
            )
            .onChange(of: state.panelIsKey) { isKey in
                if isKey {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
                } else {
                    inputFocused = false
                }
            }
            // Pulling the stealth composer up while the panel is key should put
            // the caret in it immediately.
            .onChange(of: state.stealthComposerOpen) { open in
                if open && state.panelIsKey {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
                }
            }
        }
    }

    // Near-black in stealth; otherwise per panelStyle. Smoke is a darker
    // NSVisualEffectView blur. Clear keeps the faint CGS blur set in AppState.
    @ViewBuilder private var panelBackdrop: some View {
        let shape = NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius)
        if state.stealthMode {
            // Stealth honors only the clear material; smoke falls back to
            // the near-black overlay. Neither draws a stroke — a lit rim
            // would trace the panel's corners, which is exactly what
            // stealth is hiding.
            if state.panelStyle == .clear {
                clearPane(shape)
            } else {
                shape.fill(Color(red: 0.01, green: 0.01, blue: 0.02).opacity(0.94))
            }
        } else {
            switch state.panelStyle {
            case .black:
                shape.fill(Color.black)
            case .smoke:
                smokeGlass(shape: shape)
            case .clear:
                clearPane(shape)
                    .overlay(shape.stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
        }
    }

    private func clearPane(_ shape: NotchShape) -> some View {
        shape.fill(LinearGradient(
            stops: [
                .init(color: .white.opacity(0.05), location: 0),
                .init(color: .white.opacity(0.01), location: 0.25),
                .init(color: Color(red: 0.03, green: 0.03, blue: 0.05).opacity(0.12), location: 1),
            ],
            startPoint: .top, endPoint: .bottom))
    }

    // Smoked frosted glass: a dark vibrancy backdrop diffuses what's behind
    // the window under a smoked tint, with only dark edge shading for depth
    // — no specular rim or corner glows, so the edges never catch light.
    private func smokeGlass(shape: NotchShape) -> some View {
        ZStack {
            VisualEffectBackdrop(material: .hudWindow, appearance: .vibrantDark)
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.30).opacity(0.10), location: 0),
                    .init(color: .black.opacity(0.26), location: 0.5),
                    .init(color: .black.opacity(0.40), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
            // Depth: the pane darkens slightly toward its edges the way
            // thick glass does.
            shape.stroke(Color.black.opacity(0.20), style: StrokeStyle(lineWidth: 30))
                .blur(radius: 20)
            // The refraction line just inside the edge.
            shape.stroke(Color.black.opacity(0.28), lineWidth: 1)
                .padding(1.8)
                .blur(radius: 0.6)
        }
        .allowsHitTesting(false)
    }

    // Edge-drag resizing. Width is symmetric (the panel stays centered on the
    // notch, so pulling one side grows both); height grows downward. Deltas
    // come from NSEvent.mouseLocation (screen coords) so the math stays
    // stable while the window frame changes mid-drag.
    private func sideResizeHandle(sign: CGFloat) -> some View {
        Color.clear
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            // Center the handle on the visible edge: ~6pt over the panel, ~6pt
            // out into the margin.
            .offset(x: sign * 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if state.resizeStart == nil {
                            state.resizeStart = (mouse, NSSize(width: state.panelWidth, height: state.panelHeight))
                        }
                        guard let start = state.resizeStart else { return }
                        let dx = (mouse.x - start.mouse.x) * sign
                        state.applyPanelResize(width: start.size.width + dx * 2)
                    }
                    .onEnded { _ in
                        state.resizeStart = nil
                        state.persistPanelSize()
                    }
            )
    }

    // Corner drag: width and height at once. Width stays symmetric like the
    // side handles (panel is centered on the notch); height grows downward.
    private func cornerResizeHandle(sign: CGFloat) -> some View {
        Circle()
            .fill(Color.clear)
            .frame(width: 18, height: 18)
            // Center the corner on the panel's bottom corner, straddling it.
            .offset(x: sign * 6, y: 6)
            .contentShape(Circle())
            .onHover { hovering in
                if hovering {
                    // No true diagonal cursor in AppKit; the down-up arrow
                    // reads best for a bottom corner.
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if state.resizeStart == nil {
                            state.resizeStart = (mouse, NSSize(width: state.panelWidth, height: state.panelHeight))
                        }
                        guard let start = state.resizeStart else { return }
                        let dx = (mouse.x - start.mouse.x) * sign
                        let dy = start.mouse.y - mouse.y
                        state.applyPanelResize(
                            width: start.size.width + dx * 2,
                            height: start.size.height + dy)
                    }
                    .onEnded { _ in
                        state.resizeStart = nil
                        state.persistPanelSize()
                    }
            )
    }

    private var bottomResizeHandle: some View {
        Color.clear
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            // Center on the visible bottom edge, straddling it.
            .offset(y: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        if state.resizeStart == nil {
                            state.resizeStart = (mouse, NSSize(width: state.panelWidth, height: state.panelHeight))
                        }
                        guard let start = state.resizeStart else { return }
                        // AppKit screen coords grow upward; dragging down is negative.
                        let dy = start.mouse.y - mouse.y
                        state.applyPanelResize(height: start.size.height + dy)
                    }
                    .onEnded { _ in
                        state.resizeStart = nil
                        state.persistPanelSize()
                    }
            )
    }

    // Buttons live in the black strip flanking the physical notch cutout:
    // history + settings on the left; pin + new chat on the right.
    private var topStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                historyButton
                settingsButton
            }
            Spacer()
            HStack(spacing: 12) {
                pinButton
                newChatButton
            }
        }
        .padding(.horizontal, 14)
        .frame(height: state.notchHeight + 2)
    }

    private var historyButton: some View {
        Button { state.showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Past chats")
        .popover(isPresented: $state.showHistory, arrowEdge: .bottom) {
            historyList
        }
    }

    private var historyList: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if session.pastChats.isEmpty {
                    Text("No past chats")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(session.pastChats) { chat in
                    HStack(spacing: 6) {
                        Button {
                            session.restore(chat)
                            state.showHistory = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text("\(chat.provider.label) · \(chat.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            session.deleteChat(chat.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            }
            .padding(6)
        }
        .frame(width: 230)
        .frame(maxHeight: 260)
    }

    private var pinButton: some View {
        Button { state.pinned.toggle() } label: {
            Image(systemName: state.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(state.pinned ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(state.pinned ? "Unpin — clicking elsewhere closes the panel" : "Pin — keep open while using other apps")
    }

    private var settingsButton: some View {
        Button { state.openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private var newChatButton: some View {
        Button(action: session.reset) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("New conversation")
    }

    // Consecutive tool messages render as one collapsible "N steps" group.
    // The trailing run stays live-inline while the turn is in flight, then
    // collapses when it finishes.
    private enum DisplayItem: Identifiable {
        case message(ChatMessage)
        case steps([ChatMessage])

        var id: UUID {
            switch self {
            case .message(let m): return m.id
            case .steps(let run): return run[0].id
            }
        }
    }

    private var displayItems: [DisplayItem] {
        var out: [DisplayItem] = []
        var run: [ChatMessage] = []
        for message in session.messages {
            if message.role == .tool {
                run.append(message)
            } else {
                if !run.isEmpty { out.append(.steps(run)); run = [] }
                out.append(.message(message))
            }
        }
        if !run.isEmpty {
            if session.isRunning {
                run.forEach { out.append(.message($0)) }
            } else {
                out.append(.steps(run))
            }
        }
        return out
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10 * s) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message, scale: s)
                                .id(item.id)
                        case .steps(let run):
                            StepsGroup(
                                steps: run,
                                scale: s,
                                expanded: state.expandedGroups.contains(item.id),
                                toggle: {
                                    if state.expandedGroups.contains(item.id) {
                                        state.expandedGroups.remove(item.id)
                                    } else {
                                        state.expandedGroups.insert(item.id)
                                    }
                                }
                            )
                            .id(item.id)
                        }
                    }
                    if session.isRunning && session.messages.last?.role != .assistant {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(currentActivity)
                                .font(.system(size: 11 * s))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.top, 2)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 12 * s)
                .padding(.horizontal, 18 * s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.messages) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: session.isRunning) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Fog at the bottom edge: text dissolves just above the composer
            // instead of being cut off mid-glyph. An alpha mask, not a color
            // overlay — the backdrop can be clear glass, so painting a
            // gradient over it would show as a smudge on the desktop. The
            // mask honors the composer's safe-area inset, so nothing renders
            // behind the composer box.
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black.opacity(0.6), location: 0.45),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 36 * s)
                }
            }
            .overlay {
                if let notice = session.usageLimit {
                    usageLimitScreen(notice)
                } else if session.messages.isEmpty && !session.isRunning {
                    emptyState
                }
            }
            // Stealth: clicking the history pulls the composer up; clicking
            // again puts it away so a short panel shows only the chat text.
            .contentShape(Rectangle())
            .onTapGesture {
                guard state.stealthMode else { return }
                state.stealthComposerOpen.toggle()
            }
        }
    }

    // While running, the spinner row narrates the most recent tool action.
    private var currentActivity: String {
        if let last = session.messages.last, last.role == .tool {
            return last.text
        }
        return "Waiting for response"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 16 * s))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, 2)
            Text("Ask anything.")
                .font(.system(size: 12.5 * s))
                .foregroundStyle(.white.opacity(0.55))
            Text("⌥Space toggle · Esc close")
                .font(.system(size: 10 * s))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private func usageLimitScreen(_ notice: ProviderLimitNotice) -> some View {
        VStack(spacing: 11 * s) {
            Image(systemName: notice.kind == .uploads ? "tray.full.fill" : "hourglass.circle.fill")
                .font(.system(size: 24 * s, weight: .medium))
                .foregroundStyle(notice.kind == .uploads ? AnyShapeStyle(accent) : AnyShapeStyle(amber))
            Text(notice.title)
                .font(.system(size: 14 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
            Text(notice.message)
                .font(.system(size: 11.5 * s))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = notice.providerDetail {
                Text(detail)
                    .font(.system(size: 10 * s))
                    .foregroundStyle(.white.opacity(0.38))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            HStack(spacing: 8 * s) {
                Button("Dismiss") { session.usageLimit = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10 * s)
                    .padding(.vertical, 6 * s)

                if notice.kind == .uploads {
                    Button {
                        session.usageLimit = nil
                        // The blocked files were restored to the composer on
                        // rollback; continuing without them means dropping them.
                        session.attachments.removeAll()
                        inputFocused = true
                    } label: {
                        Text("Continue without files")
                            .font(.system(size: 11 * s, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12 * s)
                            .padding(.vertical, 6 * s)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)
                } else {
                    Menu {
                        ForEach(AgentProvider.allCases.filter { $0 != notice.provider }) { provider in
                            Button(provider.label) { session.provider = provider }
                        }
                    } label: {
                        Text("Switch provider")
                            .font(.system(size: 11 * s, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12 * s)
                            .padding(.vertical, 6 * s)
                            .background(Capsule().fill(amber))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
            }
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 20 * s)
        .frame(maxWidth: 330 * s)
        .background(
            RoundedRectangle(cornerRadius: 18 * s)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18 * s)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .padding(18 * s)
    }

    private let amber = Color(red: 232/255, green: 182/255, blue: 76/255)

    // Frosted glass normally: the material blurs what's behind the window
    // and a dark wash keeps it near-opaque. On the clear pane that opacity
    // defeats the whole material, so the composer goes genuinely clear.
    // Outside stealth, a hairline rim keeps its bounds readable. The chat is
    // masked to stop above the composer, so no text shows through it either way.
    @ViewBuilder private var composerBackdrop: some View {
        let shape = RoundedRectangle(cornerRadius: Self.composerRadius)
        if state.panelStyle == .clear {
            shape.fill(session.pendingPermission != nil
                       ? AnyShapeStyle(amber.opacity(0.06))
                       : AnyShapeStyle(Color.white.opacity(0.04)))
                .overlay {
                    if !state.stealthMode {
                        shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    }
                }
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.fill(Color(red: 0.09, green: 0.09, blue: 0.10).opacity(0.55)))
                .overlay(shape.fill(session.pendingPermission != nil
                                    ? AnyShapeStyle(amber.opacity(0.06))
                                    : AnyShapeStyle(Color.white.opacity(0.08))))
        }
    }

    private var composer: some View {
        Group {
            if let request = session.pendingPermission {
                permissionComposer(request)
            } else {
                standardComposer
            }
        }
        .padding(.horizontal, 11 * s)
        .padding(.top, 9 * s)
        .padding(.bottom, 8 * s)
        .background(composerBackdrop)
        .overlay {
            // Amber while an approval is pending.
            if session.pendingPermission != nil && !state.stealthMode {
                RoundedRectangle(cornerRadius: Self.composerRadius)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
        .padding(.horizontal, Self.composerMargin + state.notchTopRadius)
        .padding(.top, 4 * s)
        .padding(.bottom, Self.composerMargin)
    }

    // Concentric corners: for the composer's arc to follow the panel's, the
    // visible gap to the panel edge must be uniform and the inner radius
    // must be outer radius minus that gap (24 − 12 = 12), not the same
    // radius. NotchShape draws its straight sides notchTopRadius inside the
    // layout bounds (the top flare needs the full rect width), so the
    // horizontal padding adds that inset back; the bottom edge isn't inset.
    // Unscaled so the geometry holds in stealth, where the panel radius
    // doesn't shrink either.
    private static let composerMargin: CGFloat = 12
    private static let composerRadius: CGFloat = 12

    private var standardComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                attachmentChips
            }
            TextField("Ask anything…", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13 * s))
                .foregroundStyle(.white)
                .tint(accent)
                .focused($inputFocused)
                .onSubmit(sendDraft)
            HStack(spacing: 6) {
                attachButton
                contextMenus
                stealthEyeButton
                Spacer(minLength: 4)
                sendButton
            }
        }
    }

    // Eye next to the model/permissions chip: enters stealth from normal
    // mode, exits it from stealth (where this composer row is the only
    // always-reachable control).
    private var stealthEyeButton: some View {
        Button { state.toggleStealth() } label: {
            Image(systemName: state.stealthMode ? "eye" : "eye.slash")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help(state.stealthMode
              ? "Exit stealth mode"
              : "Stealth mode — silent notch, dim notch-width panel")
    }

    // P4 "composer morph": the composer becomes the approval while the agent
    // waits. Deny left; Always + Allow (Return) right. Esc denies.
    private func permissionComposer(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 11 * s))
                    .foregroundStyle(amber)
                Text(request.title)
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundStyle(Color(red: 240/255, green: 224/255, blue: 192/255))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 11 * s, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            }
            HStack(spacing: 6) {
                Button {
                    session.respondPermission(.deny)
                } label: {
                    Text("Deny")
                        .font(.system(size: 11.5 * s, weight: .semibold))
                        .foregroundStyle(Color(red: 224/255, green: 122/255, blue: 106/255))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: 4)
                if request.canAlways {
                    Button {
                        session.respondPermission(.always)
                    } label: {
                        Text("Always")
                            .font(.system(size: 11.5 * s, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.vertical, 5)
                            .padding(.horizontal, 11)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    session.respondPermission(.allow)
                } label: {
                    HStack(spacing: 4) {
                        Text("Allow")
                        Image(systemName: "return")
                            .font(.system(size: 9 * s, weight: .bold))
                    }
                    .font(.system(size: 11.5 * s, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 11)
                    .background(Capsule().fill(amber))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Q2 "docked sheet": the model's question slides in between the chat and
    // the composer, one question at a time. Single-select answers on click;
    // multi-select collects checkmarks behind an Answer button. The text
    // field takes a custom answer either way.
    @ViewBuilder
    private var questionSheet: some View {
        if let request = session.pendingQuestion {
            questionSheetContent(request)
        }
    }

    private func questionSheetContent(_ request: QuestionRequest) -> some View {
        let question = request.current
        return VStack(alignment: .leading, spacing: 8) {
            questionHeader(request, question)
            // Fits naturally when short; once the question + options are taller
            // than the room available, the body scrolls in place like the chat
            // history above it. Header and answer field stay pinned.
            ViewThatFits(in: .vertical) {
                questionBody(question)
                ScrollView(showsIndicators: false) { questionBody(question) }.frame(maxHeight: 260)
            }
            questionFooter(question)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        )
        // Same side-inset correction as the composer: NotchShape's straight
        // sides sit notchTopRadius inside the layout bounds.
        .padding(.horizontal, 10 + state.notchTopRadius)
        .padding(.bottom, 6)
    }

    // The scrollable portion of the question sheet: the prompt text and the
    // option rows. Pulled out so ViewThatFits can render it either plainly or
    // wrapped in a ScrollView.
    private func questionBody(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.system(size: 12.5 * s))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(question.options) { option in
                    questionOptionRow(option, multiSelect: question.multiSelect)
                }
            }
        }
    }

    private func questionHeader(_ request: QuestionRequest, _ question: AgentQuestion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 11 * s))
                .foregroundStyle(accent)
            Text(question.header)
                .font(.system(size: 10 * s, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Spacer()
            if request.questions.count > 1 {
                Text("\(request.index + 1) of \(request.questions.count)")
                    .font(.system(size: 10 * s))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private func questionOptionRow(_ option: AgentQuestionOption, multiSelect: Bool) -> some View {
        let selected = session.questionSelection.contains(option.label)
        let icon = multiSelect ? (selected ? "checkmark.square.fill" : "square") : "circle"
        return Button {
            if multiSelect {
                if selected {
                    session.questionSelection.remove(option.label)
                } else {
                    session.questionSelection.insert(option.label)
                }
            } else {
                session.answerQuestion(option.label)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11 * s))
                    .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.4)))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12 * s))
                        .foregroundStyle(.white.opacity(0.88))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10 * s))
                            .foregroundStyle(.white.opacity(0.42))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func questionFooter(_ question: AgentQuestion) -> some View {
        HStack(spacing: 6) {
            TextField("Something else…", text: $session.questionDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5 * s))
                .foregroundStyle(.white)
                .tint(accent)
                .onSubmit {
                    let custom = session.questionDraft.trimmingCharacters(in: .whitespaces)
                    if !custom.isEmpty { session.answerQuestion(custom) }
                }
            if question.multiSelect {
                Button {
                    // Keep the option order stable regardless of click order.
                    var parts = question.options.map(\.label)
                        .filter(session.questionSelection.contains)
                    let custom = session.questionDraft.trimmingCharacters(in: .whitespaces)
                    if !custom.isEmpty { parts.append(custom) }
                    session.answerQuestion(parts.joined(separator: ", "))
                } label: {
                    Text("Answer")
                        .font(.system(size: 11.5 * s, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
                .disabled(session.questionSelection.isEmpty
                          && session.questionDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(session.attachments.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 4) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: ["jpg", "jpeg", "png", "gif", "heic", "tiff", "webp"]
                                    .contains(url.pathExtension.lowercased()) ? "photo.fill" : "doc.fill")
                                    .font(.system(size: 9 * s))
                                    .fixedSize()
                                Text(url.lastPathComponent)
                                    .font(.system(size: 10.5 * s))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 145 * s, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(url.path)")
                        .contextMenu {
                            Button("Open") { NSWorkspace.shared.open(url) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }
                        Button {
                            session.attachments.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10 * s))
                                .foregroundStyle(.white.opacity(0.5))
                                .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .layoutPriority(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
    }

    private var attachButton: some View {
        Menu {
            Button("Choose Files…", action: pickFiles)
            Divider()
            Button("Screenshot: Full Screen") {
                ScreenshotCapture.capture(.fullScreen, state: state)
            }
            Button("Screenshot: Active App Window") {
                ScreenshotCapture.capture(.activeAppWindow, state: state)
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12 * s))
                .foregroundStyle(.white.opacity(0.6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach files or a screenshot")
        .disabled(session.isRunning)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // Our panel sits at .statusBar level, above the open dialog, so hide it
        // while the chooser is up and bring it back once a file is picked.
        state.suspendCollapse = true
        state.chatPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        state.suspendCollapse = false
        state.chatPanel?.makeKeyAndOrderFront(nil)
        if response == .OK {
            session.addAttachments(panel.urls)
        }
    }

    // Session context controls: model, effort, and permissions live in one
    // dropdown as submenus; the working folder gets its own dropdown so it
    // can truncate independently instead of fighting the session pill for
    // row width. Picking a model also switches provider; the ChatGPT provider
    // exposes a single Web entry and has no CLI options, so the folder
    // dropdown hides.
    // Stealth locks the panel to notch width, so the folder pill hides and
    // the folder submenu moves inside the session menu instead.
    @ViewBuilder
    private var contextMenus: some View {
        sessionMenu
        if session.provider.hasCLIOptions && !state.stealthMode {
            folderMenu
        }
    }

    private var sessionMenu: some View {
        contextMenu(help: sessionMenuHelp) {
            Menu("Model") {
                ForEach(AgentProvider.allCases) { provider in
                    Menu(provider.label) {
                        let groups = session.modelMenuGroups(for: provider)
                        if groups.isEmpty {
                            menuItem("Web", checked: session.provider == provider) {
                                session.provider = provider
                            }
                            if provider == .chatgpt {
                                Divider()
                                switch chatgptWeb.accountStatus {
                                case .checking:
                                    Button("Checking account…") {}
                                        .disabled(true)
                                    Button("Open Account…") {
                                        session.provider = .chatgpt
                                        chatgptWeb.showAccountWindow()
                                    }
                                case .signedOut:
                                    Button("Not signed in") {}
                                        .disabled(true)
                                    Button("Sign In…") {
                                        session.provider = .chatgpt
                                        chatgptWeb.showAccountWindow()
                                    }
                                case .signedIn(let email):
                                    Button(email ?? "Logged in") {}
                                        .disabled(true)
                                    Button("Change…") {
                                        session.provider = .chatgpt
                                        chatgptWeb.showAccountWindow()
                                    }
                                }
                            }
                        } else {
                            ForEach(groups) { group in
                                modelMenuGroup(group, provider: provider)
                            }
                            let otherGroups = session.otherModelMenuGroups(for: provider)
                            if !otherGroups.isEmpty {
                                Menu("Other") {
                                    ForEach(otherGroups) { group in
                                        modelMenuGroup(group, provider: provider)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if session.provider.hasCLIOptions {
                let efforts = session.efforts(for: session.provider)
                if !efforts.isEmpty {
                    Menu(session.effortMenuLabel(for: session.provider)) {
                        ForEach(efforts) { effort in
                            menuItem(effort.label, checked: currentEffort?.id == effort.id) {
                                session.effortChoice[session.provider] = effort.value
                            }
                        }
                    }
                }
                let speedVersions = session.speedVersions(for: session.provider)
                let contextVersions = session.contextVersions(for: session.provider)
                if !speedVersions.isEmpty || !contextVersions.isEmpty {
                    Menu("Version") {
                        ForEach(speedVersions) { version in
                            menuItem(
                                version.label,
                                checked: session.effectiveSpeedVersion(for: session.provider)
                                    == version.value
                            ) {
                                if let value = version.value {
                                    session.setSpeedVersion(value, for: session.provider)
                                }
                            }
                        }
                        if !speedVersions.isEmpty && !contextVersions.isEmpty {
                            Divider()
                        }
                        ForEach(contextVersions) { version in
                            menuItem(
                                version.label,
                                checked: session.effectiveContextVersion(for: session.provider)
                                    == version.value
                            ) {
                                if let value = version.value {
                                    session.setContextVersion(value, for: session.provider)
                                }
                            }
                        }
                    }
                }
                Menu("Permissions") {
                    ForEach(session.provider.permissionModes) { mode in
                        menuItem(mode.label, checked: session.modeChoice[session.provider] == mode.value) {
                            session.modeChoice[session.provider] = mode.value
                        }
                    }
                }
                if state.stealthMode {
                    Menu("Folder") {
                        Button("Choose Folder…", action: pickFolder)
                        Divider()
                        Text(session.workingDirectory.path)
                    }
                }
            }
        } label: {
            menuPill(sessionPillText)
        }
    }

    private func modelMenuItem(
        _ variant: AgentModelVariant, provider: AgentProvider, title: String
    ) -> some View {
        menuItem(
            title,
            checked: session.provider == provider
                && session.modelChoice[provider] == variant.option.value
        ) {
            session.provider = provider
            session.modelChoice[provider] = variant.option.value
        }
    }

    @ViewBuilder
    private func modelMenuGroup(
        _ group: AgentModelMenuGroup, provider: AgentProvider
    ) -> some View {
        if group.variants.count == 1, let variant = group.variants.first {
            modelMenuItem(variant, provider: provider, title: group.label)
        } else {
            Menu(group.label) {
                ForEach(group.variants) { variant in
                    modelMenuItem(variant, provider: provider, title: variant.label)
                }
            }
        }
    }

    // "Sonnet 5 · High"; just "ChatGPT" for the web provider. Permissions
    // only show inside the menu (and the tooltip), not on the pill. Stealth
    // collapses the pill to the bare model name — the row has no room for
    // more there.
    private var sessionPillText: String {
        guard session.provider.hasCLIOptions else { return session.provider.label }
        guard !state.stealthMode else { return modelPillText }
        var parts = [modelPillText]
        if let effort = currentEffort { parts.append(effort.short) }
        if let version = currentVersion { parts.append(version.short) }
        return parts.joined(separator: " · ")
    }

    private var sessionMenuHelp: String {
        guard session.provider.hasCLIOptions else { return session.provider.label }
        let effortLabel = session.effortMenuLabel(for: session.provider)
        let effort = currentEffort.map { " · \(effortLabel): \($0.label)" } ?? ""
        let version = currentVersion.map { " · Version: \($0.label)" } ?? ""
        return "Model: \(modelPillText)\(effort)\(version) · Permissions: \(currentMode.label)"
    }

    private var folderMenu: some View {
        contextMenu(help: "Folder: \(session.workingDirectory.path)") {
            Button("Choose Folder…", action: pickFolder)
            Divider()
            Text(session.workingDirectory.path)
        } label: {
            menuPill(session.workingDirectory.lastPathComponent)
        }
    }

    // Shared dropdown chrome: plain-styled system Menu, hidden indicator,
    // disabled mid-turn like the rest of the session controls. No fixedSize:
    // it would force the label's full ideal width, and on a narrow panel the
    // row then overflows its padding and the composer box swallows its own
    // margins. Without it the labels compress and truncate instead.
    private func contextMenu(
        help: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Menu(content: content, label: label)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(session.isRunning)
            .help(help)
    }

    private func menuItem(
        _ title: String, checked: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // The checked effort item and the pill's effort segment. An unset (or
    // unsupported-for-this-model) effortChoice shows the stop the CLI
    // defaults to without sending a flag.
    private var currentEffort: AgentOption? {
        let efforts = session.efforts(for: session.provider)
        guard !efforts.isEmpty else { return nil }
        if let value = session.effectiveEffort(for: session.provider),
           let match = efforts.first(where: { $0.value == value }) {
            return match
        }
        return efforts.first { $0.value == session.defaultEffortValue(for: session.provider) }
            ?? efforts.first
    }

    private var currentVersion: AgentOption? {
        let versions = session.contextVersions(for: session.provider)
        guard let value = session.effectiveContextVersion(for: session.provider) else { return nil }
        return versions.first { $0.value == value }
    }

    // A chosen model replaces the provider name ("Sonnet 5" instead of
    // "Claude"); ChatGPT has no models, so it keeps the provider name.
    private var modelPillText: String {
        let provider = session.provider
        guard let value = session.modelChoice[provider],
              let model = session.models(for: provider).first(where: { $0.value == value })
        else { return provider.label }
        let fastSuffix = session.effectiveFastMode(for: provider) ? " Fast" : ""
        return model.short + fastSuffix
    }

    private var currentMode: AgentOption {
        let provider = session.provider
        let modes = provider.permissionModes
        return modes.first { $0.value == session.modeChoice[provider] }
            ?? modes.first
            ?? AgentOption(label: "Default", short: "Default", value: nil)
    }

    // The HStack proposes the available composer width, so long labels still
    // truncate while short labels keep their natural width beside the icon.
    private func menuPill(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 11 * s, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 6.5 * s, weight: .semibold))
                .opacity(0.55)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 4 * s)
        .padding(.vertical, 4 * s)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isRunning {
            Button(action: session.cancel) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20 * s))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: sendDraft) {
                // No accent: plain white that the panel's theme treatment
                // (grey colorMultiply on glass, stealth desaturation) tints
                // appropriately. Dim until there's something to send.
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20 * s))
                    .foregroundStyle(.white.opacity(session.draft.isEmpty ? 0.25 : 0.85))
            }
            .buttonStyle(.plain)
            .disabled(session.draft.isEmpty)
        }
    }

    private func sendDraft() {
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isRunning else { return }
        session.draft = ""
        session.send(text)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.workingDirectory
        // Our panel sits at .statusBar level, above the open dialog, so hide it
        // while the chooser is up and bring it back once a folder is picked.
        state.suspendCollapse = true
        state.chatPanel?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        state.suspendCollapse = false
        state.chatPanel?.makeKeyAndOrderFront(nil)
        if response == .OK, let url = panel.url {
            session.workingDirectory = url
        }
    }
}

// Collapsed run of tool activity: "N steps" row that expands in place.
struct StepsGroup: View {
    let steps: [ChatMessage]
    var scale: CGFloat = 1
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8 * scale, weight: .semibold))
                    Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                        .font(.system(size: 11 * scale))
                }
                .foregroundStyle(.white.opacity(0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        MessageBubble(message: step, scale: scale)
                    }
                }
                .padding(.leading, 14 * scale)
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var scale: CGFloat = 1

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .leading, spacing: 7 * scale) {
                    if !message.displayText.isEmpty {
                        Text(message.displayText)
                            .font(.system(size: 13 * scale))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(message.attachmentURLs.enumerated()), id: \.offset) { _, url in
                        MessageAttachmentButton(url: url, scale: scale)
                    }
                }
                    .padding(.horizontal, 11 * scale)
                    .padding(.vertical, 7 * scale)
                    .background(RoundedRectangle(cornerRadius: 15 * scale).fill(Color.white.opacity(0.14)))
            }
        case .assistant:
            MarkdownView(text: message.text, scale: scale)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 5) {
                Image(systemName: message.icon ?? "wrench.fill")
                    .font(.system(size: 9 * scale))
                    .frame(width: 12 * scale)
                Text(message.text)
                    .font(.system(size: 11 * scale))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.45))
        case .error:
            Text(message.text)
                .font(.system(size: 12 * scale, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                .textSelection(.enabled)
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 7 * scale)
                .background(RoundedRectangle(cornerRadius: 12 * scale).fill(Color(red: 1, green: 0.3, blue: 0.3).opacity(0.12)))
        }
    }
}

struct MessageAttachmentButton: View {
    let url: URL
    var scale: CGFloat = 1

    private var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp"]
            .contains(url.pathExtension.lowercased())
    }

    var body: some View {
        Button {
            guard exists else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: isImage ? "photo.fill" : "doc.fill")
                    .font(.system(size: 10 * scale))
                    .fixedSize()
                Text(url.lastPathComponent)
                    .font(.system(size: 10.5 * scale, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 175 * scale, alignment: .leading)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 8.5 * scale))
                    .fixedSize()
                    .layoutPriority(1)
            }
            .foregroundStyle(exists ? Color.white.opacity(0.82) : Color.white.opacity(0.35))
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 5 * scale)
            .background(Capsule().fill(Color.black.opacity(0.26)))
        }
        .buttonStyle(.plain)
        .help(exists ? "Open \(url.path)" : "File no longer exists: \(url.path)")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
                .disabled(!exists)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!exists)
        }
    }
}

// Settings surface shown in its own window, opened from the panel's gear
// button and the menu-bar item. A standalone view (not a popover) so both
// entry points can present it and it survives the panel collapsing.
struct SettingsView: View {
    @ObservedObject var state: AppState

    private var styleCaption: String {
        switch state.notchStyle {
        case .standard: return "Live activity text and buttons around the notch"
        case .compact: return "A hairline sliver under the notch — color shows what's happening"
        case .stealth: return "Silent while working; dim notch-width panel — Clear material makes it glass"
        }
    }

    private var materialCaption: String {
        switch state.panelStyle {
        case .black: return "Solid black — the panel hides what's behind it"
        case .smoke: return "Dark frosted glass — smoked blur of what's behind"
        case .clear: return "Clear pane — the panel shows what's behind it"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle")
                Text("NotchAgent").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("v0.1").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Toggle panel")
                Spacer()
                Text("⌥ Space").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))

            HStack {
                Text("Close panel")
                Spacer()
                Text("Esc").foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))

            Toggle(isOn: $state.pinned) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep panel pinned").font(.system(size: 12.5))
                    Text("Stay open while using other apps")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("Notch activity").font(.system(size: 12.5))
                Picker("Notch activity", selection: $state.notchStyle) {
                    Text("Standard").tag(AppState.NotchStyle.standard)
                    Text("Compact").tag(AppState.NotchStyle.compact)
                    Text("Stealth").tag(AppState.NotchStyle.stealth)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(styleCaption)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Panel material").font(.system(size: 12.5))
                Picker("Panel material", selection: $state.panelStyle) {
                    Text("Black").tag(AppState.PanelStyle.black)
                    Text("Smoke").tag(AppState.PanelStyle.smoke)
                    Text("Clear").tag(AppState.PanelStyle.clear)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(materialCaption)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Hover the notch or press ⌥Space to open.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

// Lightweight LaTeX-to-Unicode so model math reads properly without a
// typesetting engine (this build has no package deps). It finds math spans
// ($…$, $$…$$, \(…\), \[…\]) and rewrites the common constructs — \frac,
// \sqrt, super/subscripts, greek letters, operators — into Unicode. It is not
// a real typesetter: anything it can't map degrades to linear text rather than
// showing raw backslashes.
enum MathText {
    static func render(_ raw: String) -> String {
        guard raw.contains("$") || raw.contains("\\(") || raw.contains("\\[") else { return raw }
        return convertDelimited(raw)
    }

    // Walk the string, converting the inside of each math span and leaving the
    // surrounding prose untouched. An unclosed delimiter is treated as literal.
    private static func convertDelimited(_ s: String) -> String {
        let c = Array(s)
        let n = c.count
        var out = ""
        var i = 0
        func span(_ open: [Character], _ close: [Character], _ from: Int) -> (String, Int)? {
            guard from + open.count <= n else { return nil }
            for k in 0..<open.count where c[from + k] != open[k] { return nil }
            var j = from + open.count
            var inner = ""
            while j < n {
                if j + close.count <= n {
                    var hit = true
                    for k in 0..<close.count where c[j + k] != close[k] { hit = false; break }
                    if hit { return (inner, j + close.count) }
                }
                inner.append(c[j]); j += 1
            }
            return nil
        }
        while i < n {
            if let m = span(["$", "$"], ["$", "$"], i) { out += convertMath(m.0); i = m.1; continue }
            if let m = span(["\\", "["], ["\\", "]"], i) { out += convertMath(m.0); i = m.1; continue }
            if let m = span(["\\", "("], ["\\", ")"], i) { out += convertMath(m.0); i = m.1; continue }
            if c[i] == "$", let m = span(["$"], ["$"], i) { out += convertMath(m.0); i = m.1; continue }
            out.append(c[i]); i += 1
        }
        return out
    }

    private static func convertMath(_ math: String) -> String {
        var s = math
        s = s.replacingOccurrences(of: "\\\\", with: "\n")
        for junk in ["\\left", "\\right", "\\,", "\\;", "\\!", "\\:", "\\displaystyle"] {
            s = s.replacingOccurrences(of: junk, with: "")
        }
        for space in ["\\quad", "\\qquad"] { s = s.replacingOccurrences(of: space, with: " ") }
        s = stripWrappers(s, ["text", "mathrm", "mathbf", "mathit", "mathsf", "operatorname",
                              "boldsymbol", "vec", "hat", "bar", "dot", "tilde", "overline", "underline"])
        s = loop(s, replaceFrac)
        s = loop(s, replaceSqrt)
        s = replaceCommands(s)
        s = replaceScripts(s)
        return s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    }

    // Re-run a pass until it stops changing, so nested \frac{\frac…} resolve.
    private static func loop(_ s: String, _ f: (String) -> String) -> String {
        var cur = s
        for _ in 0..<8 { let next = f(cur); if next == cur { break }; cur = next }
        return cur
    }

    private static func matches(_ c: [Character], _ i: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard i + t.count <= c.count else { return false }
        for k in 0..<t.count where c[i + k] != t[k] { return false }
        return true
    }

    private static func readBrace(_ c: [Character], _ start: Int) -> (String, Int)? {
        guard start < c.count, c[start] == "{" else { return nil }
        var depth = 0, j = start
        var inner = ""
        while j < c.count {
            let ch = c[j]
            if ch == "{" { depth += 1; if depth == 1 { j += 1; continue } }
            else if ch == "}" { depth -= 1; if depth == 0 { return (inner, j + 1) } }
            inner.append(ch); j += 1
        }
        return nil
    }

    private static func skipSpaces(_ c: [Character], _ i: Int) -> Int {
        var j = i; while j < c.count, c[j] == " " { j += 1 }; return j
    }

    private static func needsParens(_ s: String) -> Bool {
        s.count > 1 && s.contains(where: { "+-*/ ".contains($0) })
    }
    private static func wrap(_ s: String) -> String { needsParens(s) ? "(\(s))" : s }

    private static func replaceFrac(_ s: String) -> String {
        let c = Array(s)
        var out = "", i = 0
        while i < c.count {
            if matches(c, i, "\\frac") {
                let a = readBrace(c, skipSpaces(c, i + 5))
                if let g1 = a, let g2 = readBrace(c, skipSpaces(c, g1.1)) {
                    out += wrap(g1.0) + "/" + wrap(g2.0)
                    i = g2.1
                    continue
                }
            }
            out.append(c[i]); i += 1
        }
        return out
    }

    private static func replaceSqrt(_ s: String) -> String {
        let c = Array(s)
        var out = "", i = 0
        while i < c.count {
            if matches(c, i, "\\sqrt") {
                var j = skipSpaces(c, i + 5)
                // drop an optional [n] root index
                if j < c.count, c[j] == "[" { while j < c.count, c[j] != "]" { j += 1 }; if j < c.count { j += 1 } }
                if let g = readBrace(c, skipSpaces(c, j)) {
                    out += "√" + wrap(g.0)
                    i = g.1
                    continue
                }
            }
            out.append(c[i]); i += 1
        }
        return out
    }

    private static func stripWrappers(_ s: String, _ cmds: [String]) -> String {
        return loop(s) { input in
            let c = Array(input)
            var out = "", i = 0
            while i < c.count {
                var hit = false
                for cmd in cmds where matches(c, i, "\\" + cmd) {
                    if let g = readBrace(c, skipSpaces(c, i + cmd.count + 1)) {
                        out += g.0; i = g.1; hit = true; break
                    }
                }
                if hit { continue }
                out.append(c[i]); i += 1
            }
            return out
        }
    }

    // \command -> symbol; unknown commands drop the backslash and keep the name.
    private static func replaceCommands(_ s: String) -> String {
        let c = Array(s)
        var out = "", i = 0
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count, c[i + 1].isLetter {
                var j = i + 1
                var name = ""
                while j < c.count, c[j].isLetter { name.append(c[j]); j += 1 }
                out += symbols[name] ?? name
                i = j
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    private static func replaceScripts(_ s: String) -> String {
        let c = Array(s)
        var out = "", i = 0
        while i < c.count {
            if c[i] == "^" || c[i] == "_" {
                let sup = c[i] == "^"
                var content = "", j = i + 1
                if let g = readBrace(c, j) { content = g.0; j = g.1 }
                else if j < c.count { content = String(c[j]); j += 1 }
                out += mapScript(content, sup: sup)
                i = j
            } else {
                out.append(c[i]); i += 1
            }
        }
        return out
    }

    private static func mapScript(_ content: String, sup: Bool) -> String {
        let map = sup ? superscripts : subscripts
        var mapped = ""
        for ch in content {
            guard let u = map[ch] else {
                let body = content.count > 1 ? "(\(content))" : content
                return (sup ? "^" : "_") + body
            }
            mapped.append(u)
        }
        return mapped
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ",
    ]
    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "h": "ₕ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ",
        "p": "ₚ", "s": "ₛ", "t": "ₜ", "i": "ᵢ", "j": "ⱼ", "r": "ᵣ", "u": "ᵤ", "v": "ᵥ",
    ]
    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈",
        "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮",
        "to": "→", "rightarrow": "→", "Rightarrow": "⇒", "leftarrow": "←", "Leftarrow": "⇐",
        "leftrightarrow": "↔", "mapsto": "↦", "implies": "⟹", "iff": "⟺",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "forall": "∀", "exists": "∃", "nexists": "∄",
        "emptyset": "∅", "varnothing": "∅", "ldots": "…", "cdots": "⋯", "vdots": "⋮", "dots": "…",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "langle": "⟨", "rangle": "⟩",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "deg": "°", "circ": "∘",
        "prime": "′", "wedge": "∧", "vee": "∨", "oplus": "⊕", "otimes": "⊗",
        "sqrt": "√", "surd": "√", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "quad": " ", "qquad": " ",
    ]
}
