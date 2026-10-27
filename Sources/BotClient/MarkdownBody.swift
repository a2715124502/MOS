import SwiftUI
import AppKit

/// Parse completed text once, so scrolling and unrelated streaming updates reuse the same runs.
private enum InlineMarkdown {
    final class Value: NSObject { let text: AttributedString; init(_ text: AttributedString) { self.text = text } }
    static let cache: NSCache<NSString, Value> = {
        let cache = NSCache<NSString, Value>(); cache.countLimit = 3000; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
    static let strong = try! NSRegularExpression(pattern: #"(?<![\\*])\*\*(?=\S)([^\n]+?\S|\S)\*\*(?!\*)"#)
    static func render(_ source: String) -> AttributedString {
        if let value = cache.object(forKey: source as NSString) { return value.text }
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // cmark's punctuation boundaries can leave paired ** visible next to CJK punctuation.
        // Only repair paired residual markers; never strip literal stars or touch inline code.
        let plain = String(result.characters)
        for match in strong.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
            guard let full = Range(match.range, in: plain), let content = Range(match.range(at: 1), in: plain) else { continue }
            func index(_ i: String.Index) -> AttributedString.Index { result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: i)) }
            let fullRange = index(full.lowerBound)..<index(full.upperBound)
            let innerRange = index(content.lowerBound)..<index(content.upperBound)
            guard !result[fullRange].runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else { continue }
            var inner = AttributedString(result[innerRange])
            inner.inlinePresentationIntent = (inner.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
            result.replaceSubrange(fullRange, with: inner)
        }
        cache.setObject(Value(result), forKey: source as NSString, cost: source.utf8.count * 3)
        return result
    }
}

private final class MarkdownDocument: NSObject {
    enum Block {
        case prose(String), heading(String, Int), bullet(String, String), quote(String), rule
        case code(String, String), table([[String]])
    }
    let blocks: [Block]
    private static let cache: NSCache<NSString, MarkdownDocument> = {
        let cache = NSCache<NSString, MarkdownDocument>(); cache.countLimit = 500; cache.totalCostLimit = 4 * 1024 * 1024; return cache
    }()
    static func read(_ text: String) -> MarkdownDocument {
        if let document = cache.object(forKey: text as NSString) { return document }
        let document = MarkdownDocument(text)
        cache.setObject(document, forKey: text as NSString, cost: text.utf8.count * 2)
        return document
    }
    static func cells(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", escaped = false, code = false
        for c in line.trimmingCharacters(in: .whitespaces) {
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { cell.append(c); escaped = true; continue }
            if c == "`" { code.toggle() }
            if c == "|" && !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first == "" { cells.removeFirst() }; if cells.last == "" { cells.removeLast() }
        return cells
    }
    init(_ source: String) {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = [], i = 0
        func flush() { if !paragraph.isEmpty { blocks.append(.prose(paragraph.joined(separator: "\n"))); paragraph = [] } }
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let marker = line.first!, count = line.prefix(while: { $0 == marker }).count
                let language = String(line.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []; i += 1
                while i < lines.count {
                    let end = lines[i].trimmingCharacters(in: .whitespaces)
                    if end.prefix(while: { $0 == marker }).count >= count && end.allSatisfy({ $0 == marker }) { i += 1; break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n"))); continue
            }
            if i + 1 < lines.count, line.contains("|") {
                let separator = Self.cells(lines[i + 1])
                if !separator.isEmpty, separator.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                    flush(); var rows = [Self.cells(line)]; i += 2
                    while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(Self.cells(lines[i])); i += 1 }
                    blocks.append(.table(rows)); continue
                }
            }
            if line.isEmpty { flush() }
            else if ["---", "***", "___"].contains(line) { flush(); blocks.append(.rule) }
            else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); blocks.append(.heading(String(line[range.upperBound...]), line.prefix(while: { $0 == "#" }).count))
            } else if line.hasPrefix(">") { flush(); blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))) }
            else if let range = line.range(of: #"^(?:[-*+] |\d+[.)] )"#, options: .regularExpression) {
                flush(); let prefix = String(line[range]); let ordered = prefix.first?.isNumber == true
                blocks.append(.bullet(ordered ? prefix.trimmingCharacters(in: .whitespaces) : "•", String(line[range.upperBound...])))
            } else { paragraph.append(lines[i]) }
            i += 1
        }
        flush(); self.blocks = blocks
    }
}

struct MarkdownBody: View {
    let text: String
    var user: Bool
    var body: some View {
        Group {
            if user { Text(verbatim: text).textSelection(.enabled) }
            else {
                let blocks = MarkdownDocument.read(text).blocks
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks.indices, id: \.self) { index in
                        switch blocks[index] {
                        case .prose(let value): inline(value)
                        case .heading(let value, let level): inline(value).font(.ui(size: level <= 2 ? 16 : 14, weight: .semibold)).padding(.top, 4)
                        case .bullet(let marker, let value): HStack(alignment: .firstTextBaseline, spacing: 9) { Text(marker).foregroundStyle(Color.muted); inline(value) }
                        case .quote(let value): HStack(spacing: 10) { Rectangle().fill(Color.accent.opacity(0.4)).frame(width: 2); inline(value).foregroundStyle(Color.muted) }.fixedSize(horizontal: false, vertical: true)
                        case .rule: Divider().padding(.vertical, 4)
                        case .code(let language, let code): codeBlock(language, code)
                        case .table(let rows): table(rows)
                        }
                    }
                }
            }
        }.font(.ui(size: 15)).lineSpacing(5).textSelection(.enabled)
            .tint(user ? Color.onOutgoing : Color.accent).fixedSize(horizontal: false, vertical: true)
    }
    private func inline(_ value: String) -> Text { Text(InlineMarkdown.render(value)) }
    private func codeBlock(_ language: String, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(language.isEmpty ? "代码" : language).font(.ui(size: 12, weight: .medium)).foregroundStyle(Color.muted)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 24) }
                    .buttonStyle(ResponsiveButton()).help("复制代码").accessibilityLabel("复制代码")
            }
            ScrollView(.horizontal) { Text(verbatim: code).font(.ui(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
        }.padding(12).background(Color.canvas.opacity(0.65), in: OpticalRoundedRectangle())
            .overlay(OpticalRoundedRectangle().strokeBorder(.primary.opacity(0.08)))
    }
    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow(alignment: .top) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            inline(rows[r][c]).fontWeight(r == 0 ? .semibold : .regular)
                                .frame(minWidth: 90, maxWidth: 260, alignment: .leading).padding(10)
                                .background(.primary.opacity(r == 0 ? 0.07 : r % 2 == 0 ? 0.025 : 0))
                                .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
                        }
                    }
                }
            }
        }.clipShape(OpticalRoundedRectangle())
    }
}
