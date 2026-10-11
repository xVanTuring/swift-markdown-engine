//
//  MarkdownTableEditing.swift
//  MarkdownEngine
//
//  Structural edits on a parsed GFM table (set a cell, add / remove / move
//  rows and columns, change alignment) and the serializer that writes it back
//  as Markdown source. Row 0 is the header; body rows start at 1.
//

import Foundation

extension MarkdownStyler.ParsedTable {

    var columnCount: Int { alignments.count }
    /// Header plus body rows.
    var rowCount: Int { 1 + rows.count }

    // MARK: - Serialization

    /// Cell text as it must appear between pipes: a literal `|` is escaped and a
    /// line break becomes `<br>` (a GFM row is one source line).
    static func encodeCell(_ text: String) -> String {
        var out = ""
        var escaped = false
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                out.append(ch)
                escaped = true
            } else if ch == "|" {
                out.append("\\|")
            } else if ch == "\n" || ch == "\r" {
                if !out.hasSuffix("<br>") { out.append("<br>") }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Markdown source for the whole table, one line per row, no trailing newline.
    func markdownSource() -> String {
        func line(_ cells: [String]) -> String {
            "| " + cells.map { Self.encodeCell($0) }.joined(separator: " | ") + " |"
        }
        let delimiter = "|" + alignments.map { alignment -> String in
            switch alignment {
            case .left: return " --- "
            case .center: return " :---: "
            case .right: return " ---: "
            }
        }.joined(separator: "|") + "|"
        return ([line(header), delimiter] + rows.map(line)).joined(separator: "\n")
    }

    // MARK: - Cells

    func cell(row: Int, column: Int) -> String? {
        guard column >= 0, column < columnCount, row >= 0, row < rowCount else { return nil }
        return row == 0 ? header[column] : rows[row - 1][column]
    }

    func settingCell(row: Int, column: Int, to text: String) -> Self {
        guard cell(row: row, column: column) != nil else { return self }
        var newHeader = header
        var newRows = rows
        if row == 0 { newHeader[column] = text } else { newRows[row - 1][column] = text }
        return Self(header: newHeader, alignments: alignments, rows: newRows)
    }

    // MARK: - Rows

    /// Inserts an empty body row so it ends up at index `row` (clamped to 1…rowCount).
    func insertingRow(at row: Int) -> Self {
        var newRows = rows
        let index = min(max(row, 1), rowCount) - 1
        newRows.insert(Array(repeating: "", count: columnCount), at: index)
        return Self(header: header, alignments: alignments, rows: newRows)
    }

    /// Removes a body row. The header (row 0) cannot be removed.
    func removingRow(at row: Int) -> Self {
        guard row >= 1, row < rowCount else { return self }
        var newRows = rows
        newRows.remove(at: row - 1)
        return Self(header: header, alignments: alignments, rows: newRows)
    }

    /// Swaps a body row with its neighbour above (`-1`) or below (`+1`).
    func movingRow(at row: Int, by offset: Int) -> Self {
        let target = row + offset
        guard row >= 1, row < rowCount, target >= 1, target < rowCount, offset != 0 else { return self }
        var newRows = rows
        newRows.swapAt(row - 1, target - 1)
        return Self(header: header, alignments: alignments, rows: newRows)
    }

    // MARK: - Columns

    /// Inserts an empty column so it ends up at index `column` (clamped to 0…columnCount).
    func insertingColumn(at column: Int) -> Self {
        let index = min(max(column, 0), columnCount)
        var newHeader = header
        var newAlignments = alignments
        var newRows = rows
        newHeader.insert("", at: index)
        newAlignments.insert(.left, at: index)
        for i in newRows.indices { newRows[i].insert("", at: index) }
        return Self(header: newHeader, alignments: newAlignments, rows: newRows)
    }

    /// Removes a column. The last remaining column cannot be removed.
    func removingColumn(at column: Int) -> Self {
        guard columnCount > 1, column >= 0, column < columnCount else { return self }
        var newHeader = header
        var newAlignments = alignments
        var newRows = rows
        newHeader.remove(at: column)
        newAlignments.remove(at: column)
        for i in newRows.indices { newRows[i].remove(at: column) }
        return Self(header: newHeader, alignments: newAlignments, rows: newRows)
    }

    /// Swaps a column with its neighbour to the left (`-1`) or right (`+1`).
    func movingColumn(at column: Int, by offset: Int) -> Self {
        let target = column + offset
        guard column >= 0, column < columnCount, target >= 0, target < columnCount, offset != 0 else { return self }
        var newHeader = header
        var newAlignments = alignments
        var newRows = rows
        newHeader.swapAt(column, target)
        newAlignments.swapAt(column, target)
        for i in newRows.indices { newRows[i].swapAt(column, target) }
        return Self(header: newHeader, alignments: newAlignments, rows: newRows)
    }

    func settingAlignment(_ alignment: MarkdownStyler.TableAlignment, column: Int) -> Self {
        guard column >= 0, column < columnCount else { return self }
        var newAlignments = alignments
        newAlignments[column] = alignment
        return Self(header: header, alignments: newAlignments, rows: rows)
    }
}
