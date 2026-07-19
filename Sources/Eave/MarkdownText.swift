import AppKit
import SwiftUI

// Lightweight Markdown for assistant replies (Claude / Codex / ChatGPT / any
// future provider). No package deps — fence-aware block parse + Foundation's
// AttributedString for inline marks. MathText still runs on prose, not code.

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case code(language: String?, code: String)
    case list(ordered: Bool, items: [String])
    case quote(String)
    case rule
}

enum Markdown {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 } // closing fence, if present
                blocks.append(.code(
                    language: lang.isEmpty ? nil : lang,
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                blocks.append(.heading(heading.level, heading.text))
                i += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var parts: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var body = String(t.dropFirst())
                    if body.hasPrefix(" ") { body = String(body.dropFirst()) }
                    parts.append(body)
                    i += 1
                }
                blocks.append(.quote(parts.joined(separator: "\n")))
                continue
            }

            if let listStart = parseListItem(trimmed) {
                var items: [String] = [listStart.text]
                let ordered = listStart.ordered
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    guard let item = parseListItem(t), item.ordered == ordered else { break }
                    items.append(item.text)
                    i += 1
                }
                blocks.append(.list(ordered: ordered, items: items))
                continue
            }

            // Paragraph: gather until a blank line or a block starter.
            var parts: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let t = next.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") || parseHeading(t) != nil || isRule(t)
                    || t.hasPrefix(">") || parseListItem(t) != nil {
                    break
                }
                parts.append(next)
                i += 1
            }
            blocks.append(.paragraph(parts.joined(separator: "\n")))
        }

        return blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1; continue }
            break
        }
        guard level >= 1, level <= 6, line.count > level else { return nil }
        let idx = line.index(line.startIndex, offsetBy: level)
        guard line[idx] == " " else { return nil }
        let text = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let s = line.filter { !$0.isWhitespace }
        guard s.count >= 3 else { return false }
        return s.allSatisfy { $0 == "-" } || s.allSatisfy { $0 == "*" } || s.allSatisfy { $0 == "_" }
    }

    private static func parseListItem(_ line: String) -> (ordered: Bool, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (false, String(line.dropFirst(2)))
        }
        // "1. item"
        var i = line.startIndex
        var digits = 0
        while i < line.endIndex, line[i].isNumber {
            digits += 1
            i = line.index(after: i)
        }
        guard digits > 0, i < line.endIndex, line[i] == "." else { return nil }
        let afterDot = line.index(after: i)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return (true, String(line[line.index(after: afterDot)...]))
    }

    // Inline markdown for prose. Math first so $…$ becomes Unicode before
    // AttributedString sees it; fall back to plain text if parsing fails.
    static func inlineAttributed(_ raw: String) -> AttributedString {
        let prose = MathText.render(raw)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attr = try? AttributedString(markdown: prose, options: options) {
            return attr
        }
        return AttributedString(prose)
    }
}

// Provider-agnostic assistant body: used for every chat role=.assistant path.
struct MarkdownView: View {
    let text: String
    var scale: CGFloat = 1

    var body: some View {
        let blocks = Markdown.parse(text)
        VStack(alignment: .leading, spacing: 8 * scale) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            inlineText(s, size: 13 * scale, weight: .regular)

        case .heading(let level, let s):
            let size: CGFloat = {
                switch level {
                case 1: return 17
                case 2: return 15
                case 3: return 14
                default: return 13
                }
            }() * scale
            inlineText(s, size: size, weight: .semibold)
                .padding(.top, level <= 2 ? 2 * scale : 0)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code, scale: scale)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3 * scale) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6 * scale) {
                        Text(ordered ? "\(idx + 1)." : "•")
                            .font(.system(size: 13 * scale).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 16 * scale, alignment: .trailing)
                        inlineText(item, size: 13 * scale, weight: .regular)
                    }
                }
            }

        case .quote(let s):
            HStack(alignment: .top, spacing: 8 * scale) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 2 * scale)
                inlineText(s, size: 13 * scale, weight: .regular)
                    .foregroundStyle(.white.opacity(0.72))
            }

        case .rule:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 4 * scale)
        }
    }

    private func inlineText(_ raw: String, size: CGFloat, weight: Font.Weight) -> some View {
        Text(Markdown.inlineAttributed(raw))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(0.92))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8 * scale) {
                Text((language?.isEmpty == false ? language! : "code").lowercased())
                    .font(.system(size: 10 * scale, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(4 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.horizontal, 10 * scale)
            .padding(.top, 7 * scale)
            .padding(.bottom, 4 * scale)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5 * scale, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10 * scale)
            .padding(.bottom, 9 * scale)
        }
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}
