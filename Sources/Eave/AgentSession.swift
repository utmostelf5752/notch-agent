import AppKit
import Foundation
import UniformTypeIdentifiers

enum AppPaths {
    private static let applicationSupportRoot = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
    private static let legacySupportDirectory = applicationSupportRoot
        .appendingPathComponent("NotchAgent", isDirectory: true)

    static let supportDirectory: URL = {
        let directory = applicationSupportRoot.appendingPathComponent("Eave", isDirectory: true)
        migrateLegacySupportDirectory(to: directory)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }()

    static let screenshotsDirectory: URL = {
        let directory = supportDirectory.appendingPathComponent("Screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }()

    static let attachmentsDirectory: URL = {
        let directory = supportDirectory.appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }()

    static func existingScreenshot(named name: String) -> URL? {
        let candidates = [
            screenshotsDirectory.appendingPathComponent(name),
            URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func isScreenshotName(_ name: String) -> Bool {
        name.hasPrefix("eave-screenshot-") || name.hasPrefix("notchagent-screenshot-")
    }

    static func relocatedManagedURL(for url: URL) -> URL {
        let legacyPath = legacySupportDirectory.standardizedFileURL.path
        let sourcePath = url.standardizedFileURL.path
        guard sourcePath == legacyPath || sourcePath.hasPrefix(legacyPath + "/") else {
            return url
        }
        let relativePath = String(sourcePath.dropFirst(legacyPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relocated = supportDirectory.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: relocated.path) ? relocated : url
    }

    static func migrateLegacyScreenshots() {
        let manager = FileManager.default
        let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard let files = try? manager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for source in files where isScreenshotName(source.lastPathComponent) {
            let destination = screenshotsDirectory.appendingPathComponent(source.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.moveItem(at: source, to: destination)
        }
    }

    private static func migrateLegacySupportDirectory(to destination: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: legacySupportDirectory.path) else { return }

        if !manager.fileExists(atPath: destination.path) {
            do {
                try manager.moveItem(at: legacySupportDirectory, to: destination)
                return
            } catch {
                NSLog("Eave: could not move legacy data directory: \(error.localizedDescription)")
            }
        }

        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        mergeMissingItems(from: legacySupportDirectory, into: destination, manager: manager)
    }

    private static func mergeMissingItems(
        from source: URL,
        into destination: URL,
        manager: FileManager
    ) {
        guard let items = try? manager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory, manager.fileExists(atPath: target.path) {
                mergeMissingItems(from: item, into: target, manager: manager)
            } else if !manager.fileExists(atPath: target.path) {
                try? manager.moveItem(at: item, to: target)
            }
        }
    }
}

enum ImageAttachmentNormalizer {
    static let maximumBytes = 4_500_000

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    static func jpegURL(for source: URL) throws -> URL {
        guard isImage(source) else { return source }

        let extensionName = source.pathExtension.lowercased()
        let sourceBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if ["jpg", "jpeg"].contains(extensionName), sourceBytes <= maximumBytes {
            return source
        }

        guard let image = NSImage(contentsOf: source) else {
            throw NSError(
                domain: "Eave.ImageAttachment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "the image could not be decoded"]
            )
        }

        let pixelWidth = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw NSError(
                domain: "Eave.ImageAttachment",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "the image has no readable pixels"]
            )
        }

        let screenshot = AppPaths.isScreenshotName(source.lastPathComponent)
        let directory = screenshot ? AppPaths.screenshotsDirectory : AppPaths.attachmentsDirectory
        let baseName = source.deletingPathExtension().lastPathComponent
        let managedSource = source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        let destination = directory.appendingPathComponent(
            managedSource ? "\(baseName).jpg" : "\(baseName)-\(UUID().uuidString.prefix(8)).jpg"
        )

        var longestSide = max(pixelWidth, pixelHeight)
        var lastData: Data?
        while true {
            let scale = min(1, CGFloat(longestSide) / CGFloat(max(pixelWidth, pixelHeight)))
            let width = max(1, Int((CGFloat(pixelWidth) * scale).rounded()))
            let height = max(1, Int((CGFloat(pixelHeight) * scale).rounded()))
            guard let bitmap = renderedBitmap(image, width: width, height: height) else {
                throw NSError(
                    domain: "Eave.ImageAttachment",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "the JPEG renderer could not be created"]
                )
            }

            for quality in [0.86, 0.72, 0.58] {
                guard let data = bitmap.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: quality]
                ) else { continue }
                lastData = data
                if data.count <= maximumBytes {
                    try data.write(to: destination, options: .atomic)
                    return destination
                }
            }

            if longestSide <= 1024, let lastData {
                try lastData.write(to: destination, options: .atomic)
                return destination
            }
            longestSide = max(1024, Int(CGFloat(longestSide) * 0.75))
        }
    }

    private static func renderedBitmap(_ image: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
        // 32-bit RGBA: NSGraphicsContext(bitmapImageRep:) rejects the 24-bit
        // no-alpha layout on recent macOS and returns nil. We fill an opaque
        // white background before drawing, so the alpha channel is unused and
        // the JPEG encode (which drops alpha) is unaffected.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    enum Role: String, Equatable, Codable { case user, assistant, tool, error }
    let id: UUID
    let role: Role
    var text: String
    var icon: String?
    // Optional keeps decoding compatible with chats saved before attachments
    // were persisted as clickable paths.
    var attachmentPaths: [String]?
    // Full tool invocation (name plus raw arguments) behind a one-line step
    // row, shown when the step is clicked. Optional for the same decoding
    // reason as attachmentPaths.
    var detail: String?
    // Structured version of the same step, used by the inspector to render a
    // clean command or diff. Optional so older archives still decode; `detail`
    // remains the fallback and the copy source.
    var step: StepPayload?

    init(
        role: Role,
        text: String,
        icon: String? = nil,
        attachments: [URL] = [],
        detail: String? = nil,
        step: StepPayload? = nil
    ) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.icon = icon
        self.attachmentPaths = attachments.isEmpty ? nil : attachments.map(\.path)
        self.detail = detail
        self.step = step
    }

    var attachmentURLs: [URL] {
        if let attachmentPaths, !attachmentPaths.isEmpty {
            return attachmentPaths.map {
                AppPaths.relocatedManagedURL(for: URL(fileURLWithPath: $0))
            }
        }

        // Older user messages retained only "Attached: <filename>". Recover
        // legacy NotchAgent screenshots while those files still exist or after
        // they have been migrated into Application Support.
        guard role == .user,
              let attachedLine = text.split(separator: "\n", omittingEmptySubsequences: false)
                .last(where: { $0.hasPrefix("Attached: ") })
        else { return [] }
        return attachedLine.dropFirst("Attached: ".count)
            .split(separator: ",")
            .compactMap { raw in
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard AppPaths.isScreenshotName(name) else { return nil }
                return AppPaths.existingScreenshot(named: name)
            }
    }

    var displayText: String {
        guard attachmentPaths == nil, !attachmentURLs.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("Attached: ") }
            .joined(separator: "\n")
    }
}

// Structured detail behind a tool step, so the inspector can render a clean
// command or a red/green diff instead of the raw JSON dump. Optional on
// ChatMessage keeps chats archived before this was added decodable.
enum StepPayload: Equatable, Codable {
    case command(text: String, cwd: String?, exitCode: Int?)
    case fileChange(files: [FileChange])
}

struct FileChange: Equatable, Codable {
    enum Kind: String, Codable { case create, edit, delete }
    // Relative to the working directory when it could be resolved, else the
    // path as the backend reported it.
    var path: String
    var kind: Kind
    // Unified diff text. Real hunks (with @@ headers) come from Codex; Claude
    // and Cursor edits are synthesized as a plain replace block with no line
    // numbers. Nil when the backend gave us no content to diff.
    var diff: String?
}

// One rendered line of a unified diff. oldNumber/newNumber are nil for
// synthesized diffs that carry no line information.
struct DiffLine {
    enum Kind { case add, del, context, hunk }
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

enum DiffParser {
    static func lines(_ diff: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldN = 0, newN = 0
        var numbered = false
        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                numbered = true
                if let (o, n) = hunkStart(raw) { oldN = o; newN = n }
                result.append(DiffLine(kind: .hunk, oldNumber: nil, newNumber: nil, text: raw))
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---")
                || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                continue // file headers, not content
            } else if raw.hasPrefix("+") {
                result.append(DiffLine(kind: .add, oldNumber: nil,
                                       newNumber: numbered ? newN : nil, text: String(raw.dropFirst())))
                newN += 1
            } else if raw.hasPrefix("-") {
                result.append(DiffLine(kind: .del, oldNumber: numbered ? oldN : nil,
                                       newNumber: nil, text: String(raw.dropFirst())))
                oldN += 1
            } else {
                let t = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
                result.append(DiffLine(kind: .context, oldNumber: numbered ? oldN : nil,
                                       newNumber: numbered ? newN : nil, text: t))
                oldN += 1; newN += 1
            }
        }
        return result
    }

    // Parse the starting line numbers out of "@@ -a,b +c,d @@".
    private static func hunkStart(_ header: String) -> (old: Int, new: Int)? {
        let nums = header.split(whereSeparator: { !"0123456789-+,".contains($0) })
        guard let minus = nums.first(where: { $0.hasPrefix("-") }),
              let plus = nums.first(where: { $0.hasPrefix("+") }) else { return nil }
        let old = Int(minus.dropFirst().split(separator: ",").first ?? "") ?? 0
        let new = Int(plus.dropFirst().split(separator: ",").first ?? "") ?? 0
        return (old, new)
    }

    // Synthesize a replace block for backends that report old/new text rather
    // than a unified diff. Empty `old` yields an all-additions block.
    static func replaceDiff(old: String, new: String) -> String {
        var parts: [String] = []
        if !old.isEmpty { parts += old.components(separatedBy: "\n").map { "-" + $0 } }
        if !new.isEmpty { parts += new.components(separatedBy: "\n").map { "+" + $0 } }
        return parts.joined(separator: "\n")
    }
}

// A persisted conversation, restorable with its provider session ids so it
// can be continued (ChatGPT threads resume via their /c/<id> URL — works
// when signed in; anonymous chats restore as transcript only).
struct ChatArchive: Identifiable, Codable {
    var id = UUID()
    let title: String
    let provider: AgentProvider
    let messages: [ChatMessage]
    let claudeSessionID: String?
    let codexThreadID: String?
    let chatgptThreadID: String?
    let cursorSessionID: String?
    // The folder the chat ran in. Claude stores sessions per project
    // directory, so resuming from any other cwd cannot find the session;
    // Codex and Cursor resume but with the wrong file context. Optional so
    // archives written before this field decode. (nil on those.)
    var workingDirectory: String?
    // The provider settings the chat ran with, applied back on restore. The
    // whole struct is optional so pre-existing archives decode; nil means
    // "unknown, leave the current settings alone", while a present struct
    // with a nil field means "the chat used the provider default".
    var settings: ChatSettings?
    // The live picker can differ from the settings used by the last completed
    // turn. Preserve both so an unfinished draft reopens exactly as left.
    var pickerSettings: ChatSettings?
    // Composer state is kept with the conversation so switching chats never
    // leaks an unfinished prompt or pending files into another conversation.
    var draft: String?
    var pendingAttachmentPaths: [String]?
    // Queues belong to the conversation, not whichever chat is visible.
    var queuedMessages: [QueuedMessage]?
    let date: Date
}

// Snapshot of the per-provider choices in effect for a chat's provider.
// Fields are nil when the corresponding choice was the provider default
// (missing key in the session dictionaries).
struct ChatSettings: Codable, Equatable {
    var model: String?
    var mode: String?
    var effort: String?
    var fastMode: Bool?
    var contextVersion: String?
}

struct QueuedMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var attachmentPaths: [String]
    let createdAt: Date

    init(id: UUID = UUID(), text: String, attachments: [URL], createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachmentPaths = attachments.map(\.path)
        self.createdAt = createdAt
    }

    var attachments: [URL] {
        attachmentPaths.map {
            AppPaths.relocatedManagedURL(for: URL(fileURLWithPath: $0))
        }
    }
}


