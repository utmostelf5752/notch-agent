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

// Rectangle with rounded bottom corners only — the notch silhouette.
struct NotchShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        p.closeSubpath()
        return p
    }
}

// The always-on click target drawn over the physical notch.
// Hover state lives on AppState (mouse poll) because SwiftUI onHover is
// unreliable on a window that can never become key.
struct NotchTargetView: View {
    @ObservedObject var state: AppState

    var body: some View {
        NotchShape(radius: 8)
            .fill(Color.black)
            .overlay(alignment: .bottom) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(state.notchHovering ? 0.85 : 0))
                    .padding(.bottom, 3)
                    .animation(.easeOut(duration: 0.15), value: state.notchHovering)
            }
            .contentShape(Rectangle())
            .onTapGesture { state.expand(takeKeyboard: true) }
            // Dragging a file onto the notch attaches it and opens the panel.
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                let accepted = acceptDroppedFiles(providers)
                if accepted { state.expand(takeKeyboard: true) }
                return accepted
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
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchShape(radius: cornerRadius).fill(Color.black))
        .clipShape(NotchShape(radius: cornerRadius))
        .overlay(alignment: .top) { topStrip }
        .overlay {
            if state.dropTargeted {
                NotchShape(radius: cornerRadius)
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
        // Reveal, not movement: the content is laid out in place and a
        // top-anchored mask wipes downward over it, so the panel appears to
        // be uncovered rather than to slide.
        .mask {
            GeometryReader { geo in
                NotchShape(radius: cornerRadius)
                    .frame(height: state.expanded ? geo.size.height : 0)
            }
        }
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
        Button { state.showSettings.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help("Settings")
        .popover(isPresented: $state.showSettings, arrowEdge: .bottom) {
            settingsView
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $session.autoEdit) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-edit")
                        .font(.system(size: 12))
                    Text("Let the agent change files without asking")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            HStack {
                Text("Toggle panel")
                    .font(.system(size: 12))
                Spacer()
                Text("⌥ Space")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Quit NotchAgent") { NSApp.terminate(nil) }
                .font(.system(size: 12))
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 240)
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

    private var composer: some View {
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
                providerMenu
                if session.provider != .chatgpt {
                    folderMenu
                }
                Spacer(minLength: 4)
                sendButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
        // Hold the panel open while the Finder dialog has focus.
        state.suspendCollapse = true
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        state.suspendCollapse = false
        state.chatPanel?.makeKeyAndOrderFront(nil)
        if response == .OK {
            session.attachments.append(contentsOf: panel.urls)
        }
    }

    private var providerMenu: some View {
        Menu {
            ForEach(AgentProvider.allCases) { provider in
                Button {
                    session.provider = provider
                } label: {
                    if provider == session.provider {
                        Label(provider.label, systemImage: "checkmark")
                    } else {
                        Text(provider.label)
                    }
                }
            }
        } label: {
            pill(session.provider.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.isRunning)
    }

    private var folderMenu: some View {
        Menu {
            Button("Choose Folder…", action: pickFolder)
            Divider()
            Text(session.workingDirectory.path)
        } label: {
            pill(session.workingDirectory.lastPathComponent, icon: "folder")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(session.isRunning)
        .help("Working directory: \(session.workingDirectory.path)")
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
        state.suspendCollapse = true
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
            Text(message.text)
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
