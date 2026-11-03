import SwiftUI
import UIKit

enum MarkdownBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case list([ListItem])
    case code(String, String)
    case quote(String)
    case table([[String]])
    case rule

    struct ListItem: Hashable {
        let marker: String
        let indent: Int
        let text: String
    }
}

enum MarkdownParser {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let tag = try! NSRegularExpression(pattern: #"<[^>]+>"#)

    static func parse(_ text: String, stripHTML: Bool = false) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [MarkdownBlock.ListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        func flush() {
            if !paragraph.isEmpty {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph = []
            }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] }
            if !table.isEmpty {
                if table.count == 1 { blocks.append(.paragraph(table[0].joined(separator: " | "))) } else { blocks.append(.table(table)) }
                table = []
            }
        }

        var i = 0
        while i < lines.count {
            var line = lines[i]
            if stripHTML { line = clean(line) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang, code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }

            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = heading.firstMatch(in: line, range: range) {
                flush()
                blocks.append(.heading(m.range(at: 1).length, ns.substring(with: m.range(at: 2))))
            } else if ["---", "***", "___"].contains(where: { trimmed.hasPrefix($0) && Set(trimmed).count == 1 }) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty || !items.isEmpty || !quote.isEmpty {
                    let saved = table
                    table = []
                    flush()
                    table = saved
                }
                let cells = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ !$0.isEmpty && Set($0).isSubset(of: Set("-: ")) }) {
                    table.append(cells)
                }
            } else if let m = bullet.firstMatch(in: line, range: range) {
                if !paragraph.isEmpty || !quote.isEmpty || !table.isEmpty {
                    let saved = items
                    items = []
                    flush()
                    items = saved
                }
                let marker = ns.substring(with: m.range(at: 2))
                items.append(.init(marker: marker.first?.isNumber == true ? marker : "•",
                                   indent: m.range(at: 1).length / 2,
                                   text: ns.substring(with: m.range(at: 3))))
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || !items.isEmpty || !table.isEmpty { flush() }
                var q = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] where q.uppercased().hasPrefix("[!\(kind)]") {
                    q = "**\(kind.capitalized)**" + q.dropFirst(kind.count + 3)
                }
                quote.append(q)
            } else if !items.isEmpty && line.hasPrefix("  ") {
                let last = items.removeLast()
                items.append(.init(marker: last.marker, indent: last.indent, text: last.text + " " + trimmed))
            } else {
                if !items.isEmpty || !quote.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return blocks
    }

    static func clean(_ line: String) -> String {
        var s = line
        let ns = s as NSString
        s = image.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        s = tag.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        return s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func inline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    }
}

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var selectable = true
    @Environment(\.theme) private var theme

    init(_ text: String, stripHTML: Bool = false, selectable: Bool = true) {
        blocks = MarkdownParser.parse(text, stripHTML: stripHTML)
        self.selectable = selectable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(MarkdownParser.inline(text))
                .font(.system(size: [26, 22, 19, 17, 16, 15][min(level, 6) - 1], weight: .bold, design: theme.bodyDesign))
                .padding(.top, level <= 2 ? 6 : 2)
                .selectable(selectable)
        case let .paragraph(text):
            Text(MarkdownParser.inline(text))
                .font(.system(.body, design: theme.bodyDesign))
                .fixedSize(horizontal: false, vertical: true)
                .selectable(selectable)
        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(theme.accent)
                            .monospacedDigit()
                        Text(MarkdownParser.inline(item.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .selectable(selectable)
                    }
                    .font(.system(.body, design: theme.bodyDesign))
                    .padding(.leading, CGFloat(item.indent) * 16)
                }
            }
        case let .code(lang, code):
            CodeBlock(language: lang, code: code)
        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent)
                    .frame(width: 3)
                Text(MarkdownParser.inline(text))
                    .font(.system(.body, design: theme.bodyDesign))
                    .foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownParser.inline(cell))
                                    .font(.footnote.weight(index == 0 ? .semibold : .regular))
                                    .lineLimit(4)
                                    .frame(maxWidth: 220, alignment: .leading)
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
                .padding(12)
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: min(theme.radius, 10)))
        case .rule:
            Divider()
        }
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: min(theme.radius, 10)))
        .overlay(RoundedRectangle(cornerRadius: min(theme.radius, 10)).stroke(theme.border))
    }
}

private extension View {
    @ViewBuilder
    func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { self }
    }
}