enum AgentProvider: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case cursor
    case chatgpt

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .chatgpt: return "ChatGPT"
        }
    }

    // ChatGPT-web is chat only; it never touches local files,
    // and its model is whatever the web UI is set to.
    var hasCLIOptions: Bool { self != .chatgpt }

    // `short` stands alone in the composer pill, so it must identify the
    // model without the provider name next to it.
    var models: [AgentOption] {
        switch self {
        case .claude: return [
            // Claude Code's family aliases intentionally follow the latest
            // model available for the user's provider and account. Exact
            // versions below are retained only to render older saved choices;
            // the picker exposes the rolling aliases.
            AgentOption(label: "Fable (Latest)", short: "Fable", value: "fable"),
            AgentOption(label: "Opus (Latest)", short: "Opus", value: "opus"),
            AgentOption(label: "Sonnet (Latest)", short: "Sonnet", value: "sonnet"),
            AgentOption(label: "Haiku (Latest)", short: "Haiku", value: "haiku"),
            AgentOption(label: "Fable 5", short: "Fable 5", value: "claude-fable-5"),
            AgentOption(label: "Opus 5", short: "Opus 5", value: "claude-opus-5"),
            AgentOption(label: "Opus 4.8", short: "Opus 4.8", value: "claude-opus-4-8"),
            AgentOption(label: "Sonnet 5", short: "Sonnet 5", value: "claude-sonnet-5"),
            AgentOption(label: "Haiku 4.5", short: "Haiku 4.5", value: "claude-haiku-4-5-20251001"),
        ]
        case .codex: return [
            AgentOption(label: "GPT-5.5", short: "GPT-5.5", value: "gpt-5.5"),
            AgentOption(label: "GPT-5.6 Sol", short: "5.6 Sol", value: "gpt-5.6-sol"),
            AgentOption(label: "GPT-5.6 Terra", short: "5.6 Terra", value: "gpt-5.6-terra"),
            AgentOption(label: "GPT-5.6 Luna", short: "5.6 Luna", value: "gpt-5.6-luna"),
            AgentOption(label: "GPT-5.4", short: "GPT-5.4", value: "gpt-5.4"),
            AgentOption(label: "GPT-5.4 Mini", short: "5.4 Mini", value: "gpt-5.4-mini"),
            AgentOption(label: "GPT-5.3 Codex Spark", short: "Codex Spark", value: "gpt-5.3-codex-spark"),
            AgentOption(label: "Codex Auto Review", short: "Auto Review", value: "codex-auto-review"),
        ]
        case .cursor: return [
            AgentOption(label: "Composer 2.5", short: "Composer", value: "composer-2.5"),
            AgentOption(label: "Composer Fast", short: "Composer Fast", value: "composer-2.5-fast"),
            AgentOption(label: "Opus 5", short: "Opus 5", value: "claude-opus-5-thinking-high"),
            AgentOption(label: "Opus 5 Fast", short: "Opus 5 Fast", value: "claude-opus-5-thinking-high-fast"),
            AgentOption(label: "Opus 4.8", short: "Opus 4.8", value: "claude-opus-4-8-thinking-high"),
            AgentOption(label: "Opus 4.8 Fast", short: "Opus 4.8 Fast", value: "claude-opus-4-8-thinking-high-fast"),
            AgentOption(label: "Fable 5", short: "Fable 5", value: "claude-fable-5-thinking-high"),
            AgentOption(label: "Sonnet 5", short: "Sonnet 5", value: "claude-sonnet-5-thinking-high"),
            AgentOption(label: "GPT-5.6 Sol", short: "5.6 Sol", value: "gpt-5.6-sol-high"),
            AgentOption(label: "GPT-5.6 Sol Fast", short: "5.6 Sol Fast", value: "gpt-5.6-sol-high-fast"),
            AgentOption(label: "5.6 Terra", short: "5.6 Terra", value: "gpt-5.6-terra-medium"),
            AgentOption(label: "5.6 Terra Fast", short: "5.6 Terra Fast", value: "gpt-5.6-terra-medium-fast"),
            AgentOption(label: "Grok 4.5", short: "Grok 4.5", value: "cursor-grok-4.5-high"),
            AgentOption(label: "Grok 4.5 Fast", short: "Grok 4.5 Fast", value: "cursor-grok-4.5-high-fast"),
        ]
        case .chatgpt: return []
        }
    }

    // Claude and Codex expose fast mode separately from the model id. Cursor's
    // raw catalog is collapsed into families by AgentSession after it loads.
    var modelMenuGroups: [AgentModelMenuGroup] {
        if self == .cursor { return CursorModelFamily.build(from: models).map(\.menuGroup) }
        let visibleModels = self == .claude
            ? models.filter { Self.claudeRollingAliases.contains($0.value ?? "") }
            : models
        return visibleModels.map { model in
            AgentModelMenuGroup(
                label: model.label,
                variants: [.init(label: model.label, option: model, fastMode: false)]
            )
        }
    }

    private static let claudeRollingAliases: Set<String> = [
        "fable", "opus", "sonnet", "haiku",
    ]

    func supportsFastMode(_ model: String?) -> Bool {
        switch self {
        case .claude:
            return model == "opus"
                || model == "claude-opus-5"
                || model == "claude-opus-4-8"
        case .codex:
            return ["gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4"]
                .contains(model)
        case .cursor, .chatgpt:
            return false
        }
    }

    // Thinking-effort scale, ordered fastest → smartest. Claude values feed
    // `--effort`; Codex values feed the app-server turn/start `effort`.
    // Codex scales differ per model: GPT-5.6 adds `max`, and Sol/Terra add
    // `ultra`; other current models top out at xhigh. Labels follow each
    // CLI's own naming (Codex calls low "Light" and xhigh "Extra High").
    // Cursor embeds effort in its raw catalog ids; AgentSession turns those
    // entries back into a model-specific Effort menu.
    func efforts(for model: String?) -> [AgentOption] {
        switch self {
        case .claude: return [
            AgentOption(label: "Low", short: "Low", value: "low"),
            AgentOption(label: "Medium", short: "Med", value: "medium"),
            AgentOption(label: "High", short: "High", value: "high"),
            AgentOption(label: "XHigh", short: "XHigh", value: "xhigh"),
            AgentOption(label: "Max", short: "Max", value: "max"),
        ]
        case .codex:
            var levels = [
                AgentOption(label: "Light", short: "Light", value: "low"),
                AgentOption(label: "Medium", short: "Med", value: "medium"),
                AgentOption(label: "High", short: "High", value: "high"),
                AgentOption(label: "Extra High", short: "XHigh", value: "xhigh"),
            ]
            if model?.hasPrefix("gpt-5.6") == true {
                levels.append(AgentOption(label: "Max", short: "Max", value: "max"))
            }
            if model == "gpt-5.6-sol" || model == "gpt-5.6-terra" {
                levels.append(AgentOption(label: "Ultra", short: "Ultra", value: "ultra"))
            }
            return levels
        case .cursor, .chatgpt: return []
        }
    }

    // The stop each CLI defaults to when no effort flag is sent.
    var defaultEffortValue: String? {
        switch self {
        case .claude: return "high"
        case .codex: return "medium"
        case .cursor, .chatgpt: return nil
        }
    }

    // Claude values feed --permission-mode; Codex values feed --sandbox;
    // Cursor values feed --force / --sandbox (print mode has no interactive
    // permission prompts).
    var permissionModes: [AgentOption] {
        switch self {
        case .claude: return [
            AgentOption(label: "Accept Edits", short: "Edits", value: "acceptEdits"),
            AgentOption(label: "Auto", short: "Auto", value: "auto"),
            AgentOption(label: "Bypass Permissions", short: "Bypass", value: "bypassPermissions", dangerous: true),
        ]
        case .codex: return [
            AgentOption(label: "Ask for Approval", short: "Ask", value: nil),
            AgentOption(label: "Approve for Me", short: "Approve", value: "workspace-write"),
            AgentOption(label: "Full Access", short: "Full", value: "danger-full-access", dangerous: true),
        ]
        case .cursor: return [
            AgentOption(label: "Propose Only", short: "Propose", value: nil),
            AgentOption(label: "Auto Edit", short: "Auto", value: "force"),
            AgentOption(label: "Full Access", short: "Full", value: "force-nosandbox", dangerous: true),
        ]
        case .chatgpt: return []
        }
    }
}

// A provider-reported account limit is materially different from a transport
// or UI failure: it needs a durable, actionable state instead of a red debug
// bubble. Upload limits are separate because ChatGPT text chat can still work.
struct ProviderLimitNotice: Equatable {
    enum Kind: Equatable {
        case usage
        case uploads
    }

    let provider: AgentProvider
    let kind: Kind
    let providerDetail: String?

    var title: String {
        kind == .uploads ? "ChatGPT uploads unavailable" : "\(provider.label) usage limit reached"
    }

    var message: String {
        if kind == .uploads {
            return "Your message wasn't sent. ChatGPT isn't accepting more uploads for this account right now. You can keep chatting without attachments or try again after your upload allowance resets."
        }
        return "Your message wasn't sent. \(provider.label) reports that usage is unavailable for this account right now. Switch providers or try again after the limit resets."
    }
}

// One entry in a model or permission-mode menu. `label` is the menu item,
// `short` is what fits in the composer pill. `dangerous` modes get a warning
// tint on the composer.
struct AgentOption: Identifiable, Equatable {
    let label: String
    let short: String
    let value: String?
    var dangerous: Bool = false
    var id: String { value ?? "default" }
}

struct AgentModelVariant: Identifiable {
    let label: String
    let option: AgentOption
    let fastMode: Bool
    var id: String { "\(option.id):\(fastMode)" }
}

struct AgentModelMenuGroup: Identifiable {
    let label: String
    let variants: [AgentModelVariant]
    var id: String { variants.first?.option.id ?? label }
}

// Structured metadata returned by Codex app-server's model/list endpoint.
// Keeping capabilities beside the option prevents new models from inheriting
// stale effort or speed assumptions from a previously hard-coded generation.
struct CodexModelCatalogEntry {
    let option: AgentOption
    let efforts: [AgentOption]
    let defaultEffortValue: String?
    let supportsFastMode: Bool

    init?(json: [String: Any]) {
        guard json["hidden"] as? Bool != true,
              let model = (json["model"] as? String) ?? (json["id"] as? String),
              !model.isEmpty
        else { return nil }
        let displayName = (json["displayName"] as? String)?.trimmingCharacters(in: .whitespaces)
        let label = displayName?.isEmpty == false ? displayName! : model
        option = AgentOption(label: label, short: label, value: model)

        let reportedEfforts = (json["supportedReasoningEfforts"] as? [[String: Any]]) ?? []
        let values = reportedEfforts.compactMap { $0["reasoningEffort"] as? String }
        efforts = Self.effortOrder.filter(values.contains).map(Self.effortOption)
        defaultEffortValue = json["defaultReasoningEffort"] as? String

        let speedTiers = (json["additionalSpeedTiers"] as? [String]) ?? []
        let serviceTiers = (json["serviceTiers"] as? [[String: Any]]) ?? []
        supportsFastMode = speedTiers.contains("fast")
            || serviceTiers.contains { $0["id"] as? String == "priority" }
    }

    private static let effortOrder = ["none", "low", "medium", "high", "xhigh", "max", "ultra"]

    private static func effortOption(_ value: String) -> AgentOption {
        switch value {
        case "none": return AgentOption(label: "None", short: "None", value: value)
        case "low": return AgentOption(label: "Light", short: "Light", value: value)
        case "medium": return AgentOption(label: "Medium", short: "Med", value: value)
        case "high": return AgentOption(label: "High", short: "High", value: value)
        case "xhigh": return AgentOption(label: "Extra High", short: "XHigh", value: value)
        case "max": return AgentOption(label: "Max", short: "Max", value: value)
        case "ultra": return AgentOption(label: "Ultra", short: "Ultra", value: value)
        default: return AgentOption(label: value.capitalized, short: value, value: value)
        }
    }
}

// Cursor lists every effort/speed combination as a separate model. These
// types normalize that catalog into one visible model family, keeping the raw
// ids only for the final CLI launch.
struct CursorModelConfiguration {
    let modelID: String
    let option: AgentOption
    let effort: String?
    let fastMode: Bool
    let thinkingMode: Bool
    let advertisesOneMillionContext: Bool
}

struct CursorModelFamily: Identifiable {
    let id: String
    let label: String
    let configurations: [CursorModelConfiguration]
    let regularDefaultEffortValue: String?

    var option: AgentOption { AgentOption(label: label, short: label, value: id) }
    var supportsFastMode: Bool { configurations.contains(where: \.fastMode) }
    var supportsThinkingMode: Bool {
        configurations.contains { !$0.thinkingMode }
            && configurations.contains { $0.thinkingMode }
    }
    var supportsOneMillionContext: Bool {
        configurations.contains(where: \.advertisesOneMillionContext)
    }

    var supportedEfforts: [String] {
        let relevant = configurations.filter {
            supportsThinkingMode ? $0.thinkingMode : !$0.thinkingMode
        }
        let available = Set(relevant.compactMap(\.effort))
        return Self.effortOrder.filter(available.contains)
    }

    var defaultControlValue: String? {
        supportsThinkingMode ? "off" : regularDefaultEffortValue
    }

    // When Cursor lists both normal and Thinking aliases, Thinking becomes a
    // setting instead of a duplicate model: Off plus its supported levels.
    // A non-thinking model still uses the ordinary effort menu.
    var effortOptions: [AgentOption] {
        guard supportsThinkingMode || supportedEfforts.count > 1 else { return [] }
        var options: [AgentOption] = supportsThinkingMode
            ? [AgentOption(label: "Off", short: "Off", value: "off")]
            : []
        if supportsThinkingMode && supportedEfforts.isEmpty {
            options.append(AgentOption(label: "On", short: "On", value: "on"))
        }
        options += supportedEfforts.map { value in
            switch value {
            case "none": return AgentOption(label: "None", short: "None", value: value)
            case "low": return AgentOption(label: "Low", short: "Low", value: value)
            case "medium": return AgentOption(label: "Medium", short: "Med", value: value)
            case "high": return AgentOption(label: "High", short: "High", value: value)
            case "xhigh": return AgentOption(label: "Extra High", short: "XHigh", value: value)
            case "max": return AgentOption(label: "Max", short: "Max", value: value)
            default: return AgentOption(label: value.capitalized, short: value, value: value)
            }
        }
        return options
    }

    var menuGroup: AgentModelMenuGroup {
        AgentModelMenuGroup(
            label: label,
            variants: [.init(label: label, option: option, fastMode: false)]
        )
    }

    func modelID(thinkingMode: Bool) -> String {
        configurations.first { $0.thinkingMode == thinkingMode }?.modelID
            ?? configurations.first?.modelID
            ?? id
    }

