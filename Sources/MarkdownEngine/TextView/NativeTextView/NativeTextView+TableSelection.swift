//
//  NativeTextView+TableSelection.swift
//  MarkdownEngine
//
//  Selecting a block of cells in a table that is edited in place: drag across
//  cells, then Delete / Escape / copy. The selection is drawn by a small
//  non-interactive view laid over the table (in the wide-table overlay's host
//  for a scrolling table, so it follows the scroll).
//

import AppKit

// MARK: - State

/// The selected cells of one table (by the document offset of its first
/// character) and the view that draws them.
final class TableSelectionState {
    var tableStart: Int
    var selection: TableCellSelection
    let view = TableSelectionView()

    init(tableStart: Int, selection: TableCellSelection) {
        self.tableStart = tableStart
        self.selection = selection
    }
}

/// Outline and tint over the selected cells. Never takes the mouse.
final class TableSelectionView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

// MARK: - NativeTextView

extension NativeTextView {

    var canSelectTableCells: Bool {
        canEditTablesInPlace && configuration.tableInteraction.selectsCells
    }

    // MARK: Selecting

    /// Follows the mouse from a press on cell `anchor` until it is released.
    /// `cellAt` maps a mouse event to the cell nearest it. Returns true when
    /// the pointer left the anchor cell and a block was selected; false means
    /// it was a plain click and nothing changed.
    func trackTableCellSelection(
        tableStart: Int,
        anchor: (row: Int, column: Int),
        cellAt: (NSEvent) -> (row: Int, column: Int)?
    ) -> Bool {
        guard let window else { return false }
        var selected = false
        while let event = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            if event.type == .leftMouseUp { break }
            guard let cell = cellAt(event) else { continue }
            if !selected {
                guard cell.row != anchor.row || cell.column != anchor.column else { continue }
                // Leaving the anchor cell: close any open editor (committing it)
                // and take the keyboard for Delete / Escape.
                endTableCellEditing(restoreFocus: false)
                window.makeFirstResponder(self)
                selected = true
            }
            setTableSelection(
                tableStart: tableStart,
                TableCellSelection(
                    rows: min(anchor.row, cell.row)...max(anchor.row, cell.row),
                    columns: min(anchor.column, cell.column)...max(anchor.column, cell.column)
                )
            )
        }
        return selected
    }

    func setTableSelection(tableStart: Int, _ selection: TableCellSelection) {
        if let state = tableSelectionState, state.tableStart == tableStart {
            state.selection = selection
        } else {
            clearTableSelection()
            tableSelectionState = TableSelectionState(tableStart: tableStart, selection: selection)
        }
        layoutTableSelection()
    }

    func clearTableSelection() {
        tableSelectionState?.view.removeFromSuperview()
        tableSelectionState = nil
    }

    // MARK: Layout

    /// Puts the selection view over its cells. Call after anything that can
    /// move or re-render the table. Drops the selection when its table or
    /// cells are gone.
    func layoutTableSelection() {
        guard let state = tableSelectionState else { return }
        guard canSelectTableCells,
              let (token, parsed) = table(startingAt: state.tableStart),
              let selection = state.selection.clamped(to: parsed),
              let rendered = renderedTable(in: token.range),
              let first = cellFrame(row: selection.rows.lowerBound, column: selection.columns.lowerBound,
                                    image: rendered.image, geometry: rendered.geometry, anchor: rendered.anchor),
              let last = cellFrame(row: selection.rows.upperBound, column: selection.columns.upperBound,
                                   image: rendered.image, geometry: rendered.geometry, anchor: rendered.anchor),
              first.host === last.host else {
            clearTableSelection()
            return
        }
        state.selection = selection
        var frame = first.frame.union(last.frame).insetBy(dx: -1, dy: -1)
        // A scrolling table is clipped by its overlay; its selection must be too.
        if first.host !== self,
           let overlay = wideTableOverlays.values.first(where: { $0.superview === first.host && $0.currentImage === rendered.image }) {
            frame = frame.intersection(overlay.frame)
        }
        let view = state.view
        guard !frame.isNull, !frame.isEmpty else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        if view.superview !== first.host { first.host.addSubview(view) }
        view.frame = frame
        view.needsDisplay = true
    }

    // MARK: Keys

    /// Handles a key while cells are selected. Returns true when consumed.
    func handleTableSelectionKey(_ event: NSEvent) -> Bool {
        guard tableSelectionState != nil else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            if event.charactersIgnoringModifiers == "c" {
                copyTableSelection()
                return true
            }
            clearTableSelection()
            return false
        }
        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            deleteTableSelection()
        case 53:        // escape
            clearTableSelection()
        default:
            // Typing has no cell to land in; swallow it rather than let it
            // reach the document at the old caret.
            clearTableSelection()
        }
        return true
    }

    // MARK: Edits

    /// Delete on the selection, per `TableInteractionStyle.deleteBehavior`.
    func deleteTableSelection() {
        guard let state = tableSelectionState,
              let (token, parsed) = table(startingAt: state.tableStart) else { return }
        let result = parsed.deleting(state.selection, behavior: configuration.tableInteraction.deleteBehavior)
        let newSource = result.table.markdownSource()
        if newSource != parsed.markdownSource() {
            suppressTableEntry = true
            MarkdownLists.performEdit(self, replace: token.range, with: newSource)
            suppressTableEntry = false
        }
        if let remaining = result.selection {
            state.selection = remaining
            layoutTableSelection()
        } else {
            clearTableSelection()
        }
    }

    /// The selected cells as tab-separated lines (each cell's raw Markdown).
    func copyTableSelection() {
        guard let state = tableSelectionState,
              let (_, parsed) = table(startingAt: state.tableStart),
              let s = state.selection.clamped(to: parsed) else { return }
        let text = s.rows.map { row in
            s.columns.map { column in
                (parsed.cell(row: row, column: column) ?? "")
                    .replacingOccurrences(of: "\t", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        if handleTableSelectionKey(event) { return }
        super.keyDown(with: event)
    }
}
