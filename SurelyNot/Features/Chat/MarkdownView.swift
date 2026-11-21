import SwiftUI

/// One block of a reply, as far as this app lays Markdown out.
nonisolated enum MarkdownBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case table(header: [String], rows: [[String]])
    case rule

    /// Splits Markdown into blocks. Anything it does not recognise becomes a
    /// paragraph, so no text is ever dropped.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
            if !numbered.isEmpty {
                blocks.append(.numbered(numbered))
                numbered = []
            }
            if !table.isEmpty {
                // A real table has a header, a row of dashes, then the rows.
                if table.count >= 2, isDivider(table[1]) {
                    blocks.append(.table(header: table[0], rows: Array(table.dropFirst(2))))
                } else {
                    blocks.append(.paragraph(table.map { $0.joined(separator: " | ") }.joined(separator: "\n")))
                }
                table = []
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("|") {
                if !paragraph.isEmpty || !bullets.isEmpty || !numbered.isEmpty { flush() }
                table.append(cells(in: line))
            } else if let text = headingText(line) {
                flush()
                blocks.append(.heading(text))
            } else if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }), line.count >= 3 {
                flush()
                blocks.append(.rule)
            } else if let text = bulletText(line) {
                if !paragraph.isEmpty || !numbered.isEmpty || !table.isEmpty { flush() }
                bullets.append(text)
            } else if let text = numberedText(line) {
                if !paragraph.isEmpty || !bullets.isEmpty || !table.isEmpty { flush() }
                numbered.append(text)
            } else {
                if !bullets.isEmpty || !numbered.isEmpty || !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func cells(in line: String) -> [String] {
        var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    private static func isDivider(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedText(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }
}

/// Lays out an assistant reply: headings, paragraphs, lists and tables.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(Theme.body)
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text))
                .font(Theme.font(18, .semibold, relativeTo: .headline))
                .padding(.top, 4)
        case .paragraph(let text):
            Text(Self.inline(text))
        case .bullets(let items):
            list(items) { _ in "•" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        case .rule:
            RowRule()
        }
    }

    private func list(_ items: [String], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                    Text(Self.inline(item))
                }
            }
        }
    }

    /// Bold, italics, code and links inside one piece of text.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A table from a reply. Columns that hold numbers line up on the right.
/// A table too wide for the screen scrolls sideways on its own.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    /// A column is numeric when every filled cell in it reads as a figure.
    private func isNumeric(_ column: Int) -> Bool {
        let cells = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
            .map { $0.replacingOccurrences(of: "*", with: "") }
            .filter { !$0.isEmpty && $0 != "–" && $0 != "-" }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.contains(where: \.isNumber)
                && cell.allSatisfy { $0.isNumber || "$€£¥.,%+-−() ".contains($0) }
        }
    }

    private func cell(_ row: [String], _ column: Int) -> String {
        row.indices.contains(column) ? row[column] : ""
    }

    var body: some View {
        let numeric = (0..<columnCount).map(isNumeric)
        ViewThatFits(in: .horizontal) {
            grid(numeric: numeric)
            ScrollView(.horizontal, showsIndicators: false) {
                grid(numeric: numeric)
            }
        }
    }

    private func grid(numeric: [Bool]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                ForEach(0..<columnCount, id: \.self) { column in
                    Text(MarkdownView.inline(cell(header, column)))
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .gridColumnAlignment(numeric[column] ? .trailing : .leading)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                RowRule().gridCellColumns(columnCount)
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        Text(MarkdownView.inline(cell(row, column)))
                            .font(Theme.small)
                            .monospacedDigit()
                            .fixedSize(horizontal: numeric[column], vertical: true)
                    }
                }
            }
        }
    }
}