    func supportsFastMode(effort: String?, thinkingMode: Bool) -> Bool {
        configurations.contains {
            $0.fastMode && $0.effort == effort && $0.thinkingMode == thinkingMode
        }
    }

    func configuration(
        effort: String?, fastMode: Bool, thinkingMode: Bool
    ) -> CursorModelConfiguration? {
        let relevant = configurations.filter { $0.thinkingMode == thinkingMode }
        return relevant.first { $0.effort == effort && $0.fastMode == fastMode }
            ?? relevant.first { $0.effort == effort && !$0.fastMode }
            ?? relevant.first { $0.effort == regularDefaultEffortValue && $0.fastMode == fastMode }
            ?? relevant.first { $0.effort == regularDefaultEffortValue && !$0.fastMode }
            ?? relevant.first
            ?? configurations.first
    }

    private static let effortOrder = ["none", "low", "medium", "high", "xhigh", "max"]
    private static let effortSuffixes: [(suffix: String, value: String)] = [
        ("extra-high", "xhigh"),
        ("medium", "medium"),
        ("xhigh", "xhigh"),
        ("high", "high"),
        ("none", "none"),
        ("low", "low"),
        ("max", "max"),
    ]
    // Cursor returns newest/recommended entries before older versions. Pick
    // the first member of each featured product line rather than pinning an
    // exact generation, so Opus 5 replaces 4.8 (and future versions replace
    // 5) without an Eave release. Unrecognized families remain available in
    // Other instead of disappearing.
    static func featuredFamilyIDs(in families: [CursorModelFamily]) -> Set<String> {
        var seenSeries: Set<String> = []
        var featured: Set<String> = []
        for family in families {
            guard let series = featuredSeries(for: family.id), seenSeries.insert(series).inserted
            else { continue }
            featured.insert(family.id)
        }
        return featured
    }

    private static func featuredSeries(for id: String) -> String? {
        if id == "auto" { return "auto" }
        let prefixes: [(String, String)] = [
            ("composer-", "composer"),
            ("cursor-grok-", "cursor-grok"),
            ("claude-fable-", "claude-fable"),
            ("claude-opus-", "claude-opus"),
            ("claude-sonnet-", "claude-sonnet"),
            ("claude-haiku-", "claude-haiku"),
            ("gpt-5.5", "gpt-frontier"),
            ("kimi-", "kimi"),
            ("glm-", "glm"),
        ]
        if let match = prefixes.first(where: { id.hasPrefix($0.0) }) { return match.1 }
        if id.hasPrefix("gpt-") {
            if id.contains("-sol") { return "gpt-sol" }
            if id.contains("-terra") { return "gpt-terra" }
            if id.contains("-luna") { return "gpt-luna" }
            if id.contains("-codex") { return "gpt-codex" }
        }
        if id.hasPrefix("gemini-") {
            if id.contains("-pro") { return "gemini-pro" }
            if id.contains("-flash") { return "gemini-flash" }
        }
        return nil
    }

    static func build(from options: [AgentOption]) -> [CursorModelFamily] {
        struct Parsed {
            let familyID: String
            let modelID: String
            let option: AgentOption
            let rawEffort: String?
            let fastMode: Bool
            let thinkingMode: Bool
            let advertisesOneMillionContext: Bool
        }

        var order: [String] = []
        var grouped: [String: [Parsed]] = [:]
        for option in options {
            guard var value = option.value else { continue }
            let fastMode = value.hasSuffix("-fast")
            if fastMode { value.removeLast("-fast".count) }

            let parsed = splitEffort(from: value)
            let thinkingMode = parsed.familyID.hasSuffix("-thinking")
            let familyID = thinkingMode
                ? String(parsed.familyID.dropLast("-thinking".count))
                : parsed.familyID
            if grouped[familyID] == nil { order.append(familyID) }
            grouped[familyID, default: []].append(Parsed(
                familyID: familyID,
                modelID: parsed.familyID,
                option: option,
                rawEffort: parsed.effort,
                fastMode: fastMode,
                thinkingMode: thinkingMode,
                advertisesOneMillionContext: option.label.contains("1M")
            ))
        }

        return order.compactMap { familyID in
            guard let entries = grouped[familyID], !entries.isEmpty else { return nil }
            let regularEntries = entries.filter { !$0.thinkingMode }
            let displayEntries = regularEntries.isEmpty ? entries : regularEntries
            let hasExplicitEffort = entries.contains { $0.rawEffort != nil }
            let configurations = entries.map { entry in
                CursorModelConfiguration(
                    modelID: entry.modelID,
                    option: entry.option,
                    effort: entry.rawEffort ?? (hasExplicitEffort ? "medium" : nil),
                    fastMode: entry.fastMode,
                    thinkingMode: entry.thinkingMode,
                    advertisesOneMillionContext: entry.advertisesOneMillionContext
                )
            }

            // Cursor omits the effort word from the default entry's label.
            // The shortest cleaned regular label therefore gives us both the
            // family display name and its default effort.
            let bestIndex = displayEntries.indices.min { lhs, rhs in
                let leftLabel = cleanLabel(displayEntries[lhs].option.label)
                let rightLabel = cleanLabel(displayEntries[rhs].option.label)
                let leftWords = leftLabel.split(separator: " ").count
                let rightWords = rightLabel.split(separator: " ").count
                if leftWords != rightWords { return leftWords < rightWords }
                if displayEntries[lhs].fastMode != displayEntries[rhs].fastMode {
                    return !displayEntries[lhs].fastMode
                }
                return leftLabel.count < rightLabel.count
            } ?? displayEntries.startIndex
            let best = displayEntries[bestIndex]
            let defaultEffort = best.rawEffort ?? (hasExplicitEffort ? "medium" : nil)
            return CursorModelFamily(
                id: familyID,
                label: cleanLabel(best.option.label),
                configurations: configurations,
                regularDefaultEffortValue: defaultEffort
            )
        }
    }

    private static func splitEffort(from value: String) -> (familyID: String, effort: String?) {
        // A few older Claude ids place effort before `-thinking`.
        if value.hasSuffix("-thinking") {
            let prefix = String(value.dropLast("-thinking".count))
            if let match = effortSuffixes.first(where: { prefix.hasSuffix("-\($0.suffix)") }) {
                let family = String(prefix.dropLast(match.suffix.count + 1)) + "-thinking"
                return (family, match.value)
            }
        }
        if let match = effortSuffixes.first(where: { value.hasSuffix("-\($0.suffix)") }) {
            return (String(value.dropLast(match.suffix.count + 1)), match.value)
        }
        return (value, nil)
    }

    private static func cleanLabel(_ label: String) -> String {
        var result = label
        if result.hasSuffix(" Fast") { result.removeLast(" Fast".count) }
        result = result.replacingOccurrences(of: " 1M", with: "")
        result = result.replacingOccurrences(of: " Thinking", with: "")
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result.trimmingCharacters(in: .whitespaces)
    }

}

// A tool call waiting on the user. The composer morphs into the approval UI
// while one of these is pending; `respond` must be called exactly once.
enum PermissionDecision { case allow, always, deny }

struct PermissionRequest: Identifiable {
    let id = UUID()
    let title: String        // "Claude wants to run a command"
    let detail: String       // the command / file / tool input
    let canAlways: Bool
    let respond: (PermissionDecision) -> Void
}

// Claude's AskUserQuestion tool: one or more questions, each answered by
// picking option(s) or typing a custom answer. Answers are keyed by the full
// question text (the CLI matches them by text, not index).
struct AgentQuestionOption: Identifiable {
    let label: String
    let description: String
    var id: String { label }
}

struct AgentQuestion {
    let header: String
    let question: String
    let options: [AgentQuestionOption]
    let multiSelect: Bool
}

struct QuestionRequest: Identifiable {
    let id = UUID()
    let questions: [AgentQuestion]
    var index = 0
    var answers: [String: String] = [:]
    let respond: ([String: String]) -> Void

    var current: AgentQuestion { questions[index] }
}

// Shared persisted history. Live conversations remain separate AgentSession
// objects; this store is only their durable index and restart snapshot.
final class ChatArchiveStore: ObservableObject {
    static let shared = ChatArchiveStore()

    @Published private(set) var chats: [ChatArchive] = []

    private static let maxChats = 10
    private static let chatsURL = AppPaths.supportDirectory.appendingPathComponent("chats.json")

    private init() {
        if let data = try? Data(contentsOf: Self.chatsURL),
           let saved = try? JSONDecoder().decode([ChatArchive].self, from: data) {
            chats = Array(saved.sorted { $0.date > $1.date }.prefix(Self.maxChats))
        }
    }

    func upsert(_ chat: ChatArchive) {
        if let index = chats.firstIndex(where: { $0.id == chat.id }) {
            chats[index] = chat
        } else {
            chats.append(chat)
        }
        chats.sort { $0.date > $1.date }
        if chats.count > Self.maxChats {
            chats.removeLast(chats.count - Self.maxChats)
        }
        persist()
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: Self.chatsURL, options: .atomic)
        }
    }
}

