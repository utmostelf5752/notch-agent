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
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
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

    init(role: Role, text: String, icon: String? = nil, attachments: [URL] = []) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.icon = icon
        self.attachmentPaths = attachments.isEmpty ? nil : attachments.map(\.path)
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
    let date: Date
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
            AgentOption(label: "Fable 5", short: "Fable 5", value: "claude-fable-5"),
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
            AgentOption(label: "Opus 4.8", short: "Opus 4.8", value: "claude-opus-4-8-thinking-high"),
            AgentOption(label: "Opus 4.8 Fast", short: "Opus 4.8 Fast", value: "claude-opus-4-8-thinking-high-fast"),
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
        return models.map { model in
            AgentModelMenuGroup(
                label: model.label,
                variants: [.init(label: model.label, option: model, fastMode: false)]
            )
        }
    }

    func supportsFastMode(_ model: String?) -> Bool {
        switch self {
        case .claude:
            return model == "claude-opus-4-8"
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

    var isCurrentGeneration: Bool { Self.currentGenerationIDs.contains(id) }

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
    private static let currentGenerationIDs: Set<String> = [
        "auto",
        "composer-2.5",
        "cursor-grok-4.5",
        "claude-opus-4-8",
        "claude-sonnet-5",
        "claude-fable-5",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
        "gpt-5.3-codex",
        "gemini-3.1-pro",
        "gemini-3.5-flash",
        "kimi-k2.7-code",
        "glm-5.2",
    ]

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

struct QuestionRequest {
    let questions: [AgentQuestion]
    var index = 0
    var answers: [String: String] = [:]
    let respond: ([String: String]) -> Void

    var current: AgentQuestion { questions[index] }
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
            }
        }
    }
    @Published var draft = ""
    // Background-mode telemetry: when the current turn began, and a running
    // character count of streamed output (a cheap, provider-agnostic token
    // estimate ~= chars/4). Both reset at the start of each turn. lastTurnDuration
    // is frozen when the turn ends so the completed pill can show the final time.
    @Published var turnStartedAt: Date?
    @Published var turnChars = 0
    @Published var lastTurnDuration: TimeInterval = 0
    @Published var usageLimit: ProviderLimitNotice?
    @Published var provider: AgentProvider = .claude {
        didSet {
            if usageLimit?.provider != provider { usageLimit = nil }
        }
    }
    // Missing key = provider default (no flag). Keyed per provider so
    // switching between Claude and Codex remembers each one's choices.
    @Published var modelChoice: [AgentProvider: String] = [
        .claude: "claude-sonnet-5",
        .codex: "gpt-5.6-terra",
        .cursor: "composer-2.5",
    ]
    @Published var modeChoice: [AgentProvider: String] = [
        .claude: "auto",
        .cursor: "force",
    ]
    // Missing key = the CLI's own default effort; set once the user picks a
    // level. Keyed per provider like modelChoice.
    @Published var effortChoice: [AgentProvider: String] = [:]
    // Speed is session state for every CLI. Cursor's raw `-fast` id is chosen
    // only when a request launches.
    @Published var fastModeChoice: [AgentProvider: Bool] = [:]
    @Published private(set) var cursorModelFamilies = CursorModelFamily.build(
        from: AgentProvider.cursor.models
    )
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
    @Published var pastChats: [ChatArchive] = []
    private static let maxPastChats = 10
    private static let cursorContextDefaultsKey = "Eave.cursorContextChoice"
    // The history entry the live session was restored from, if any. Keeps a
    // reopened chat listed (and in place) in history; archiving updates that
    // entry instead of inserting a duplicate.
    private var currentArchiveID: UUID?

    private static let chatsURL = AppPaths.supportDirectory.appendingPathComponent("chats.json")

    init() {
        AppPaths.migrateLegacyScreenshots()
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
        if let data = try? Data(contentsOf: Self.chatsURL),
           let chats = try? JSONDecoder().decode([ChatArchive].self, from: data) {
            pastChats = Array(chats.prefix(Self.maxPastChats))
        }
        refreshCursorModelCatalog()
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
                messages.append(ChatMessage(
                    role: .error,
                    text: "Couldn't convert \(url.lastPathComponent) to JPEG — \(error.localizedDescription)."
                ))
            }
        }
    }

    func modelMenuGroups(for provider: AgentProvider) -> [AgentModelMenuGroup] {
        provider == .cursor
            ? cursorModelFamilies.filter(\.isCurrentGeneration).map(\.menuGroup)
            : provider.modelMenuGroups
    }

    func otherModelMenuGroups(for provider: AgentProvider) -> [AgentModelMenuGroup] {
        guard provider == .cursor else { return [] }
        return cursorModelFamilies.filter { !$0.isCurrentGeneration }.map(\.menuGroup)
    }

    func models(for provider: AgentProvider) -> [AgentOption] {
        if provider != .cursor { return provider.models }
        return cursorModelFamilies.map(\.option)
    }

    func efforts(for provider: AgentProvider) -> [AgentOption] {
        guard provider == .cursor else { return provider.efforts(for: modelChoice[provider]) }
        return selectedCursorFamily?.effortOptions ?? []
    }

    func defaultEffortValue(for provider: AgentProvider) -> String? {
        provider == .cursor ? selectedCursorFamily?.defaultControlValue : provider.defaultEffortValue
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
        return provider.supportsFastMode(selectedModel)
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

    private func persistChats() {
        if let data = try? JSONEncoder().encode(pastChats) {
            try? data.write(to: Self.chatsURL, options: .atomic)
        }
    }
    @Published var workingDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/code")

    private var claudeSessionID: String?
    private var codexThreadID: String?
    private var chatgptThreadID: String?
    private var cursorSessionID: String?
    private var process: Process?
    private var claudeStdin: FileHandle?
    private let codexServer = CodexAppServer()
    private var codexActiveTurnID: String?
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

    func send(_ text: String) {
        guard !isRunning else { return }
        usageLimit = nil
        turnStartedAt = Date()
        turnChars = 0
        let files = attachments
        attachments = []

        messages.append(ChatMessage(role: .user, text: text, attachments: files))

        // A reopened chat sits in place in history until actually continued;
        // the first new message bumps it to the top.
        if let id = currentArchiveID,
           let idx = pastChats.firstIndex(where: { $0.id == id }), idx != 0 {
            pastChats.insert(pastChats.remove(at: idx), at: 0)
            persistChats()
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
                DispatchQueue.main.async { self?.handleClaudeEvent(obj) }
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
                if proc.terminationStatus != 0 {
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
        codexServer.onEvent = { [weak self] event in self?.handleCodexServerEvent(event) }

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
            break // propose-only: no --force
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
                DispatchQueue.main.async { self?.handleCursorEvent(obj) }
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
                if proc.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.presentProviderFailure(msg.isEmpty
                        ? "agent exited with status \(proc.terminationStatus)"
                        : msg, provider: .cursor)
                }
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
        case "tool_call":
            guard event["subtype"] as? String == "started",
                  let toolCall = event["tool_call"] as? [String: Any] else { return }
            let display = Self.cursorToolDisplay(toolCall)
            appendTool(display.text, icon: display.icon)
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
        case .turnCompleted(let failureMessage):
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
        switch item["type"] as? String {
        case "agentMessage":
            if let t = item["text"] as? String,
               !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setStreamingAssistant(t)
            }
        case "commandExecution":
            let cmd = item["command"] as? String ?? "a command"
            appendTool("Running \(String(cmd.prefix(60)))", icon: "terminal")
        case "fileChange":
            let paths = ((item["changes"] as? [[String: Any]]) ?? [])
                .compactMap { $0["path"] as? String }
                .map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
            appendTool("Editing \(paths.isEmpty ? "files" : paths)", icon: "pencil")
        case "webSearch":
            appendTool("Searching \(String((item["query"] as? String ?? "the web").prefix(50)))", icon: "globe")
        case "mcpToolCall":
            let tool = item["tool"] as? String ?? "a tool"
            let lower = tool.lowercased()
            if lower.contains("screenshot") || lower.contains("image")
                || lower.contains("computer") || lower.contains("zoom") {
                appendTool("Reading screenshot", icon: "camera.viewfinder")
            } else {
                appendTool("Using \(tool)", icon: "wrench.fill")
            }
        default:
            break // userMessage echo, reasoning, plan, todoList
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
        // A pending approval must be answered before tearing the turn down,
        // otherwise the CLI side is left hanging on the request.
        if let request = pendingPermission {
            pendingPermission = nil
            request.respond(.deny)
        }
        pendingQuestion = nil
        switch provider {
        case .claude, .cursor:
            process?.terminate()
        case .codex:
            if let codexThreadID, let codexActiveTurnID {
                codexServer.interruptTurn(threadID: codexThreadID, turnID: codexActiveTurnID)
            }
            isRunning = false
        case .chatgpt:
            ChatGPTWeb.shared.cancel()
            isRunning = false
        }
    }

    func reset() {
        cancel()
        archiveCurrentIfNeeded()
        currentArchiveID = nil
        messages.removeAll()
        attachments.removeAll()
        usageLimit = nil
        claudeSessionID = nil
        codexThreadID = nil
        chatgptThreadID = nil
        cursorSessionID = nil
    }

    func restore(_ chat: ChatArchive) {
        cancel()
        archiveCurrentIfNeeded()
        currentArchiveID = chat.id
        messages = chat.messages
        provider = chat.provider
        usageLimit = nil
        claudeSessionID = chat.claudeSessionID
        codexThreadID = chat.codexThreadID
        chatgptThreadID = chat.chatgptThreadID
        cursorSessionID = chat.cursorSessionID
    }

    func deleteChat(_ id: UUID) {
        pastChats.removeAll { $0.id == id }
        if currentArchiveID == id { currentArchiveID = nil }
        persistChats()
    }

    func archiveCurrentIfNeeded() {
        guard messages.contains(where: { $0.role == .user }) else { return }
        let title = messages.first(where: { $0.role == .user })
            .map { String($0.text.prefix(60)) } ?? "Untitled"
        let archive = ChatArchive(
            id: currentArchiveID ?? UUID(),
            title: title,
            provider: provider,
            messages: messages,
            claudeSessionID: claudeSessionID,
            codexThreadID: codexThreadID,
            chatgptThreadID: chatgptThreadID,
            cursorSessionID: cursorSessionID,
            date: Date()
        )
        if let idx = pastChats.firstIndex(where: { $0.id == archive.id }) {
            // The reopened chat is already listed: refresh it in place rather
            // than reinsert, so merely viewing it doesn't reshuffle history.
            // (send() already bumped it to the top if it was continued.)
            if pastChats[idx].messages == archive.messages { return }
            pastChats[idx] = archive
        } else {
            pastChats.insert(archive, at: 0)
        }
        if pastChats.count > Self.maxPastChats {
            pastChats.removeLast(pastChats.count - Self.maxPastChats)
        }
        persistChats()
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
                    self.appendError("Message failed — \(m)\nYour message was not sent.")
                case .replyError(let m):
                    self.isRunning = false
                    self.appendError("Reply failed — \(m)\nYour message was sent, but the reply couldn't be read.")
                case .limit(let detail, let uploadsOnly):
                    self.isRunning = false
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
                let display = Self.claudeToolDisplay(name: name, input: block["input"] as? [String: Any])
                appendTool(display.text, icon: display.icon)
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

    private func appendTool(_ text: String, icon: String = "wrench.fill") {
        messages.append(ChatMessage(role: .tool, text: text, icon: icon))
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
