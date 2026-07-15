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
                AppState.shared.session.attachments.append(url)
            }
        }
    }
    return accepted
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
            NotchShape(radius: radius, topRadius: state.notchTopRadius).fill(Color.black)
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

    private var radius: CGFloat {
        if state.notchStyle != .standard { return 8 }
        switch state.notchMode {
        case .idle: return 8
        case .working, .completed: return 12
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
        case .completed: compactSliver(green, sweepsFromCompletion: 3)
        }
    }

    // One sweep per second: a bright band travels the dim track left to right.
    // sweepsFromCompletion anchors time to the pill's start so done runs
    // exactly N sweeps; nil sweeps forever.
    private func compactSliver(_ color: Color, sweepsFromCompletion: Int? = nil) -> some View {
        TimelineView(.animation) { ctx in
            let t = sweepsFromCompletion != nil
                ? ctx.date.timeIntervalSince(state.completedStartedAt)
                : ctx.date.timeIntervalSinceReferenceDate
            let stopped = sweepsFromCompletion.map { t >= Double($0) } ?? false
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { state.expand(takeKeyboard: true) }
    }

    // MARK: Stealth — nothing at all while idle or working (no size change,
    // no animation); alerts and completion compress to a hairline sliver
    // hugging the notch's bottom edge. The whole area stays a click target.
    @ViewBuilder private var stealthContent: some View {
        switch state.notchMode {
        case .idle, .working:
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { state.expand(takeKeyboard: true) }
        case .completed:
            stealthSliver(green, pulsing: false)
        case .permission:
            stealthSliver(amber, pulsing: true)
        case .question:
            stealthSliver(questionBlue, pulsing: true)
        }
    }

    private func stealthSliver(_ color: Color, pulsing: Bool) -> some View {
        // Paused when not pulsing so the completed sliver costs no frames.
        TimelineView(.animation(minimumInterval: nil, paused: !pulsing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = pulsing ? (sin(t * 3.6) + 1) / 2 : 1
            Capsule()
                .fill(color)
                .frame(height: 2)
                .padding(.horizontal, 22)
                .opacity(0.25 + 0.65 * phase)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture { state.expand(takeKeyboard: true) }
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
    @FocusState private var inputFocused: Bool

    private let cornerRadius: CGFloat = 24
    private let accent = Color(red: 10/255, green: 132/255, blue: 1)

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: state.notchHeight + 2)
            messagesList
            questionSheet
            // A pending approval overrides the stealth hide — the composer is
            // where the Deny/Allow buttons live.
            if !state.stealthMode || state.stealthComposerOpen || session.pendingPermission != nil {
                composer
            }
        }
        .animation(.easeOut(duration: 0.2), value: state.stealthComposerOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Stealth dims every color in the panel toward black; the background
        // itself goes translucent near-black so it reads as a shadow layer.
        .opacity(state.stealthMode ? 0.6 : 1)
        .background(NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius).fill(panelBackground))
        .clipShape(NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius))
        .overlay(alignment: .top) { topStrip.opacity(state.stealthMode ? 0.4 : 1) }
        .overlay {
            if state.dropTargeted {
                NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius)
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 18))
                            Text("Drop to attach")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $state.dropTargeted) { providers in
            acceptDroppedFiles(providers)
        }
        // Width is locked to the notch in stealth, so no side handles there.
        .overlay(alignment: .leading) { if !state.stealthMode { sideResizeHandle(sign: -1) } }
        .overlay(alignment: .trailing) { if !state.stealthMode { sideResizeHandle(sign: 1) } }
        .overlay(alignment: .bottom) { bottomResizeHandle }
        // Reveal, not movement: the content is laid out in place and a
        // top-anchored mask wipes downward over it, so the panel appears to
        // be uncovered rather than to slide. Stealth skips the wipe and
        // fades in place instead — a layer over the UI, not an extension.
        .mask {
            GeometryReader { geo in
                NotchShape(radius: cornerRadius, topRadius: state.notchTopRadius)
                    .frame(height: state.expanded || state.stealthMode ? geo.size.height : 0)
            }
        }
        .opacity(state.stealthMode && !state.expanded ? 0 : 1)
        .padding(.horizontal, AppState.panelMargin)
        .padding(.bottom, AppState.panelBottomMargin)
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

    private var panelBackground: Color {
        state.stealthMode
            ? Color(red: 0.01, green: 0.01, blue: 0.02).opacity(0.94)
            : .black
    }

    // Edge-drag resizing. Width is symmetric (the panel stays centered on the
    // notch, so pulling one side grows both); height grows downward. Deltas
    // come from NSEvent.mouseLocation (screen coords) so the math stays
    // stable while the window frame changes mid-drag.
    private func sideResizeHandle(sign: CGFloat) -> some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
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

    private var bottomResizeHandle: some View {
        Color.clear
            .frame(height: 10)
            .frame(maxWidth: .infinity)
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Past chats")
        .popover(isPresented: $state.showHistory, arrowEdge: .bottom) {
            historyList
        }
    }

    private var historyList: some View {
        ScrollView {
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(state.pinned ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(state.pinned ? "Unpin — clicking elsewhere closes the panel" : "Pin — keep open while using other apps")
    }

    private var settingsButton: some View {
        Button { state.openSettings() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Settings")
    }

    private var newChatButton: some View {
        Button(action: session.reset) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .medium))
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(displayItems) { item in
                        switch item {
                        case .message(let message):
                            MessageBubble(message: message)
                                .id(item.id)
                        case .steps(let run):
                            StepsGroup(
                                steps: run,
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
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.top, 2)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
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
            .overlay {
                if session.messages.isEmpty && !session.isRunning {
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
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, 2)
            Text("Ask anything.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.55))
            Text("⌥Space toggle · Esc close")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    private let amber = Color(red: 232/255, green: 182/255, blue: 76/255)

    private var composer: some View {
        Group {
            if let request = session.pendingPermission {
                permissionComposer(request)
            } else {
                standardComposer
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(session.pendingPermission != nil
                      ? AnyShapeStyle(amber.opacity(0.06))
                      : AnyShapeStyle(Color.white.opacity(0.08)))
        )
        .overlay {
            // Amber while an approval is pending or a mode that skips
            // permission prompts is active.
            if session.pendingPermission != nil || currentMode.dangerous {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private var standardComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.attachments.isEmpty {
                attachmentChips
            }
            TextField("Ask anything…", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .tint(accent)
                .focused($inputFocused)
                .onSubmit(sendDraft)
            HStack(spacing: 6) {
                attachButton
                contextChip
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
                .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 11))
                    .foregroundStyle(amber)
                Text(request.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 240/255, green: 224/255, blue: 192/255))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 11.5, weight: .semibold))
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
                            .font(.system(size: 11.5, weight: .semibold))
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
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
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
                ScrollView { questionBody(question) }.frame(maxHeight: 260)
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
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // The scrollable portion of the question sheet: the prompt text and the
    // option rows. Pulled out so ViewThatFits can render it either plainly or
    // wrapped in a ScrollView.
    private func questionBody(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .font(.system(size: 12.5))
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
                .font(.system(size: 11))
                .foregroundStyle(accent)
            Text(question.header)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            Spacer()
            if request.questions.count > 1 {
                Text("\(request.index + 1) of \(request.questions.count)")
                    .font(.system(size: 10))
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
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.4)))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.88))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10))
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
                .font(.system(size: 11.5))
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
                        .font(.system(size: 11.5, weight: .semibold))
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
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                        Text(url.lastPathComponent)
                            .font(.system(size: 10.5))
                            .lineLimit(1)
                        Button {
                            session.attachments.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
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
            Button("Screenshot: Full Screen") { captureScreenshot(activeWindowOnly: false) }
            Button("Screenshot: Active App Window") { captureScreenshot(activeWindowOnly: true) }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach files or a screenshot")
        .disabled(session.isRunning)
    }

    // screencapture needs the Screen Recording permission on first use; macOS
    // prompts for it once. -x = no shutter sound.
    private func captureScreenshot(activeWindowOnly: Bool) {
        let path = "/tmp/notchagent-shot-\(Int(Date().timeIntervalSince1970)).png"
        var args = ["-x"]
        if activeWindowOnly, let windowID = Self.frontmostWindowID() {
            args += ["-l", String(windowID)]
        }
        args.append(path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                if FileManager.default.fileExists(atPath: path) {
                    AppState.shared.session.attachments.append(URL(fileURLWithPath: path))
                } else {
                    AppState.shared.session.messages.append(ChatMessage(
                        role: .error,
                        text: "Screenshot failed — grant Screen Recording permission to NotchAgent in System Settings > Privacy."
                    ))
                }
            }
        }
        try? process.run()
    }

    // First layer-0 window of the frontmost app. Our panel is non-activating,
    // so the frontmost app is whatever the user is actually working in.
    private static func frontmostWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? UInt32
            else { continue }
            return CGWindowID(number)
        }
        return nil
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
            session.attachments.append(contentsOf: panel.urls)
        }
    }

    // The whole session context — model, permission mode, working folder —
    // lives in one chip so the composer row stays two controls wide.
    // Claude and Codex expand into model submenus; picking a model also
    // switches to that provider. ChatGPT has no model choice, so it stays flat.
    private var contextChip: some View {
        Menu {
            Menu("Model") {
                ForEach(AgentProvider.allCases) { provider in
                    if provider.models.isEmpty {
                        Button {
                            session.provider = provider
                        } label: {
                            if provider == session.provider {
                                Label(provider.label, systemImage: "checkmark")
                            } else {
                                Text(provider.label)
                            }
                        }
                    } else {
                        Menu(provider.label) {
                            ForEach(provider.models) { model in
                                Button {
                                    session.provider = provider
                                    if let value = model.value {
                                        session.modelChoice[provider] = value
                                    } else {
                                        session.modelChoice.removeValue(forKey: provider)
                                    }
                                } label: {
                                    if session.modelChoice[provider] == model.value {
                                        Label(model.label, systemImage: "checkmark")
                                    } else {
                                        Text(model.label)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if session.provider.hasCLIOptions {
                Menu("Permissions") {
                    ForEach(session.provider.permissionModes) { mode in
                        Button {
                            if let value = mode.value {
                                session.modeChoice[session.provider] = value
                            } else {
                                session.modeChoice.removeValue(forKey: session.provider)
                            }
                        } label: {
                            if session.modeChoice[session.provider] == mode.value {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
                Menu("Folder") {
                    Button("Choose Folder…", action: pickFolder)
                    Divider()
                    Text(session.workingDirectory.path)
                }
            }
        } label: {
            pill(chipText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(session.isRunning)
        .help(chipHelp)
    }

    // "Sonnet 5 · Edits · notch-agent"; just "ChatGPT" for the web provider.
    private var chipText: String {
        guard session.provider.hasCLIOptions else { return session.provider.label }
        return "\(modelPillText) · \(currentMode.short) · \(session.workingDirectory.lastPathComponent)"
    }

    private var chipHelp: String {
        guard session.provider.hasCLIOptions else { return session.provider.label }
        return "Model: \(modelPillText) · Permissions: \(currentMode.label) · Folder: \(session.workingDirectory.path)"
    }

    // A chosen model replaces the provider name ("Sonnet 5" instead of
    // "Claude"); the provider name only shows on Default.
    private var modelPillText: String {
        let provider = session.provider
        guard let value = session.modelChoice[provider],
              let model = provider.models.first(where: { $0.value == value })
        else { return provider.label }
        return model.short
    }

    private var currentMode: AgentOption {
        let provider = session.provider
        let modes = provider.permissionModes
        return modes.first { $0.value == session.modeChoice[provider] }
            ?? modes.first
            ?? AgentOption(label: "Default", short: "Default", value: nil)
    }

    private func pill(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .opacity(0.6)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    @ViewBuilder
    private var sendButton: some View {
        if session.isRunning {
            Button(action: session.cancel) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: sendDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(session.draft.isEmpty
                        ? AnyShapeStyle(.white.opacity(0.25))
                        : AnyShapeStyle(accent))
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
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        MessageBubble(message: step)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color.white.opacity(0.14)))
            }
        case .assistant:
            Text(MathText.render(message.text))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            HStack(spacing: 5) {
                Image(systemName: message.icon ?? "wrench.fill")
                    .font(.system(size: 9))
                    .frame(width: 12)
                Text(message.text)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.45))
        case .error:
            Text(message.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 1, green: 0.3, blue: 0.3).opacity(0.12)))
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
        case .stealth: return "Silent while working; dim notch-width panel, composer on click"
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
