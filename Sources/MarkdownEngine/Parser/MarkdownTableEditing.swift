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
    /// line break becomes `<br>` (a GFM row is one source line). Every break is
    /// kept — leading, trailing and repeated ones too — since each is a visible
    /// line in the cell; only spaces and tabs at the edges are trimmed.
    static func encodeCell(_ text: String) -> String {
        var out = ""
        var escaped = false
        for ch in text.trimmingCharacters(in: .whitespaces) {
            if escaped {
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                out.append(ch)
                escaped = true
            } else if ch == "|" {
                out.append("\\|")
            } else if ch.isNewline {
                out.append("<br>")
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

// MARK: - Operations on the cell being edited

/// A structural edit on the cell being edited. It is the engine's internal
/// model; ``TableEditOperation`` is the public face the host's menu uses.
enum TableOperation: Equatable {
    case insertRowAbove, insertRowBelow, deleteRow, moveRowUp, moveRowDown
    case insertColumnLeft, insertColumnRight, deleteColumn, moveColumnLeft, moveColumnRight
    case align(MarkdownStyler.TableAlignment)

    /// Whether the operation makes sense for the cell at (`row`, `column`).
    /// The header row can't be removed, moved, or have a row put above it, the
    /// first body row can't move up into the header, and the last column can't
    /// be removed or moved right.
    func isAvailable(row: Int, column: Int, in table: MarkdownStyler.ParsedTable) -> Bool {
        guard column >= 0, column < table.columnCount else { return false }
        return isAvailable(row: row, column: column, rowCount: table.rowCount,
                           columnCount: table.columnCount, alignment: table.alignments[column])
    }

    /// The same rule expressed in the table's shape rather than the table
    /// itself, so ``TableCellMenuContext/isEnabled(_:)`` — which knows only the
    /// counts and the open column's alignment — reaches the single copy of it.
    func isAvailable(
        row: Int, column: Int, rowCount: Int, columnCount: Int,
        alignment: MarkdownStyler.TableAlignment
    ) -> Bool {
        switch self {
        case .insertRowAbove: return row >= 1
        case .insertRowBelow: return true
        case .deleteRow: return row >= 1
        case .moveRowUp: return row >= 2
        case .moveRowDown: return row >= 1 && row < rowCount - 1
        case .insertColumnLeft, .insertColumnRight: return true
        case .deleteColumn: return columnCount > 1
        case .moveColumnLeft: return column >= 1
        case .moveColumnRight: return column < columnCount - 1
        case .align(let current): return alignment != current
        }
    }

    /// The edited table and where the edited cell ends up, so the caret stays
    /// on the same content (or the nearest cell when its row/column is removed).
    func apply(
        to table: MarkdownStyler.ParsedTable, row: Int, column: Int
    ) -> (table: MarkdownStyler.ParsedTable, row: Int, column: Int) {
        guard isAvailable(row: row, column: column, in: table) else { return (table, row, column) }
        switch self {
        case .insertRowAbove:
            return (table.insertingRow(at: row), row + 1, column)
        case .insertRowBelow:
            return (table.insertingRow(at: row + 1), row, column)
        case .deleteRow:
            let result = table.removingRow(at: row)
            return (result, min(row, result.rowCount - 1), column)
        case .moveRowUp:
            return (table.movingRow(at: row, by: -1), row - 1, column)
        case .moveRowDown:
            return (table.movingRow(at: row, by: 1), row + 1, column)
        case .insertColumnLeft:
            return (table.insertingColumn(at: column), row, column + 1)
        case .insertColumnRight:
            return (table.insertingColumn(at: column + 1), row, column)
        case .deleteColumn:
            let result = table.removingColumn(at: column)
            return (result, row, min(column, result.columnCount - 1))
        case .moveColumnLeft:
            return (table.movingColumn(at: column, by: -1), row, column - 1)
        case .moveColumnRight:
            return (table.movingColumn(at: column, by: 1), row, column + 1)
        case .align(let alignment):
            return (table.settingAlignment(alignment, column: column), row, column)
        }
    }
}
