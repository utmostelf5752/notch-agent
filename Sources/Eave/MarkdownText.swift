import AppKit
import SwiftUI
import WebKit

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
    case table(headers: [String], rows: [[String]])
    case image(alt: String, url: String)
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

            if let image = parseImageLine(trimmed) {
                blocks.append(.image(alt: image.alt, url: image.url))
                i += 1
                continue
            }

            if isTableRow(trimmed),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = splitTableRow(trimmed)
                i += 2 // skip header + separator
                var rows: [[String]] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isTableRow(t) { break }
                    var cells = splitTableRow(t)
                    while cells.count < headers.count { cells.append("") }
                    if cells.count > headers.count {
                        cells = Array(cells.prefix(headers.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
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
                    || t.hasPrefix(">") || parseListItem(t) != nil
                    || parseImageLine(t) != nil
                    || (isTableRow(t) && i + 1 < lines.count
                        && isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces))) {
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

    private static func isTableRow(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.count >= 3
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard isTableRow(line) else { return false }
        let inner = line.dropFirst().dropLast()
        let cells = inner.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let s = cell.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return false }
            return s.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var inner = line
        if inner.hasPrefix("|") { inner = String(inner.dropFirst()) }
        if inner.hasSuffix("|") { inner = String(inner.dropLast()) }
        return inner.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    /// Whole-line image: `![alt](url)` — url may be a long data: URI.
    private static func parseImageLine(_ line: String) -> (alt: String, url: String)? {
        guard line.hasPrefix("![") else { return nil }
        guard let altEnd = line.firstIndex(of: "]") else { return nil }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        let alt = String(line[altStart..<altEnd])
        var i = line.index(after: altEnd)
        guard i < line.endIndex, line[i] == "(" else { return nil }
        i = line.index(after: i)
        guard line.last == ")" else { return nil }
        let url = String(line[i..<line.index(before: line.endIndex)])
        guard !url.isEmpty else { return nil }
        return (alt, url.replacingOccurrences(of: "%29", with: ")"))
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

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows, scale: scale)

        case .image(let alt, let url):
            MarkdownImageView(alt: alt, url: url, scale: scale)
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

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    var scale: CGFloat = 1

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14 * scale, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        cell(header, size: 11 * scale, weight: .semibold, opacity: 0.5)
                    }
                }
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .gridCellColumns(max(headers.count, 1))
                    .padding(.vertical, 4 * scale)

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            cell(value, size: 12 * scale, weight: .regular, opacity: 0.9)
                        }
                    }
                    .padding(.vertical, 3 * scale)
                }
            }
            .padding(.vertical, 2 * scale)
        }
    }

    private func cell(_ raw: String, size: CGFloat, weight: Font.Weight, opacity: Double) -> some View {
        Text(Markdown.inlineAttributed(raw))
            .font(.system(size: size, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
            .textSelection(.enabled)
            .fixedSize(horizontal: true, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownImageView: View {
    let alt: String
    let url: String
    var scale: CGFloat = 1

    var body: some View {
        Group {
            if let image = Self.bitmapImage(from: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 280 * scale, alignment: .leading)
            } else if let svg = Self.svgMarkup(from: url) {
                SVGWebView(svg: svg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220 * scale)
            } else if let remote = URL(string: url),
                      let scheme = remote.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" {
                AsyncImage(url: remote) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 280 * scale, alignment: .leading)
                    case .failure:
                        fallback
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8 * scale)
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }

    private var fallback: some View {
        Text(alt.isEmpty ? "Image" : alt)
            .font(.system(size: 12 * scale))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func bitmapImage(from urlString: String) -> NSImage? {
        guard urlString.hasPrefix("data:image/"),
              !urlString.hasPrefix("data:image/svg+xml") else { return nil }
        guard let comma = urlString.firstIndex(of: ",") else { return nil }
        let meta = urlString[..<comma]
        let payload = String(urlString[urlString.index(after: comma)...])
        let data: Data?
        if meta.contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let data, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        return image
    }

    private static func svgMarkup(from urlString: String) -> String? {
        guard urlString.hasPrefix("data:image/svg+xml") else { return nil }
        guard let comma = urlString.firstIndex(of: ",") else { return nil }
        let meta = urlString[..<comma]
        let payload = String(urlString[urlString.index(after: comma)...])
        if meta.contains(";base64") {
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
                  let xml = String(data: data, encoding: .utf8) else { return nil }
            return xml
        }
        return payload.removingPercentEncoding
    }
}

private struct SVGWebView: NSViewRepresentable {
    let svg: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        load(svg, into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(svg, into: webView)
    }

    private func load(_ svg: String, into webView: WKWebView) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
          svg { display: block; width: 100%; height: auto; max-height: 100vh; }
        </style></head><body>\(svg)</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
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