// Drives a coding-agent CLI in headless mode. CLI providers speak JSONL over
// stdout and thread the conversation with a session/thread id:
//   claude -p <prompt> --output-format stream-json --verbose [--resume <id>]
//   codex app-server (JSON-RPC) / openThread + startTurn
//   agent -p --output-format stream-json --stream-partial-output [--resume <id>]
// Main-thread only: all mutations are dispatched to main.
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isRunning = false {
        didSet {
            if !isRunning {
                if let started = turnStartedAt { lastTurnDuration = Date().timeIntervalSince(started) }
                turnStartedAt = nil
                guard oldValue else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.turnDidFinish()
                }
            }
        }
    }
    @Published var draft = ""
    @Published private(set) var queuedMessages: [QueuedMessage] = []
    @Published private(set) var queuePaused = false
    // Background-mode telemetry: when the current turn began, and a running
    // character count of streamed output (a cheap, provider-agnostic token
    // estimate ~= chars/4). Both reset at the start of each turn. lastTurnDuration
    // is frozen when the turn ends so the completed pill can show the final time.
    @Published var turnStartedAt: Date?
    @Published var turnChars = 0
    @Published var lastTurnDuration: TimeInterval = 0
    var silentTurn = false
    var multipleChoiceTurn = false
    @Published var usageLimit: ProviderLimitNotice?
    @Published var provider: AgentProvider = .claude {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerDefaultsKey)
            if usageLimit?.provider != provider { usageLimit = nil }
            // Restores set provider as a side effect and already report
            // chat_restored; counting them would pollute provider_switched.
            if oldValue != provider, !isRestoringChat {
                Telemetry.record("provider_switched", ["provider": provider.rawValue])
            }
        }
    }
    private var isRestoringChat = false
    // Missing key = provider default (no flag). Persisted per provider so
    // switching providers, starting a new chat, and relaunching keep each
    // provider's choices.
    @Published var modelChoice: [AgentProvider: String] = [
        .claude: "sonnet",
        .codex: "gpt-5.6-terra",
        .cursor: "composer-2.5",
    ] {
        didSet { persist(modelChoice, key: Self.modelChoiceDefaultsKey) }
    }
    @Published var modeChoice: [AgentProvider: String] = [
        .claude: "auto",
        .cursor: "force",
    ] {
        didSet { persist(modeChoice, key: Self.modeChoiceDefaultsKey) }
    }
    // Missing key = the CLI's own default effort; set once the user picks a
    // level. Keyed per provider like modelChoice.
    @Published var effortChoice: [AgentProvider: String] = [:] {
        didSet { persist(effortChoice, key: Self.effortChoiceDefaultsKey) }
    }
    // Cursor's raw `-fast` id is chosen only when a request launches.
    @Published var fastModeChoice: [AgentProvider: Bool] = [:] {
        didSet { persist(fastModeChoice, key: Self.fastModeChoiceDefaultsKey) }
    }
    @Published private(set) var cursorModelFamilies = CursorModelFamily.build(
        from: AgentProvider.cursor.models
    )
    @Published private(set) var codexModelCatalog: [CodexModelCatalogEntry] = []
    private var codexCatalogLoader: CodexAppServer?
    // Context choice is remembered per Cursor model family. Missing means the
    // lower-cost/lower-context 250K version.
    @Published private(set) var cursorContextChoice: [String: String] = [:]
    @Published var pendingPermission: PermissionRequest?
    @Published var pendingQuestion: QuestionRequest?
    // Question-sheet UI state. Lives here rather than in @State because the
    // CLT toolchain can't expand SwiftUI's State macro (see build.sh).
    @Published var questionSelection: Set<String> = []
    @Published var questionDraft = ""
    @Published var attachments: [URL] = []
    private static let providerDefaultsKey = "Eave.provider"
    private static let modelChoiceDefaultsKey = "Eave.modelChoice"
    private static let modeChoiceDefaultsKey = "Eave.modeChoice"
    private static let effortChoiceDefaultsKey = "Eave.effortChoice"
    private static let fastModeChoiceDefaultsKey = "Eave.fastModeChoice"
    private static let cursorContextDefaultsKey = "Eave.cursorContextChoice"
    private static let workingDirectoryDefaultsKey = "Eave.workingDirectory"
    // The history entry the live session was restored from, if any. Keeps a
    // reopened chat listed (and in place) in history; archiving updates that
    // entry instead of inserting a duplicate.
    private(set) var currentArchiveID: UUID?
    private var lastTouchedAt = Date()
    // Settings the current conversation last ran with (set on send, carried
    // over on restore). Archived instead of the live picker values so that
    // changing the picker without sending never rewrites a chat's history.
    private var lastRunSettings: ChatSettings?
    // AppState supplies a cross-session gate for providers whose transport is
    // process-global (the shared ChatGPT web view and Cursor approval hook).
    var runBlockReason: ((AgentProvider) -> String?)?
    private var queueDrainSuspended = false
    // Checked immediately before dequeueing so a turn finishing during an
    // edit can never send the stale queue-head text.
    private var queuedMessageBeingEditedID: UUID?

    init() {
        AppPaths.migrateLegacyScreenshots()
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: Self.providerDefaultsKey),
           let savedProvider = AgentProvider(rawValue: value) {
            provider = savedProvider
        }
        modelChoice = Self.savedChoices(
            from: defaults, key: Self.modelChoiceDefaultsKey, fallback: modelChoice
        )
        modeChoice = Self.savedChoices(
            from: defaults, key: Self.modeChoiceDefaultsKey, fallback: modeChoice
        )
        effortChoice = Self.savedChoices(
            from: defaults, key: Self.effortChoiceDefaultsKey, fallback: effortChoice
        )
        fastModeChoice = Self.savedChoices(
            from: defaults, key: Self.fastModeChoiceDefaultsKey, fallback: fastModeChoice
        )
        if let savedPath = defaults.string(forKey: Self.workingDirectoryDefaultsKey) {
            let savedURL = URL(fileURLWithPath: savedPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                workingDirectory = savedURL
            }
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.cursorContextDefaultsKey)
            as? [String: String] {
            var migrated = saved
            for (modelID, value) in saved where modelID.hasSuffix("-thinking") {
                let familyID = String(modelID.dropLast("-thinking".count))
                if migrated[familyID] == nil { migrated[familyID] = value }
                migrated.removeValue(forKey: modelID)
            }
            cursorContextChoice = migrated
            if migrated != saved {
                UserDefaults.standard.set(migrated, forKey: Self.cursorContextDefaultsKey)
            }
        }
        refreshModelCatalogs()
    }

    private static func savedChoices<Value>(
        from defaults: UserDefaults,
        key: String,
        fallback: [AgentProvider: Value]
    ) -> [AgentProvider: Value] {
        guard let saved = defaults.dictionary(forKey: key) else { return fallback }
        return saved.reduce(into: [:]) { result, entry in
            guard let provider = AgentProvider(rawValue: entry.key),
                  let value = entry.value as? Value
            else { return }
            result[provider] = value
        }
    }

    private func persist<Value>(_ choices: [AgentProvider: Value], key: String) {
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) }),
            forKey: key
        )
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            guard ImageAttachmentNormalizer.isImage(url) else {
                attachments.append(url)
                continue
            }
            do {
                attachments.append(try ImageAttachmentNormalizer.jpegURL(for: url))
            } catch {
                Telemetry.record("error", [
                    "domain": "image_attachment",
                    "code": String((error as NSError).code),
                ])
                messages.append(ChatMessage(
                    role: .error,
                    text: "Couldn't convert \(url.lastPathComponent) to JPEG — \(error.localizedDescription)."
                ))
            }
        }
    }

    func modelMenuGroups(for provider: AgentProvider) -> [AgentModelMenuGroup] {
        if provider == .cursor {
            let featured = CursorModelFamily.featuredFamilyIDs(in: cursorModelFamilies)
            return cursorModelFamilies.filter { featured.contains($0.id) }.map(\.menuGroup)
        }
        if provider == .codex {
            return models(for: provider).map { model in
                AgentModelMenuGroup(
                    label: model.label,
                    variants: [.init(label: model.label, option: model, fastMode: false)]
                )
            }
        }
        return provider.modelMenuGroups
    }

    func models(for provider: AgentProvider) -> [AgentOption] {
        let available: [AgentOption]
        switch provider {
        case .cursor:
            available = cursorModelFamilies.map(\.option)
        case .codex:
            available = codexModelCatalog.isEmpty
                ? provider.models : codexModelCatalog.map(\.option)
        case .claude, .chatgpt:
            available = provider.models
        }
        guard let selected = modelChoice[provider],
              !available.contains(where: { $0.value == selected })
        else { return available }
        let preserved = provider.models.first(where: { $0.value == selected })
            ?? AgentOption(label: selected, short: selected, value: selected)
        return available + [preserved]
    }

    func efforts(for provider: AgentProvider) -> [AgentOption] {
        if provider == .cursor { return selectedCursorFamily?.effortOptions ?? [] }
        if provider == .codex, let entry = selectedCodexCatalogEntry {
            return entry.efforts
        }
        return provider.efforts(for: modelChoice[provider])
    }

    func defaultEffortValue(for provider: AgentProvider) -> String? {
        if provider == .cursor { return selectedCursorFamily?.defaultControlValue }
        if provider == .codex, let entry = selectedCodexCatalogEntry {
            return entry.defaultEffortValue
        }
        return provider.defaultEffortValue
    }

    func effortMenuLabel(for provider: AgentProvider) -> String {
        provider == .cursor && selectedCursorFamily?.supportsThinkingMode == true
            ? "Thinking" : "Effort"
    }

    func speedVersions(for provider: AgentProvider) -> [AgentOption] {
        let supportsFast: Bool
        if provider == .cursor, let family = selectedCursorFamily {
            let choice = cursorConfigurationChoice(for: family)
            supportsFast = family.supportsFastMode(
                effort: choice.effort,
                thinkingMode: choice.thinkingMode
            )
        } else if provider == .codex, let entry = selectedCodexCatalogEntry {
            supportsFast = entry.supportsFastMode
        } else {
            supportsFast = provider.supportsFastMode(modelChoice[provider])
        }
        guard supportsFast else { return [] }
        return [
            AgentOption(label: "Regular", short: "Regular", value: "regular"),
            AgentOption(label: "Fast", short: "Fast", value: "fast"),
        ]
    }

    func effectiveSpeedVersion(for provider: AgentProvider) -> String? {
        guard !speedVersions(for: provider).isEmpty else { return nil }
        return effectiveFastMode(for: provider) ? "fast" : "regular"
    }

    func setSpeedVersion(_ value: String, for provider: AgentProvider) {
        guard value == "regular" || value == "fast",
              !speedVersions(for: provider).isEmpty
        else { return }
        fastModeChoice[provider] = value == "fast"
    }

    func contextVersions(for provider: AgentProvider) -> [AgentOption] {
        guard provider == .cursor, selectedCursorFamily?.supportsOneMillionContext == true else {
            return []
        }
        return [
            AgentOption(label: "250K", short: "250K", value: "250k"),
            AgentOption(label: "1M", short: "1M", value: "1m"),
        ]
    }

    func effectiveContextVersion(for provider: AgentProvider) -> String? {
        guard provider == .cursor,
              let family = selectedCursorFamily,
              family.supportsOneMillionContext
        else { return nil }
        return cursorContextChoice[family.id] == "1m" ? "1m" : "250k"
    }

    func setContextVersion(_ value: String, for provider: AgentProvider) {
        guard provider == .cursor,
              let family = selectedCursorFamily,
              value == "250k" || value == "1m"
        else { return }
        cursorContextChoice[family.id] = value
        UserDefaults.standard.set(cursorContextChoice, forKey: Self.cursorContextDefaultsKey)
    }

    func effectiveFastMode(for provider: AgentProvider) -> Bool {
        if provider == .cursor {
            guard fastModeChoice[provider] == true, let family = selectedCursorFamily else {
                return false
            }
            let choice = cursorConfigurationChoice(for: family)
            return family.supportsFastMode(
                effort: choice.effort,
                thinkingMode: choice.thinkingMode
            )
        }
        guard fastModeChoice[provider] == true,
              let selectedModel = modelChoice[provider]
        else { return false }
        if provider == .codex, let entry = selectedCodexCatalogEntry {
            return entry.supportsFastMode
        }
        return provider.supportsFastMode(selectedModel)
    }

    func refreshModelCatalogs() {
        refreshCursorModelCatalog()
        refreshCodexModelCatalog()
    }

    private func refreshCursorModelCatalog() {
        guard let executable = Self.findExecutable("agent") else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["models"]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8)
                else { return }
                let options = Self.parseCursorModels(text)
                let families = CursorModelFamily.build(from: options)
                guard !families.isEmpty else { return }
                DispatchQueue.main.async { self?.cursorModelFamilies = families }
            } catch {
                // Keep the built-in fallback catalog when the CLI cannot list.
            }
        }
    }

    private func refreshCodexModelCatalog() {
        guard codexCatalogLoader == nil,
              let executable = Self.findExecutable("codex")
        else { return }
        let loader = CodexAppServer()
        codexCatalogLoader = loader
        do {
            try loader.start(
                executable: executable,
                environment: Self.cliEnvironment()
            ) { [weak self, weak loader] error in
                guard let self, let loader else { return }
                guard error == nil else {
                    loader.stop()
                    self.codexCatalogLoader = nil
                    return
                }
                loader.listModels { [weak self, weak loader] models, _ in
                    guard let self else { return }
                    let entries = (models ?? []).compactMap(CodexModelCatalogEntry.init(json:))
                    if !entries.isEmpty { self.codexModelCatalog = entries }
                    loader?.stop()
                    self.codexCatalogLoader = nil
                }
            }
        } catch {
            loader.stop()
            codexCatalogLoader = nil
            // Keep the bundled fallback catalog when app-server is unavailable.
        }
    }

    private static func parseCursorModels(_ output: String) -> [AgentOption] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let separator = line.range(of: " - ") else { return nil }
            let value = String(line[..<separator.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let label = String(line[separator.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.contains(" "), !label.isEmpty else { return nil }
            return AgentOption(label: label, short: label, value: value)
        }
    }

    private var selectedCursorFamily: CursorModelFamily? {
        guard let selected = modelChoice[.cursor] else { return nil }
        return cursorModelFamilies.first { $0.id == selected }
    }

    private var selectedCodexCatalogEntry: CodexModelCatalogEntry? {
        guard let selected = modelChoice[.codex] else { return nil }
        return codexModelCatalog.first { $0.option.value == selected }
    }

    private func cursorConfigurationChoice(
        for family: CursorModelFamily
    ) -> (effort: String?, thinkingMode: Bool) {
        let control = effectiveEffort(for: .cursor) ?? family.defaultControlValue
        let thinkingMode = family.supportsThinkingMode && control != "off"
        let effort: String?
        if thinkingMode {
            effort = control == "on" ? nil : control
        } else {
            effort = family.regularDefaultEffortValue
        }
        return (effort, thinkingMode)
    }

    @Published var workingDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/code") {
            didSet {
                UserDefaults.standard.set(
                    workingDirectory.standardizedFileURL.path,
                    forKey: Self.workingDirectoryDefaultsKey
                )
            }
        }

    private var claudeSessionID: String?
    private var codexThreadID: String?
    private var chatgptThreadID: String?
    private var cursorSessionID: String?
    // A question answer waiting for the asking turn to exit; see
    // deliverCursorFollowUp.
    private var pendingCursorFollowUp: String?
    // Tools the user chose "always" for, reset each Cursor turn.
    private var cursorSessionApprovals: Set<String> = []
    private var process: Process?
    // Bumped whenever the transcript is replaced (reset/restore). Output from
    // a process killed by that replacement can still be in flight on the main
    // queue; events carrying an older epoch must not touch the new transcript.
    private var transcriptEpoch = 0
    // Set when cancel() terminates a CLI process so its nonzero exit status
    // isn't reported as a provider failure.
    private var expectingProcessExit = false
    private var claudeStdin: FileHandle?
    private let codexServer = CodexAppServer()
    private var codexActiveTurnID: String?
    // Turns the user stopped. Their turn/completed notifications arrive later
    // and must not tear down whatever turn is running by then.
    private var codexInterruptedTurnIDs: Set<String> = []
    private lazy var claudePath: String? = Self.findExecutable("claude")
    private lazy var codexPath: String? = Self.findExecutable("codex")
    private lazy var cursorPath: String? = Self.findExecutable("agent")

    private static func findExecutable(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // While a turn is running, submit moves the current composer contents into
    // this chat's queue. Otherwise it starts the turn immediately.
    func submit(_ text: String) {
        let files = attachments
        attachments = []
        if isRunning || !queuedMessages.isEmpty {
            queuedMessages.append(QueuedMessage(text: text, attachments: files))
            queuePaused = false
            queueDrainSuspended = false
            archiveCurrentIfNeeded()
            if !isRunning { startNextQueuedMessage() }
            return
        }
        sendPrepared(text, files: files, echo: true)
    }

    @discardableResult
    func beginEditingQueuedMessage(_ id: UUID) -> Bool {
        guard queuedMessages.contains(where: { $0.id == id }) else { return false }
        queuedMessageBeingEditedID = id
        if queuedMessages.first?.id == id {
            queuePaused = true
        }
        return true
    }

    @discardableResult
    func commitQueuedMessageEdit(_ id: UUID, text: String, attachments: [URL]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = queuedMessages.firstIndex(where: { $0.id == id })
        else { return false }
        queuedMessages[index].text = trimmed
        queuedMessages[index].attachmentPaths = attachments.map(\.path)
        if queuedMessageBeingEditedID == id {
            queuedMessageBeingEditedID = nil
        }
        archiveCurrentIfNeeded()
        resumeQueueAfterEditIfPossible()
        return true
    }

    func cancelQueuedMessageEdit(_ id: UUID) {
        guard queuedMessageBeingEditedID == id else { return }
        queuedMessageBeingEditedID = nil
        resumeQueueAfterEditIfPossible()
    }

    func removeQueuedMessage(_ id: UUID) {
        let wasBeingEdited = queuedMessageBeingEditedID == id
        queuedMessages.removeAll { $0.id == id }
        if wasBeingEdited {
            queuedMessageBeingEditedID = nil
        }
        if queuedMessages.isEmpty {
            queuePaused = false
        }
        archiveCurrentIfNeeded()
        if wasBeingEdited {
            resumeQueueAfterEditIfPossible()
        }
    }

    func moveQueuedMessage(_ id: UUID, before targetID: UUID) {
        guard id != targetID,
              let source = queuedMessages.firstIndex(where: { $0.id == id }),
              let target = queuedMessages.firstIndex(where: { $0.id == targetID })
        else { return }
        let item = queuedMessages.remove(at: source)
        queuedMessages.insert(item, at: target)
        archiveCurrentIfNeeded()
    }

    private func startNextQueuedMessage() {
        guard !isRunning, let next = queuedMessages.first else { return }
        guard queuedMessageBeingEditedID != next.id else {
            queuePaused = true
            archiveCurrentIfNeeded()
            return
        }
        guard runBlockReason?(provider) == nil else {
            queuePaused = true
            archiveCurrentIfNeeded()
            return
        }
        queuedMessages.removeFirst()
        archiveCurrentIfNeeded()
        sendPrepared(next.text, files: next.attachments, echo: true)
        if !isRunning {
            queuePaused = true
            archiveCurrentIfNeeded()
        }
    }

    private func turnDidFinish() {
        archiveCurrentIfNeeded()
        guard !queuedMessages.isEmpty else {
            queuePaused = false
            return
        }
        guard !queueDrainSuspended,
              usageLimit == nil,
              messages.last?.role != .error
        else {
            queuePaused = true
            archiveCurrentIfNeeded()
            return
        }
        startNextQueuedMessage()
    }

    private func resumeQueueAfterEditIfPossible() {
        guard !queuedMessages.isEmpty else {
            queuePaused = false
            return
        }
        guard queuedMessageBeingEditedID == nil else { return }
        guard !queueDrainSuspended,
              usageLimit == nil,
              messages.last?.role != .error
        else {
            queuePaused = true
            archiveCurrentIfNeeded()
            return
        }
        if isRunning {
            queuePaused = false
            return
        }
        queuePaused = false
        startNextQueuedMessage()
    }

    // echo=false sends text the transcript already shows in another form (a
    // question answer, which answerQuestion has already appended as the user's
    // bubble) so it isn't printed twice.
    func send(_ text: String, echo: Bool = true) {
        let files = attachments
        attachments = []
        sendPrepared(text, files: files, echo: echo)
    }

    private func sendPrepared(_ text: String, files: [URL], echo: Bool) {
        guard !isRunning else { return }
        if let reason = runBlockReason?(provider) {
            if draft.isEmpty { draft = text }
            for file in files where !attachments.contains(file) {
                attachments.append(file)
            }
            appendError(reason)
            return
        }
        queueDrainSuspended = false
        queuePaused = false
        usageLimit = nil
        turnStartedAt = Date()
        turnChars = 0
        Telemetry.record("message_sent", ["provider": provider.rawValue, "attachments": String(files.count)])

        if echo {
            messages.append(ChatMessage(role: .user, text: text, attachments: files))
        }

        // Snapshot now, not at archive time: the archive must record what the
        // conversation actually ran with, and the picker can change between
        // the last turn and archiving (or the chat may just be viewed).
        lastRunSettings = ChatSettings(
            model: modelChoice[provider],
            mode: modeChoice[provider],
            effort: effortChoice[provider],
            fastMode: fastModeChoice[provider],
            contextVersion: effectiveContextVersion(for: provider)
        )

        // Only an ordinary user send touches history ordering. Permission
        // decisions, question answers, opening a chat, and background output
        // all preserve its existing position.
        if echo {
            if currentArchiveID == nil { currentArchiveID = UUID() }
            lastTouchedAt = Date()
            archiveCurrentIfNeeded()
        }

        if provider == .chatgpt {
            // The website receives the user's exact text plus real file
            // uploads. Do not append hidden behavioral instructions.
            sendViaChatGPTWeb(text, files: files)
            return
        }

        switch provider {
        case .claude:
            let images = files.filter(Self.isImageAttachment)
            let nonImages = files.filter { !images.contains($0) }
            sendViaClaude(Self.withAttachmentPaths(text, files: nonImages), images: images)
        case .codex:
            // Codex app-server supports native localImage and mention inputs,
            // so attachments do not need to be described inside the prompt.
            sendViaCodex(text, files: files)
        case .cursor:
            // Cursor's CLI has no attachment argument. Preserve its working
            // path transport without adding any behavioral prompt around it.
            sendViaCursor(Self.withAttachmentPaths(text, files: files))
        case .chatgpt: break // handled above
        }
    }

    private static func withAttachmentPaths(_ text: String, files: [URL]) -> String {
        guard !files.isEmpty else { return text }
        return text + "\n\n" + files.map(\.path).joined(separator: "\n")
    }

    private static func isImageAttachment(_ url: URL) -> Bool {
        ImageAttachmentNormalizer.isImage(url)
    }

    // GUI apps inherit a minimal PATH; both CLIs need node and friends.
    private static func cliEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }

    // MARK: - Claude (stream-json + stdio control protocol)

    // One process per turn. The user message goes in over stdin as stream-json
    // and stdin stays open so `--permission-prompt-tool stdio` can ask us for
    // tool permissions (control_request/can_use_tool -> control_response).
    private func sendViaClaude(_ text: String, images: [URL]) {
        guard let claudePath else {
            appendError("""
                claude CLI not found on PATH.
                Install Claude Code, then in Terminal run: claude auth login
                """)
            return
        }
        isRunning = true
        ensureAuthenticated(provider: .claude, executable: claudePath) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.isRunning = false
                return
            }
            self.launchClaude(text: text, images: images, executable: claudePath)
        }
    }

    private func launchClaude(text: String, images: [URL], executable: String) {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose", "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
        ]
        if let claudeSessionID { args += ["--resume", claudeSessionID] }
        if let model = modelChoice[.claude] { args += ["--model", model] }
        if let effort = effectiveEffort(for: .claude) { args += ["--effort", effort] }
        let fastMode = effectiveFastMode(for: .claude)
        args += ["--settings", "{\"fastMode\":\(fastMode)}"]
        if let mode = modeChoice[.claude] {
            args += ["--permission-mode", mode]
            if mode == "bypassPermissions" { args.append("--allow-dangerously-skip-permissions") }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        p.environment = Self.cliEnvironment()

        let stdin = Pipe()
        let out = Pipe()
        let err = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = err

        expectingProcessExit = false
        let epoch = transcriptEpoch
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                DispatchQueue.main.async {
                    guard let self, self.transcriptEpoch == epoch else { return }
                    self.handleClaudeEvent(obj)
                }
            }
        }

        // Drain stderr continuously: hooks and plugins are chatty enough to
        // fill the pipe buffer, which would block the CLI before it says
        // anything on stdout. Keep the tail for the failure message.
        var errData = Data()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errData.append(data)
            if errData.count > 65_536 { errData.removeFirst(errData.count - 65_536) }
        }

        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                self.claudeStdin = nil
                self.pendingPermission = nil
                self.pendingQuestion = nil
                let cancelled = self.expectingProcessExit
                self.expectingProcessExit = false
                if proc.terminationStatus != 0, !cancelled, self.transcriptEpoch == epoch {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.presentProviderFailure(msg.isEmpty
                        ? "claude exited with status \(proc.terminationStatus)"
                        : msg, provider: .claude)
                }
            }
        }

        do {
            try p.run()
            process = p
            claudeStdin = stdin.fileHandleForWriting
            var content: [[String: Any]] = []
            for image in images {
                guard let data = try? Data(contentsOf: image), data.count <= 5_000_000,
                      let type = UTType(filenameExtension: image.pathExtension),
                      let mime = type.preferredMIMEType,
                      ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime)
                else {
                    appendError("Skipped \(image.lastPathComponent) (unsupported, unreadable, or over 5 MB).")
                    continue
                }
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mime,
                        "data": data.base64EncodedString(),
                    ],
                ])
            }
            content.append(["type": "text", "text": text])
            writeClaudeLine([
                "type": "user",
                "message": ["role": "user", "content": content],
            ])
        } catch {
            isRunning = false
            appendError("Failed to launch claude: \(error.localizedDescription)")
        }
    }

    // The effort actually sent: the user's choice when the current model
    // supports it, otherwise nothing (the CLI default). A 5.6 "max" pick
    // doesn't survive switching to 5.5, which tops out at xhigh.
    func effectiveEffort(for provider: AgentProvider) -> String? {
        guard let value = effortChoice[provider] else { return nil }
        let supported: Bool
        if provider == .cursor {
            supported = selectedCursorFamily?.effortOptions.contains { $0.value == value } == true
        } else {
            supported = provider.efforts(for: modelChoice[provider]).contains { $0.value == value }
        }
        return supported ? value : nil
    }

    private func writeClaudeLine(_ obj: [String: Any]) {
        guard let claudeStdin,
              var data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        data.append(0x0A)
        try? claudeStdin.write(contentsOf: data)
    }

    private func writeClaudeControlResponse(_ requestID: String, _ inner: [String: Any]) {
        writeClaudeLine([
            "type": "control_response",
            "response": ["subtype": "success", "request_id": requestID, "response": inner],
        ])
    }

    // MARK: - Codex (app-server JSON-RPC)

    private func sendViaCodex(_ text: String, files: [URL]) {
        guard let codexPath else {
            appendError("""
                codex CLI not found on PATH.
                Install the Codex CLI, then in Terminal run: codex login
                """)
            return
        }
        isRunning = true
        ensureAuthenticated(provider: .codex, executable: codexPath) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.isRunning = false
                return
            }
            self.launchCodex(text: text, files: files, executable: codexPath)
        }
    }

    private func launchCodex(text: String, files: [URL], executable: String) {
        if !codexServer.isRunning {
            do {
                try codexServer.start(executable: executable, environment: Self.cliEnvironment())
            } catch {
                isRunning = false
                appendError("Failed to launch codex app-server: \(error.localizedDescription)")
                return
            }
        }
        let epoch = transcriptEpoch
        codexServer.onEvent = { [weak self] event in
            guard let self, self.transcriptEpoch == epoch else { return }
            self.handleCodexServerEvent(event)
        }

        let mode = Self.codexModeConfig(modeChoice[.codex])
        var threadParams: [String: Any] = [
            "cwd": workingDirectory.path,
            "approvalPolicy": mode.approvalPolicy,
            "sandbox": mode.sandbox,
            "serviceTier": effectiveFastMode(for: .codex) ? "priority" : NSNull(),
        ]
        if let model = modelChoice[.codex] { threadParams["model"] = model }

        codexServer.openThread(resuming: codexThreadID, params: threadParams) { [weak self] threadID, error in
            guard let self else { return }
            if let error {
                self.isRunning = false
                self.presentProviderFailure(error, provider: .codex)
                return
            }
            guard let threadID else { return }
            self.codexThreadID = threadID

            var input: [[String: Any]] = [["type": "text", "text": text]]
            for file in files {
                if Self.isImageAttachment(file) {
                    input.append(["type": "localImage", "path": file.path])
                } else {
                    input.append([
                        "type": "mention",
                        "name": file.lastPathComponent,
                        "path": file.path,
                    ])
                }
            }

            var turnParams: [String: Any] = [
                "threadId": threadID,
                "approvalPolicy": mode.approvalPolicy,
                "sandboxPolicy": ["type": mode.sandboxPolicyType],
                "input": input,
                "serviceTier": self.effectiveFastMode(for: .codex) ? "priority" : NSNull(),
            ]
            if let model = self.modelChoice[.codex] { turnParams["model"] = model }
            if let effort = self.effectiveEffort(for: .codex) { turnParams["effort"] = effort }
            self.codexServer.startTurn(turnParams) { [weak self] turnID, error in
                guard let self else { return }
                if let error {
                    self.isRunning = false
                    self.presentProviderFailure(error, provider: .codex)
                    return
                }
                self.codexActiveTurnID = turnID
            }
        }
    }

    // Runs `claude auth status` / `codex login status` off the main thread.
    // On failure, posts an error that tells the user the Terminal command —
    // no in-app wizard.
    private func ensureAuthenticated(
        provider: AgentProvider,
        executable: String,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok: Bool
            let message: String?
            switch provider {
            case .claude:
                let result = Self.runCLI(executable, ["auth", "status", "--json"])
                if Self.claudeLooksAuthenticated(stdout: result.stdout, status: result.status) {
                    ok = true
                    message = nil
                } else {
                    ok = false
                    message = """
                        Claude isn't logged in.
                        In Terminal run: claude auth login
                        """
                }
            case .codex:
                if Self.codexLooksAuthenticated(executable: executable) {
                    ok = true
                    message = nil
                } else {
                    ok = false
                    message = """
                        Codex isn't logged in.
                        In Terminal run: codex login
                        """
                }
            case .cursor:
                if Self.cursorLooksAuthenticated(executable: executable) {
                    ok = true
                    message = nil
                } else {
                    ok = false
                    message = """
                        Cursor isn't logged in.
                        In Terminal run: agent login
                        Or set CURSOR_API_KEY.
                        """
                }
            case .chatgpt:
                ok = true
                message = nil
            }
            DispatchQueue.main.async {
                if let message { self?.appendError(message) }
                completion(ok)
            }
        }
    }

    private static func claudeLooksAuthenticated(stdout: String, status: Int32) -> Bool {
        if let data = stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loggedIn = obj["loggedIn"] as? Bool {
            return loggedIn
        }
        let lower = stdout.lowercased()
        if status == 0, lower.contains("logged"), !lower.contains("not logged") {
            return true
        }
        return false
    }

    private static func codexLooksAuthenticated(executable: String) -> Bool {
        let result = runCLI(executable, ["login", "status"])
        let lower = result.stdout.lowercased()
        if lower.contains("logged in") { return true }
        // API-key / config auth can still work when OAuth status says no.
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false {
            return true
        }
        let authPath = NSHomeDirectory() + "/.codex/auth.json"
        return FileManager.default.fileExists(atPath: authPath)
    }

    private static func cursorLooksAuthenticated(executable: String) -> Bool {
        if ProcessInfo.processInfo.environment["CURSOR_API_KEY"]?.isEmpty == false {
            return true
        }
        let result = runCLI(executable, ["status"])
        let lower = result.stdout.lowercased()
        if lower.contains("not authenticated")
            || lower.contains("not logged")
            || lower.contains("please log in")
            || lower.contains("login required") {
            return false
        }
        if result.status == 0,
           lower.contains("logged in") || lower.contains("authenticated") {
            return true
        }
        // `agent status` prints account details when logged in; treat a clean
        // exit with any output as authenticated.
        return result.status == 0
            && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Cursor (agent CLI stream-json)

    // One process per turn. Print mode has no interactive permission prompts;
    // --force / --sandbox cover auto-edit vs propose-only.
    private func sendViaCursor(_ text: String) {
        guard let cursorPath else {
            appendError("""
                Cursor agent CLI not found on PATH.
                Install with: curl https://cursor.com/install -fsS | bash
                Then in Terminal run: agent login
                """)
            return
        }
        isRunning = true
        ensureAuthenticated(provider: .cursor, executable: cursorPath) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.isRunning = false
                return
            }
            self.launchCursor(text: text, executable: cursorPath)
        }
    }

    private func resolvedCursorModelID() -> String? {
        guard let family = selectedCursorFamily else { return modelChoice[.cursor] }
        let choice = cursorConfigurationChoice(for: family)
        let fastMode = effectiveFastMode(for: .cursor)
        let modelID = family.modelID(thinkingMode: choice.thinkingMode)

        // Cursor's parameterized model syntax keeps the family in one place:
        // normal context is the default, while 1M is an explicit override.
        if family.supportsOneMillionContext {
            var overrides: [String] = []
            if effectiveContextVersion(for: .cursor) == "1m" {
                overrides.append("context=1m")
            }
            if let effort = choice.effort { overrides.append("effort=\(effort)") }
            if family.supportsFastMode { overrides.append("fast=\(fastMode)") }
            return overrides.isEmpty ? modelID : "\(modelID)[\(overrides.joined(separator: ","))]"
        }

        return family.configuration(
            effort: choice.effort,
            fastMode: fastMode,
            thinkingMode: choice.thinkingMode
        )?.option.value ?? modelID
    }

    private func launchCursor(text: String, executable: String) {
        var args = [
            "-p",
            "--output-format", "stream-json",
            "--stream-partial-output",
            "--trust",
            "--workspace", workingDirectory.path,
        ]
        if let cursorSessionID { args += ["--resume", cursorSessionID] }
        if let model = resolvedCursorModelID() { args += ["--model", model] }
        switch modeChoice[.cursor] {
        case "force":
            args.append("--force")
        case "force-nosandbox":
            args += ["--force", "--sandbox", "disabled"]
        default:
            // Propose Only. Headless Cursor cannot ask us for permission, so
            // without the hook gate installed it rejects every call that needs
            // one. With the gate, --force hands the decision to our prompt
            // instead of to the CLI's non-existent one.
            if CursorApprovals.isInstalled {
                args.append("--force")
                beginCursorApprovals()
            }
        }
        args.append(text)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        p.environment = Self.cliEnvironment()

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        expectingProcessExit = false
        let epoch = transcriptEpoch
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            buffer.append(data)
            while let newline = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<newline.upperBound)
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                else { continue }
                DispatchQueue.main.async {
                    guard let self, self.transcriptEpoch == epoch else { return }
                    self.handleCursorEvent(obj)
                }
            }
        }

        var errData = Data()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errData.append(data)
            if errData.count > 65_536 { errData.removeFirst(errData.count - 65_536) }
        }

        p.terminationHandler = { [weak self] proc in
            err.fileHandleForReading.readabilityHandler = nil
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                CursorApprovals.endSession()
                let cancelled = self.expectingProcessExit
                self.expectingProcessExit = false
                if proc.terminationStatus != 0, !cancelled, self.transcriptEpoch == epoch {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.presentProviderFailure(msg.isEmpty
                        ? "agent exited with status \(proc.terminationStatus)"
                        : msg, provider: .cursor)
                }
                self.flushCursorFollowUp()
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            isRunning = false
            appendError("Failed to launch agent: \(error.localizedDescription)")
        }
    }

    private func handleCursorEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if let id = event["session_id"] as? String { cursorSessionID = id }
        case "assistant":
            // With --stream-partial-output: only timestamp_ms (no model_call_id)
            // carries new text. Other assistant events are duplicate flushes.
            let hasTimestamp = event["timestamp_ms"] != nil
            let hasModelCall = event["model_call_id"] != nil
            if hasTimestamp && hasModelCall { return }
            if hasTimestamp && !hasModelCall {
                guard let message = event["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { return }
                let text = content.compactMap { block -> String? in
                    guard block["type"] as? String == "text" else { return nil }
                    return block["text"] as? String
                }.joined()
                if !text.isEmpty { appendAssistantDelta(text) }
                return
            }
            // Non-streaming complete segment (no partial flag / final flush).
            if !hasTimestamp {
                // Skip the final duplicate flush at end of turn.
                return
            }
        case "interaction_query":
            // The model asked a multiple-choice question. Headless `agent -p`
            // has no channel to answer one, so the CLI instantly self-rejects
            // it ("Questions skipped by the user") and the turn continues. We
            // still surface it in the notch and deliver the pick as the next
            // message on the resumed session.
            guard event["subtype"] as? String == "request",
                  event["query_type"] as? String == "askQuestionInteractionQuery",
                  let query = event["query"] as? [String: Any],
                  let ask = query["askQuestionInteractionQuery"] as? [String: Any],
                  let args = ask["args"] as? [String: Any] else { return }
            presentCursorQuestions(args)
        case "tool_call":
            guard event["subtype"] as? String == "started",
                  let toolCall = event["tool_call"] as? [String: Any] else { return }
            // The question itself is the UI; a "using askQuestion" activity
            // line under it is noise.
            if toolCall["askQuestionToolCall"] != nil { return }
            let display = Self.cursorToolDisplay(toolCall)
            appendTool(
                display.text,
                icon: display.icon,
                detail: Self.toolDetail(name: display.text, arguments: toolCall),
                step: cursorStep(toolCall)
            )
        case "result":
            if let id = event["session_id"] as? String { cursorSessionID = id }
            if event["is_error"] as? Bool == true,
               let result = event["result"] as? String,
               !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                presentProviderFailure(result, provider: .cursor)
            }
        default:
            break
        }
    }

    // Cursor's askQuestion args: { title, questions: [{ prompt, allowMultiple,
    // options: [{ id, label }] }] }. Options carry no description text.
    private func presentCursorQuestions(_ args: [String: Any]) {
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Question"
        let questions = (args["questions"] as? [[String: Any]] ?? []).compactMap { q -> AgentQuestion? in
            let prompt = q["prompt"] as? String ?? ""
            guard !prompt.isEmpty else { return nil }
            return AgentQuestion(
                header: title,
                question: prompt,
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    AgentQuestionOption(
                        label: $0["label"] as? String ?? $0["id"] as? String ?? "",
                        description: ""
                    )
                },
                multiSelect: q["allowMultiple"] as? Bool ?? false
            )
        }
        guard !questions.isEmpty else { return }
        pendingQuestion = QuestionRequest(questions: questions) { [weak self] answers in
            guard let self else { return }
            let body = questions.compactMap { q -> String? in
                guard let answer = answers[q.question] else { return nil }
                return "\(q.question) \(answer)"
            }.joined(separator: "\n")
            guard !body.isEmpty else { return }
            self.deliverCursorFollowUp("Answering your question:\n\(body)")
        }
    }

    // The turn that asked is usually still running (the CLI never blocked on
    // the question), and send() refuses to overlap turns, so hold the answer
    // until the process exits.
    private func deliverCursorFollowUp(_ text: String) {
        guard isRunning else {
            send(text, echo: false)
            return
        }
        pendingCursorFollowUp = text
    }

    private func flushCursorFollowUp() {
        guard let text = pendingCursorFollowUp else { return }
        pendingCursorFollowUp = nil
        send(text, echo: false)
    }

    private static func cursorToolDisplay(_ toolCall: [String: Any]) -> (icon: String, text: String) {
        if let read = toolCall["readToolCall"] as? [String: Any],
           let args = read["args"] as? [String: Any] {
            let path = (args["path"] as? String).map { ($0 as NSString).lastPathComponent }
            return ("doc.text", "Reading \(path ?? "a file")")
        }
        if let write = toolCall["writeToolCall"] as? [String: Any],
           let args = write["args"] as? [String: Any] {
            let path = (args["path"] as? String).map { ($0 as NSString).lastPathComponent }
            return ("pencil", "Editing \(path ?? "a file")")
        }
        if let edit = toolCall["editToolCall"] as? [String: Any]
            ?? toolCall["searchReplaceToolCall"] as? [String: Any],
           let args = edit["args"] as? [String: Any] {
            let path = (args["path"] as? String ?? args["file_path"] as? String)
                .map { ($0 as NSString).lastPathComponent }
            return ("pencil", "Editing \(path ?? "a file")")
        }
        if let shell = toolCall["shellToolCall"] as? [String: Any]
            ?? toolCall["bashToolCall"] as? [String: Any],
           let args = shell["args"] as? [String: Any] {
            let cmd = args["command"] as? String ?? "a command"
            return ("terminal", "Running \(String(cmd.prefix(60)))")
        }
        if let grep = toolCall["grepToolCall"] as? [String: Any]
            ?? toolCall["globToolCall"] as? [String: Any],
           let args = grep["args"] as? [String: Any] {
            let q = args["pattern"] as? String ?? args["glob"] as? String ?? "the project"
            return ("magnifyingglass", "Searching \(String(q.prefix(40)))")
        }
        if let fn = toolCall["function"] as? [String: Any],
           let name = fn["name"] as? String {
            return ("wrench.fill", name)
        }
        let key = toolCall.keys.first ?? "tool"
        return ("wrench.fill", key.replacingOccurrences(of: "ToolCall", with: ""))
    }

    private static func runCLI(_ executable: String, _ args: [String]) -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = cliEnvironment()
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (1, "") }
        p.waitUntilExit()
        var data = out.fileHandleForReading.readDataToEndOfFile()
        data.append(err.fileHandleForReading.readDataToEndOfFile())
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, text)
    }

    // Mode value (from permissionModes) -> app-server thread/turn config.
    // Mapping mirrors t3code: Ask = untrusted/read-only, Approve for Me =
    // on-request/workspace-write, Full Access = never/danger-full-access.
    private static func codexModeConfig(
        _ value: String?
    ) -> (approvalPolicy: String, sandbox: String, sandboxPolicyType: String) {
        switch value {
        case "workspace-write": return ("on-request", "workspace-write", "workspaceWrite")
        case "danger-full-access": return ("never", "danger-full-access", "dangerFullAccess")
        default: return ("untrusted", "read-only", "readOnly")
        }
    }

    private func handleCodexServerEvent(_ event: CodexAppServer.Event) {
        switch event {
        case .agentDelta(let text):
            appendAssistantDelta(text)
        case .itemCompleted(let item):
            handleCodexItem(item)
        case .turnStarted(let turnID):
            codexActiveTurnID = turnID
        case .turnCompleted(let turnID, let failureMessage):
            // A stopped turn's completion can land after the next turn has
            // started; it must not tear down the newer turn's state.
            if let turnID, codexInterruptedTurnIDs.remove(turnID) != nil { return }
            if let turnID, let active = codexActiveTurnID, turnID != active { return }
            isRunning = false
            codexActiveTurnID = nil
            pendingPermission = nil
            if let failureMessage { presentProviderFailure(failureMessage, provider: .codex) }
        case .serverError(let message):
            presentProviderFailure(message, provider: .codex)
        case .approvalRequest(let kind, let payload, let respond):
            presentCodexApproval(kind: kind, payload: payload, respond: respond)
        }
    }

    private func handleCodexItem(_ item: [String: Any]) {
        let detail = { (name: String) in Self.toolDetail(name: name, arguments: item) }
        switch item["type"] as? String {
        case "agentMessage":
            if let t = item["text"] as? String,
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setStreamingAssistant(t)
            }
        case "commandExecution":
            let cmd = item["command"] as? String ?? "a command"
            let exit = item["exitCode"] as? Int ?? item["exit_code"] as? Int
            appendTool(
                "Running \(String(cmd.prefix(60)))",
                icon: "terminal",
                detail: detail("Shell"),
                step: .command(text: cmd, cwd: item["cwd"] as? String ?? workingDirectory.path, exitCode: exit)
            )
        case "fileChange":
            let changes = (item["changes"] as? [[String: Any]]) ?? []
            let files = changes.map { change in
                FileChange(
                    path: relativeToWorkingDir(change["path"] as? String ?? ""),
                    kind: Self.fileKind(change["kind"] as? String),
                    diff: Self.codexDiff(change)
                )
            }
            let paths = files
                .map { ($0.path as NSString).lastPathComponent }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            appendTool(
                "Editing \(paths.isEmpty ? "files" : paths)",
                icon: "pencil",
                detail: detail("Edit"),
                step: .fileChange(files: files)
            )
        case "webSearch":
            appendTool(
                "Searching \(String((item["query"] as? String ?? "the web").prefix(50)))",
                icon: "globe",
                detail: detail("WebSearch")
            )
        case "mcpToolCall":
            let tool = item["tool"] as? String ?? "a tool"
            let lower = tool.lowercased()
            if lower.contains("screenshot") || lower.contains("image")
                || lower.contains("computer") || lower.contains("zoom") {
                appendTool("Reading screenshot", icon: "camera.viewfinder", detail: detail(tool))
            } else {
                appendTool("Using \(tool)", icon: "wrench.fill", detail: detail(tool))
            }
        default:
            break // userMessage echo, reasoning, plan, todoList
        }
    }

    // Cursor approvals arrive from the hook script, not from the CLI stream,
    // so they are wired up per turn and torn down when the process exits.
    private func beginCursorApprovals() {
        cursorSessionApprovals.removeAll()
        CursorApprovals.beginSession { [weak self] request in
            DispatchQueue.main.async { self?.presentCursorApproval(request) }
        }
    }

    private func presentCursorApproval(_ request: CursorApprovals.Request) {
        if cursorSessionApprovals.contains(request.toolName) {
            CursorApprovals.respond(request.id, allow: true)
            return
        }
        // One prompt at a time: the hook blocks the CLI, so a second request
        // cannot arrive until this one is answered.
        pendingPermission = PermissionRequest(
            title: "Cursor wants to run \(request.toolName)",
            detail: request.detailText,
            canAlways: true
        ) { [weak self] decision in
            switch decision {
            case .allow:
                CursorApprovals.respond(request.id, allow: true)
            case .always:
                self?.cursorSessionApprovals.insert(request.toolName)
                CursorApprovals.respond(request.id, allow: true)
            case .deny:
                CursorApprovals.respond(
                    request.id, allow: false, message: "The user declined this call."
                )
            }
        }
    }

    private func presentCodexApproval(
        kind: CodexAppServer.ApprovalKind,
        payload: [String: Any],
        respond: @escaping (String) -> Void
    ) {
        let title: String
        let detail: String
        switch kind {
        case .command:
            title = "Codex wants to run a command"
            detail = payload["command"] as? String ?? ""
        case .fileChange:
            title = "Codex wants to edit files"
            detail = payload["reason"] as? String
                ?? payload["grantRoot"] as? String
                ?? "Apply proposed file changes"
        }
        pendingPermission = PermissionRequest(title: title, detail: detail, canAlways: true) { decision in
            switch decision {
            case .allow: respond("accept")
            case .always: respond("acceptForSession")
            case .deny: respond("decline")
            }
        }
    }

    // MARK: - Permission / question responses (UI entry points)

    func respondPermission(_ decision: PermissionDecision) {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        let summary = String(request.detail.prefix(60))
        appendTool(decision == .deny ? "Denied: \(summary)" : "Allowed: \(summary)", icon: "shield")
        request.respond(decision)
    }

    func answerQuestion(_ answer: String) {
        guard var qr = pendingQuestion else { return }
        questionSelection = []
        questionDraft = ""
        qr.answers[qr.current.question] = answer
        messages.append(ChatMessage(role: .user, text: answer))
        if qr.index + 1 < qr.questions.count {
            qr.index += 1
            pendingQuestion = qr
        } else {
            pendingQuestion = nil
            qr.respond(qr.answers)
        }
    }

    func cancel() {
        queueDrainSuspended = true
        queuePaused = !queuedMessages.isEmpty
        // A pending approval must be answered before tearing the turn down,
        // otherwise the CLI side is left hanging on the request.
        if let request = pendingPermission {
            pendingPermission = nil
            request.respond(.deny)
        }
        pendingQuestion = nil
        pendingCursorFollowUp = nil
        switch provider {
        case .claude, .cursor:
            if process != nil { expectingProcessExit = true }
            process?.terminate()
        case .codex:
            if let codexThreadID, let codexActiveTurnID {
                codexInterruptedTurnIDs.insert(codexActiveTurnID)
                codexServer.interruptTurn(threadID: codexThreadID, turnID: codexActiveTurnID)
            }
            codexActiveTurnID = nil
            isRunning = false
        case .chatgpt:
            ChatGPTWeb.shared.cancel()
            isRunning = false
        }
    }

    func reset() {
        cancel()
        archiveCurrentIfNeeded()
        transcriptEpoch += 1
        currentArchiveID = nil
        lastRunSettings = nil
        messages.removeAll()
        attachments.removeAll()
        queuedMessages.removeAll()
        queuedMessageBeingEditedID = nil
        queuePaused = false
        queueDrainSuspended = false
        usageLimit = nil
        claudeSessionID = nil
        codexThreadID = nil
        chatgptThreadID = nil
        cursorSessionID = nil
    }

    func load(_ chat: ChatArchive) {
        Telemetry.record("chat_restored", ["provider": chat.provider.rawValue])
        isRestoringChat = true
        defer { isRestoringChat = false }
        transcriptEpoch += 1
        currentArchiveID = chat.id
        lastTouchedAt = chat.date
        messages = chat.messages
        draft = chat.draft ?? ""
        attachments = (chat.pendingAttachmentPaths ?? []).map {
            AppPaths.relocatedManagedURL(for: URL(fileURLWithPath: $0))
        }
        queuedMessages = chat.queuedMessages ?? []
        queuedMessageBeingEditedID = nil
        queuePaused = !queuedMessages.isEmpty
        queueDrainSuspended = !queuedMessages.isEmpty
        provider = chat.provider
        usageLimit = nil
        claudeSessionID = chat.claudeSessionID
        codexThreadID = chat.codexThreadID
        chatgptThreadID = chat.chatgptThreadID
        cursorSessionID = chat.cursorSessionID
        lastRunSettings = chat.settings
        if let settings = chat.pickerSettings ?? chat.settings {
            // Restore only the chat's own provider slot; the other providers'
            // choices are unrelated to this chat.
            apply(settings.model, into: &modelChoice)
            apply(settings.mode, into: &modeChoice)
            apply(settings.effort, into: &effortChoice)
            apply(settings.fastMode, into: &fastModeChoice)
            if provider == .cursor,
               !contextVersions(for: provider).isEmpty {
                setContextVersion(settings.contextVersion ?? "regular", for: provider)
            }
        }
        if let path = chat.workingDirectory {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                workingDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    // nil = the archived chat used the provider default, so clear the key
    // (missing key means "no flag" throughout these dictionaries).
    private func apply<V>(_ value: V?, into choice: inout [AgentProvider: V]) {
        if let value {
            choice[provider] = value
        } else {
            choice.removeValue(forKey: provider)
        }
    }

    func deleteChat(_ id: UUID) {
        if currentArchiveID == id { currentArchiveID = nil }
        ChatArchiveStore.shared.delete(id)
    }

    func archiveCurrentIfNeeded() {
        guard messages.contains(where: { $0.role == .user })
                || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
                || !queuedMessages.isEmpty
        else { return }
        if currentArchiveID == nil { currentArchiveID = UUID() }
        let draftTitle = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = messages.first(where: { $0.role == .user })
            .map { String($0.text.prefix(60)) }
            ?? (draftTitle.isEmpty ? "Draft" : String(draftTitle.prefix(60)))
        let archive = ChatArchive(
            id: currentArchiveID!,
            title: title,
            provider: provider,
            messages: messages,
            claudeSessionID: claudeSessionID,
            codexThreadID: codexThreadID,
            chatgptThreadID: chatgptThreadID,
            cursorSessionID: cursorSessionID,
            workingDirectory: workingDirectory.path,
            settings: lastRunSettings,
            pickerSettings: ChatSettings(
                model: modelChoice[provider],
                mode: modeChoice[provider],
                effort: effortChoice[provider],
                fastMode: fastModeChoice[provider],
                contextVersion: effectiveContextVersion(for: provider)
            ),
            draft: draft.isEmpty ? nil : draft,
            pendingAttachmentPaths: attachments.isEmpty ? nil : attachments.map(\.path),
            queuedMessages: queuedMessages.isEmpty ? nil : queuedMessages,
            date: lastTouchedAt
        )
        ChatArchiveStore.shared.upsert(archive)
    }

    // MARK: - ChatGPT embedded web view (ChatGPTWeb.swift)

    private func sendViaChatGPTWeb(_ text: String, files: [URL]) {
        isRunning = true
        ChatGPTWeb.shared.send(text, thread: chatgptThreadID, files: files) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                switch event {
                case .status(let t):
                    let icon = t == "Reading screenshot" ? "camera.viewfinder" : "globe"
                    self.updateTool(t, icon: icon)
                case .thread(let id):
                    self.chatgptThreadID = id
                case .partial(let t), .message(let t):
                    self.setStreamingAssistant(t)
                case .error(let m):
                    self.isRunning = false
                    Telemetry.record("error", [
                        "domain": "provider.chatgpt",
                        "kind": ChatGPTWeb.telemetryKind(forSendError: m),
                    ])
                    self.appendError("Message failed — \(m)\nYour message was not sent.")
                case .replyError(let m):
                    self.isRunning = false
                    Telemetry.record("error", [
                        "domain": "provider.chatgpt",
                        "kind": ChatGPTWeb.telemetryKind(forReplyError: m),
                    ])
                    self.appendError("Reply failed — \(m)\nYour message was sent, but the reply couldn't be read.")
                case .limit(let detail, let uploadsOnly):
                    self.isRunning = false
                    Telemetry.record("error", ["domain": "provider.chatgpt", "kind": "usage_limit"])
                    // The notice says the message wasn't sent — make the
                    // transcript and composer agree: withdraw the optimistic
                    // user bubble (and this turn's tool chips) and put the
                    // text and files back.
                    if let idx = self.messages.lastIndex(where: { $0.role == .user && $0.text == text }) {
                        self.messages.removeSubrange(idx...)
                    }
                    if self.draft.isEmpty { self.draft = text }
                    for file in files where !self.attachments.contains(file) {
                        self.attachments.append(file)
                    }
                    self.usageLimit = ProviderLimitNotice(
                        provider: .chatgpt,
                        kind: uploadsOnly ? .uploads : .usage,
                        providerDetail: Self.conciseLimitDetail(detail)
                    )
                case .done:
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: - Claude stream-json events

    private func handleClaudeEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "system":
            if claudeSessionID == nil { claudeSessionID = event["session_id"] as? String }
        case "stream_event":
            // Token-level deltas from --include-partial-messages.
            guard let ev = event["event"] as? [String: Any],
                  ev["type"] as? String == "content_block_delta",
                  let delta = ev["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            appendAssistantDelta(t)
        case "assistant":
            guard let message = event["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let texts = content.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let t = block["text"] as? String,
                      !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return t
            }
            if !texts.isEmpty {
                // The full message replaces whatever the deltas accumulated,
                // so streaming never double-prints.
                setStreamingAssistant(texts.joined(separator: "\n\n"))
            }
            for block in content where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any]
                let display = Self.claudeToolDisplay(name: name, input: input)
                appendTool(
                    display.text,
                    icon: display.icon,
                    detail: Self.toolDetail(name: name, arguments: input),
                    step: claudeStep(name: name, input: input)
                )
            }
        case "control_request":
            guard let requestID = event["request_id"] as? String,
                  let request = event["request"] as? [String: Any] else { return }
            handleClaudeControlRequest(requestID, request)
        case "result":
            // Resumed runs get a fresh session id; always track the latest.
            if let id = event["session_id"] as? String { claudeSessionID = id }
            if event["is_error"] as? Bool == true,
               let result = event["result"] as? String,
               !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                presentProviderFailure(result, provider: .claude)
            }
            // The turn is over; closing stdin lets the process exit.
            try? claudeStdin?.close()
            claudeStdin = nil
        default:
            break
        }
    }

    // The CLI blocks on these until we write a control_response line.
    private func handleClaudeControlRequest(_ requestID: String, _ request: [String: Any]) {
        guard request["subtype"] as? String == "can_use_tool" else {
            writeClaudeLine([
                "type": "control_response",
                "response": ["subtype": "error", "request_id": requestID,
                             "error": "unsupported control request"],
            ])
            return
        }
        let toolName = request["tool_name"] as? String ?? "a tool"
        let input = request["input"] as? [String: Any] ?? [:]

        if toolName == "AskUserQuestion" {
            presentClaudeQuestions(input, requestID: requestID)
            return
        }

        let display = Self.permissionSummary(
            toolName: toolName,
            displayName: request["display_name"] as? String,
            input: input
        )
        let suggestions = request["permission_suggestions"]
        pendingPermission = PermissionRequest(
            title: display.title,
            detail: display.detail,
            canAlways: suggestions != nil
        ) { [weak self] decision in
            guard let self else { return }
            switch decision {
            case .allow:
                self.writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": input])
            case .always:
                var inner: [String: Any] = ["behavior": "allow", "updatedInput": input]
                if let suggestions { inner["updatedPermissions"] = suggestions }
                self.writeClaudeControlResponse(requestID, inner)
            case .deny:
                self.writeClaudeControlResponse(
                    requestID,
                    ["behavior": "deny", "message": "User declined tool execution."]
                )
            }
        }
    }

    private static func permissionSummary(
        toolName: String,
        displayName: String?,
        input: [String: Any]
    ) -> (title: String, detail: String) {
        func str(_ key: String) -> String? { input[key] as? String }
        func fileName(_ path: String?) -> String? {
            path.map { ($0 as NSString).lastPathComponent }
        }
        switch toolName {
        case "Bash":
            return ("Claude wants to run a command", str("command") ?? "")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ("Claude wants to edit \(fileName(str("file_path")) ?? "a file")",
                    str("file_path") ?? "")
        case "Read", "NotebookRead":
            return ("Claude wants to read \(fileName(str("file_path")) ?? "a file")",
                    str("file_path") ?? "")
        case "WebFetch", "WebSearch":
            return ("Claude wants to browse the web", str("url") ?? str("query") ?? "")
        default:
            let compact = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ("Claude wants to use \(displayName ?? toolName)", String(compact.prefix(300)))
        }
    }

    private func presentClaudeQuestions(_ input: [String: Any], requestID: String) {
        let questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
            AgentQuestion(
                header: q["header"] as? String ?? "Question",
                question: q["question"] as? String ?? "",
                options: (q["options"] as? [[String: Any]] ?? []).map {
                    AgentQuestionOption(
                        label: $0["label"] as? String ?? "",
                        description: $0["description"] as? String ?? ""
                    )
                },
                multiSelect: q["multiSelect"] as? Bool ?? false
            )
        }
        guard !questions.isEmpty else {
            writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": input])
            return
        }
        pendingQuestion = QuestionRequest(questions: questions) { [weak self] answers in
            var updated = input
            updated["answers"] = answers
            self?.writeClaudeControlResponse(requestID, ["behavior": "allow", "updatedInput": updated])
        }
    }

    // Human-readable activity line per tool call: an SF Symbol plus a verb,
    // e.g. "Editing Views.swift", "Running swift build", "Looking at your screen".
    private static func claudeToolDisplay(name: String, input: [String: Any]?) -> (icon: String, text: String) {
        func detail(_ keys: [String]) -> String? {
            keys.compactMap { input?[$0] as? String }.first { !$0.isEmpty }
        }
        func fileName(_ path: String?) -> String? {
            path.map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Read", "NotebookRead":
            return ("doc.text", "Reading \(fileName(detail(["file_path"])) ?? "a file")")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return ("pencil", "Editing \(fileName(detail(["file_path"])) ?? "a file")")
        case "Bash":
            return ("terminal", "Running \(String(detail(["command"])?.prefix(60) ?? "a command"))")
        case "Grep", "Glob", "LS":
            return ("magnifyingglass", "Searching \(String(detail(["pattern", "path"])?.prefix(40) ?? "the project"))")
        case "WebSearch", "WebFetch":
            return ("globe", "Browsing \(String(detail(["url", "query"])?.prefix(50) ?? "the web"))")
        case "TodoWrite", "TaskCreate", "TaskUpdate":
            return ("checklist", "Updating the plan")
        case "Task", "Agent":
            return ("person.2", "Running a subagent")
        default:
            let lower = name.lowercased()
            if lower.contains("screenshot") || lower.contains("computer") || lower.contains("zoom") {
                return ("camera.viewfinder", "Reading screenshot")
            }
            if lower.contains("click") || lower.contains("type") || lower.contains("key") || lower.contains("scroll") {
                return ("cursorarrow.click.2", "Controlling the screen")
            }
            let d = detail(["command", "file_path", "pattern", "path", "url", "description", "query"])
            return ("wrench.fill", d.map { "\(name) · \(String($0.prefix(50)))" } ?? name)
        }
    }

    // MARK: - Message helpers

    // Streaming: grow the trailing assistant bubble token by token.
    private func appendAssistantDelta(_ text: String) {
        turnChars += text.count
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text += text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    // Streaming: replace the trailing assistant bubble with the full text.
    private func setStreamingAssistant(_ text: String) {
        turnChars = max(turnChars, text.count)
        if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text = text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
        }
    }

    private func appendTool(
        _ text: String,
        icon: String = "wrench.fill",
        detail: String? = nil,
        step: StepPayload? = nil
    ) {
        messages.append(ChatMessage(role: .tool, text: text, icon: icon, detail: detail, step: step))
    }

    // Shorten an absolute path to one relative to the chat's working directory
    // so steps read as "Sources/Eave/AppState.swift", not a home-dir path.
    func relativeToWorkingDir(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let base = workingDirectory.standardizedFileURL.path
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        if full == base { return (full as NSString).lastPathComponent }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : path
    }

    private static func fileKind(_ raw: String?) -> FileChange.Kind {
        switch raw?.lowercased() {
        case "add", "added", "create", "created", "new": return .create
        case "delete", "deleted", "remove", "removed": return .delete
        default: return .edit
        }
    }

    // Codex change entries carry the unified diff under one of a few key names.
    private static func codexDiff(_ change: [String: Any]) -> String? {
        for key in ["diff", "unifiedDiff", "unified_diff", "patch"] {
            if let d = change[key] as? String, !d.isEmpty { return d }
        }
        return nil
    }

    // Claude reports edits as find/replace (no line numbers), commands via Bash.
    private func claudeStep(name: String, input: [String: Any]?) -> StepPayload? {
        guard let input else { return nil }
        switch name {
        case "Bash":
            guard let cmd = input["command"] as? String else { return nil }
            return .command(text: cmd, cwd: workingDirectory.path, exitCode: nil)
        case "Edit":
            guard let path = input["file_path"] as? String else { return nil }
            let diff = DiffParser.replaceDiff(
                old: input["old_string"] as? String ?? "",
                new: input["new_string"] as? String ?? ""
            )
            return .fileChange(files: [FileChange(path: relativeToWorkingDir(path), kind: .edit, diff: diff)])
        case "MultiEdit":
            guard let path = input["file_path"] as? String else { return nil }
            let diff = ((input["edits"] as? [[String: Any]]) ?? []).map {
                DiffParser.replaceDiff(old: $0["old_string"] as? String ?? "",
                                       new: $0["new_string"] as? String ?? "")
            }.joined(separator: "\n")
            return .fileChange(files: [FileChange(path: relativeToWorkingDir(path), kind: .edit, diff: diff)])
        case "Write":
            guard let path = input["file_path"] as? String else { return nil }
            let diff = DiffParser.replaceDiff(old: "", new: input["content"] as? String ?? "")
            return .fileChange(files: [FileChange(path: relativeToWorkingDir(path), kind: .create, diff: diff)])
        default:
            return nil
        }
    }

    // Cursor tool calls nest their args under a per-tool key.
    private func cursorStep(_ toolCall: [String: Any]) -> StepPayload? {
        if let shell = (toolCall["shellToolCall"] ?? toolCall["bashToolCall"]) as? [String: Any],
           let args = shell["args"] as? [String: Any],
           let cmd = args["command"] as? String {
            return .command(text: cmd, cwd: workingDirectory.path, exitCode: nil)
        }
        if let write = toolCall["writeToolCall"] as? [String: Any],
           let args = write["args"] as? [String: Any],
           let path = args["path"] as? String ?? args["file_path"] as? String {
            let content = args["contents"] as? String ?? args["content"] as? String ?? ""
            return .fileChange(files: [FileChange(path: relativeToWorkingDir(path), kind: .create,
                                                  diff: DiffParser.replaceDiff(old: "", new: content))])
        }
        if let edit = (toolCall["editToolCall"] ?? toolCall["searchReplaceToolCall"]) as? [String: Any],
           let args = edit["args"] as? [String: Any],
           let path = args["path"] as? String ?? args["file_path"] as? String {
            let old = args["old_string"] as? String ?? args["oldString"] as? String ?? ""
            let new = args["new_string"] as? String ?? args["newString"] as? String ?? ""
            let diff = old.isEmpty && new.isEmpty ? nil : DiffParser.replaceDiff(old: old, new: new)
            return .fileChange(files: [FileChange(path: relativeToWorkingDir(path), kind: .edit, diff: diff)])
        }
        return nil
    }

    // The exact call behind a step row: readable header plus the raw
    // arguments, so "Running whoami" can be opened to show the real command.
    static func toolDetail(name: String, arguments: Any?) -> String {
        var out = name
        if let command = (arguments as? [String: Any])?["command"] {
            let text = (command as? String) ?? String(describing: command)
            out += "\n\n$ \(text)"
        }
        if let arguments, let json = prettyJSON(arguments) {
            out += "\n\n\(json)"
        }
        return out
    }

    private static func prettyJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // Browser phases are one live activity row, not a separate step for each
    // internal upload/navigation transition.
    private func updateTool(_ text: String, icon: String) {
        if let last = messages.indices.last, messages[last].role == .tool {
            messages[last].text = text
            messages[last].icon = icon
        } else {
            appendTool(text, icon: icon)
        }
    }

    private func appendError(_ text: String, provider errorProvider: AgentProvider? = nil) {
        // Codex emits the same failure as both an `error` and a `turn.failed`.
        let text = Self.withLoginHint(text, provider: errorProvider ?? provider)
        if messages.last?.role == .error, messages.last?.text == text { return }
        messages.append(ChatMessage(role: .error, text: text))
    }

    private func presentProviderFailure(_ text: String, provider: AgentProvider) {
        // Classified only — never forward `text` (provider stderr can contain paths).
        Telemetry.record("error", [
            "domain": "provider.\(provider.rawValue)",
            "kind": Self.isUsageLimit(text) ? "usage_limit" : "failure",
        ])
        if Self.isUsageLimit(text) {
            // Providers report one limit through both their structured stream
            // and process termination — one notice is enough. And a trailing
            // event from a provider the user already switched away from must
            // not raise a stale overlay over the new provider's session.
            guard usageLimit?.provider != provider, provider == self.provider else { return }
            usageLimit = ProviderLimitNotice(
                provider: provider,
                kind: .usage,
                providerDetail: Self.conciseLimitDetail(text)
            )
            return
        }
        // A distinct non-limit failure is real information even while a limit
        // notice is up; appendError's exact-text dedup handles true repeats.
        appendError(text, provider: provider)
    }

    // Provider wording changes frequently, so match the stable semantic forms
    // seen across Claude, Codex, and Cursor rather than one exact sentence.
    // Deliberately avoid a bare "limit" match, "token limit", and transient
    // 429 phrasings ("too many requests", "rate limit exceeded"): file-size,
    // context-window, and momentary-throttle errors should remain ordinary
    // errors, not be mislabeled as a durable account usage cap.
    static func isUsageLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            #"insufficient[_ -]?quota"#,
            #"resource[_ -]?exhausted"#,
            #"usage[_ -]?(?:limit|cap)"#,
            #"quota.{0,40}(?:reached|exceeded|exhausted|depleted)"#,
            #"(?:reached|hit|exceeded).{0,50}(?:usage|weekly|monthly|daily|spend|plan|request).{0,20}limit"#,
            #"(?:usage|weekly|monthly|daily|spend|plan|request).{0,20}limit.{0,20}(?:reached|exceeded|exhausted|depleted)"#,
            #"(?:out of|no|zero).{0,20}(?:usage|credits).{0,20}(?:left|remaining|available)?"#,
            // Tokens/requests need the trailing word: "out of tokens" alone is
            // how context-window errors read.
            #"(?:out of|no|zero).{0,20}(?:tokens|requests).{0,12}(?:left|remaining|available)"#,
            #"(?:credit|balance).{0,40}(?:exhausted|depleted|too low|insufficient)"#,
            #"(?:limit|quota).{0,50}reset(?:s|ting)?(?: at| in| on)?"#,
            // Lookbehind keeps the trailing 0 of "1000 tokens left" from
            // matching as a zero balance.
            #"(?<![\d.,])0 ?(?:weighted )?tokens?.{0,12}left"#,
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }

    private static func conciseLimitDetail(_ text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let line = lines.first(where: isUsageLimit) ?? lines.first else { return nil }
        // Avoid putting a JSON/log dump onto the screen. The generic copy is
        // enough when the provider did not return one short human sentence.
        guard line.count <= 240, !line.hasPrefix("{"), !line.hasPrefix("[") else { return nil }
        return line
    }

    // If a CLI failure looks like an auth problem, append the Terminal command.
    private static func withLoginHint(_ text: String, provider: AgentProvider) -> String {
        let lower = text.lowercased()
        let authy = lower.contains("not logged")
            || lower.contains("not authenticated")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
            || lower.contains("please log in")
            || lower.contains("login required")
            || (lower.contains("401") && lower.contains("auth"))
        guard authy else { return text }
        let hint: String
        switch provider {
        case .claude: hint = "In Terminal run: claude auth login"
        case .codex: hint = "In Terminal run: codex login"
        case .cursor: hint = "In Terminal run: agent login"
        case .chatgpt: return text
        }
        if text.contains(hint) { return text }
        return text + "\n" + hint
    }
}
