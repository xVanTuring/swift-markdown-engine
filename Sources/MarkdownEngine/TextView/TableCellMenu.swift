//
//  TableCellMenu.swift
//  MarkdownEngine
//
//  The table seam. The engine ships no table menu: it hands the host a context
//  describing the cell being edited, and the host builds (and titles, and
//  localizes) the menu itself. Titles belong to the host because a resource
//  bundle nested inside the module resolves against the HOST bundle's
//  localizations — engine-supplied strings cannot follow the app's language.
//

import Foundation

/// One structural edit to the table cell being edited in place.
///
/// The engine ships no menu, so no operation carries a title here; the host
/// names each one in the language it is presenting.
public enum TableEditOperation: Sendable, Equatable, CaseIterable {
    case insertRowAbove, insertRowBelow, deleteRow, moveRowUp, moveRowDown
    case insertColumnLeft, insertColumnRight, deleteColumn, moveColumnLeft, moveColumnRight
    case alignLeft, alignCenter, alignRight
}

/// How a column is aligned, for the menu's current-state checkmark.
public enum TableEditAlignment: Sendable, Equatable {
    case left, center, right
}

/// The cell being edited, handed to the host's table-menu hook so the host can
/// build the menu itself.
///
/// The engine exposes this instead of building menu items because the titles
/// (and their language) are the host's: the engine's own strings live in a
/// nested bundle that resolves against the host bundle's localizations, so they
/// cannot follow the app's language. Everything here is already computed — ask
/// ``isEnabled(_:)`` which operations apply to this cell, and call ``perform``
/// to run one the user picked.
public struct TableCellMenuContext {
    /// The open cell: row 0 is the header, column 0 the first column.
    public let row: Int
    public let column: Int
    public let rowCount: Int
    public let columnCount: Int
    /// Alignment of the open column, so the host can check the active item.
    public let alignment: TableEditAlignment
    /// Runs one operation on the open cell: a single undoable edit that
    /// re-renders the table and leaves the caret on the same content. Captures
    /// the text view weakly, so a menu action that arrives after the cell is
    /// gone does nothing.
    public let perform: (TableEditOperation) -> Void

    /// The engine builds the context it hands the hook; this initializer is
    /// public so a host can build one to test its own menu code.
    public init(
        row: Int, column: Int, rowCount: Int, columnCount: Int,
        alignment: TableEditAlignment, perform: @escaping (TableEditOperation) -> Void
    ) {
        self.row = row
        self.column = column
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.alignment = alignment
        self.perform = perform
    }

    /// Whether `operation` applies to this cell. Same rules the edit itself
    /// enforces: the header row cannot be deleted, moved, or have a row put
    /// above it, the first body row cannot move up into the header, and the
    /// last column cannot be deleted or moved right. The alignment items are
    /// always enabled: the column's current one carries the checkmark (see
    /// ``alignment``), and choosing it again changes nothing.
    public func isEnabled(_ operation: TableEditOperation) -> Bool {
        switch operation {
        case .alignLeft, .alignCenter, .alignRight: return true
        default: break
        }
        return operation.operation.isAvailable(
            row: row, column: column,
            rowCount: rowCount, columnCount: columnCount,
            alignment: alignment.tableAlignment
        )
    }
}

// MARK: - Internal conversions

extension TableEditOperation {
    /// The internal operation this one stands for.
    var operation: TableOperation {
        switch self {
        case .insertRowAbove: return .insertRowAbove
        case .insertRowBelow: return .insertRowBelow
        case .deleteRow: return .deleteRow
        case .moveRowUp: return .moveRowUp
        case .moveRowDown: return .moveRowDown
        case .insertColumnLeft: return .insertColumnLeft
        case .insertColumnRight: return .insertColumnRight
        case .deleteColumn: return .deleteColumn
        case .moveColumnLeft: return .moveColumnLeft
        case .moveColumnRight: return .moveColumnRight
        case .alignLeft: return .align(.left)
        case .alignCenter: return .align(.center)
        case .alignRight: return .align(.right)
        }
    }

    init(_ operation: TableOperation) {
        switch operation {
        case .insertRowAbove: self = .insertRowAbove
        case .insertRowBelow: self = .insertRowBelow
        case .deleteRow: self = .deleteRow
        case .moveRowUp: self = .moveRowUp
        case .moveRowDown: self = .moveRowDown
        case .insertColumnLeft: self = .insertColumnLeft
        case .insertColumnRight: self = .insertColumnRight
        case .deleteColumn: self = .deleteColumn
        case .moveColumnLeft: self = .moveColumnLeft
        case .moveColumnRight: self = .moveColumnRight
        case .align(.left): self = .alignLeft
        case .align(.center): self = .alignCenter
        case .align(.right): self = .alignRight
        }
    }
}

extension TableEditAlignment {
    init(_ alignment: MarkdownStyler.TableAlignment) {
        switch alignment {
        case .left: self = .left
        case .center: self = .center
        case .right: self = .right
        }
    }

    var tableAlignment: MarkdownStyler.TableAlignment {
        switch self {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}
