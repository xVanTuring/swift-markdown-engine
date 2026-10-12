//
//  MarkdownTableSelection.swift
//  MarkdownEngine
//
//  Cell selection on a parsed table (a block of cells, whole rows, whole
//  columns) and the edits it drives: clear, remove, and drag-move a single
//  row or column to any position. Row 0 is the header; body rows start at 1.
//

import Foundation

/// What Delete does to a selected row or column.
public enum TableDeleteBehavior: Sendable, Equatable {
    /// First press clears the cells' content; once they are all empty, the
    /// next press removes the selected rows / columns. (Default.)
    case clearThenRemove
    /// Only ever clears content; the table's shape never changes.
    case clearOnly
    /// Removes the selected rows / columns straight away, content or not.
    case removeOnly
}

/// A rectangular block of cells, inclusive on both ends.
struct TableCellSelection: Equatable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>

    /// What the block amounts to in a table of a given shape.
    enum Shape: Equatable {
        /// Every column of one or more rows (but not the whole table).
        case rows
        /// Every row of one or more columns (but not the whole table).
        case columns
        /// Any other block, including the whole table.
        case cells
    }

    func shape(in table: MarkdownStyler.ParsedTable) -> Shape {
        let allColumns = columns.lowerBound <= 0 && columns.upperBound >= table.columnCount - 1
        let allRows = rows.lowerBound <= 0 && rows.upperBound >= table.rowCount - 1
        if allColumns && !allRows { return .rows }
        if allRows && !allColumns { return .columns }
        return .cells
    }

    /// The block clamped to the table, or nil when nothing of it is left.
    func clamped(to table: MarkdownStyler.ParsedTable) -> TableCellSelection? {
        let r0 = max(rows.lowerBound, 0), r1 = min(rows.upperBound, table.rowCount - 1)
        let c0 = max(columns.lowerBound, 0), c1 = min(columns.upperBound, table.columnCount - 1)
        guard r0 <= r1, c0 <= c1 else { return nil }
        return TableCellSelection(rows: r0...r1, columns: c0...c1)
    }
}

extension MarkdownStyler.ParsedTable {

    /// Whether every selected cell is empty (spaces only counts as empty).
    func isEmpty(_ selection: TableCellSelection) -> Bool {
        guard let s = selection.clamped(to: self) else { return true }
        for row in s.rows {
            for column in s.columns {
                let text = cell(row: row, column: column) ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            }
        }
        return true
    }

    /// The selected cells emptied.
    func clearing(_ selection: TableCellSelection) -> Self {
        guard let s = selection.clamped(to: self) else { return self }
        var newHeader = header
        var newRows = rows
        for row in s.rows {
            for column in s.columns {
                if row == 0 { newHeader[column] = "" } else { newRows[row - 1][column] = "" }
            }
        }
        return Self(header: newHeader, alignments: alignments, rows: newRows)
    }

    /// Removes the body rows in `range`; the header (row 0) is never removed.
    func removingRows(_ range: ClosedRange<Int>) -> Self {
        let lower = max(range.lowerBound, 1), upper = min(range.upperBound, rowCount - 1)
        guard lower <= upper else { return self }
        var newRows = rows
        newRows.removeSubrange((lower - 1)...(upper - 1))
        return Self(header: header, alignments: alignments, rows: newRows)
    }

    /// Removes the columns in `range`; at least one column always stays.
    func removingColumns(_ range: ClosedRange<Int>) -> Self {
        let lower = max(range.lowerBound, 0), upper = min(range.upperBound, columnCount - 1)
        guard lower <= upper, upper - lower + 1 < columnCount else { return self }
        var newHeader = header
        var newAlignments = alignments
        var newRows = rows
        newHeader.removeSubrange(lower...upper)
        newAlignments.removeSubrange(lower...upper)
        for i in newRows.indices { newRows[i].removeSubrange(lower...upper) }
        return Self(header: newHeader, alignments: newAlignments, rows: newRows)
    }

    /// Moves a body row so it ends up at index `target` (1…rowCount - 1).
    func movingRow(from row: Int, to target: Int) -> Self {
        guard row >= 1, row < rowCount, target >= 1, target < rowCount, row != target else { return self }
        var newRows = rows
        newRows.insert(newRows.remove(at: row - 1), at: target - 1)
        return Self(header: header, alignments: alignments, rows: newRows)
    }

    /// Moves a column so it ends up at index `target` (0…columnCount - 1).
    func movingColumn(from column: Int, to target: Int) -> Self {
        guard column >= 0, column < columnCount, target >= 0, target < columnCount, column != target else { return self }
        var newHeader = header
        var newAlignments = alignments
        var newRows = rows
        newHeader.insert(newHeader.remove(at: column), at: target)
        newAlignments.insert(newAlignments.remove(at: column), at: target)
        for i in newRows.indices { newRows[i].insert(newRows[i].remove(at: column), at: target) }
        return Self(header: newHeader, alignments: newAlignments, rows: newRows)
    }

    /// What Delete does to `selection` under `behavior`: the edited table and
    /// the selection that should remain (nil once the selected rows / columns
    /// are gone).
    func deleting(
        _ selection: TableCellSelection, behavior: TableDeleteBehavior
    ) -> (table: Self, selection: TableCellSelection?) {
        guard let s = selection.clamped(to: self) else { return (self, nil) }
        let shape = s.shape(in: self)
        let removes: Bool
        switch behavior {
        case .clearOnly: removes = false
        case .removeOnly: removes = true
        case .clearThenRemove: removes = isEmpty(s)
        }
        guard removes, shape != .cells else { return (clearing(s), s) }
        switch shape {
        case .rows:
            let result = removingRows(s.rows)
            // Only the header selected: nothing to remove, keep the selection.
            if result.rowCount == rowCount { return (self, s) }
            return (result, nil)
        case .columns:
            let result = removingColumns(s.columns)
            if result.columnCount == columnCount { return (self, s) }
            return (result, nil)
        case .cells:
            return (clearing(s), s)
        }
    }
}
