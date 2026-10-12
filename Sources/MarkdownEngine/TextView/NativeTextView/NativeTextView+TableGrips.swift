//
//  NativeTextView+TableGrips.swift
//  MarkdownEngine
//
//  Grips on a table edited in place: while the pointer is over a cell, a grip
//  shows above its column and beside its row. Click selects the whole column /
//  row; drag moves it, with a line marking where it will land.
//

import AppKit

// MARK: - Views

enum TableAxis {
    case row, column
}

/// The draggable handle. Lives in the table's host view, outside the table image.
final class TableGripView: NSView {
    let axis: TableAxis
    var index = 0
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    weak var owner: NativeTextView?
    var tableStart = 0

    static let longSide: CGFloat = 22
    static let shortSide: CGFloat = 12

    init(axis: TableAxis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        (isSelected ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor.withAlphaComponent(0.35)).setFill()
        pill.fill()
        (isSelected ? NSColor.white : NSColor.secondaryLabelColor).setFill()
        // Six dots: 3 × 2 across a column grip, 2 × 3 down a row grip.
        let (cols, rows) = axis == .column ? (3, 2) : (2, 3)
        let dot: CGFloat = 2, gap: CGFloat = 2
        let width = CGFloat(cols) * dot + CGFloat(cols - 1) * gap
        let height = CGFloat(rows) * dot + CGFloat(rows - 1) * gap
        let originX = (bounds.width - width) / 2, originY = (bounds.height - height) / 2
        for r in 0..<rows {
            for c in 0..<cols {
                NSBezierPath(ovalIn: NSRect(
                    x: originX + CGFloat(c) * (dot + gap), y: originY + CGFloat(r) * (dot + gap),
                    width: dot, height: dot
                )).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        owner?.trackTableGrip(self, startEvent: event)
    }
}

/// The line showing where a dragged row / column will land.
final class TableDropLineView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

final class TableGripState {
    var tableStart: Int
    var row: Int
    var column: Int
    let columnGrip = TableGripView(axis: .column)
    let rowGrip = TableGripView(axis: .row)
    let dropLine = TableDropLineView()

    init(tableStart: Int, row: Int, column: Int) {
        self.tableStart = tableStart
        self.row = row
        self.column = column
    }
}

// MARK: - NativeTextView

extension NativeTextView {

    var showsTableGrips: Bool {
        canEditTablesInPlace && configuration.tableInteraction.showsGrips
    }

    // MARK: Hover

    /// Pointer moved over this view (a narrow table's host): show the grips of
    /// the cell under it, keep them while it stays near the table, else hide.
    func updateTableGrips(for event: NSEvent) {
        guard showsTableGrips, !isTrackingTableGrip else { hideTableGrips(); return }
        let point = convert(event.locationInWindow, from: nil)
        if let hit = narrowTableCell(at: point) {
            showTableGrips(tableStart: hit.tableStart, row: hit.row, column: hit.column)
        } else if let state = tableGripState, !isNearTable(state, point: point) {
            hideTableGrips()
        }
    }

    /// The cell of a table drawn in this view that is under `point`.
    private func narrowTableCell(at point: NSPoint) -> (tableStart: Int, row: Int, column: Int)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let probe = min(max(characterIndexForInsertion(at: point), 0), storage.length - 1)
        guard let token = tableToken(containing: probe)
                ?? tableToken(containing: (storage.string as NSString).paragraphRange(
                    for: NSRange(location: probe, length: 0)).location),
              let rendered = renderedTable(in: token.range),
              let origin = cellFrame(row: 0, column: 0, image: rendered.image,
                                     geometry: rendered.geometry, anchor: rendered.anchor),
              origin.host === self,
              let corner = rendered.geometry.cellRect(row: 0, column: 0) else { return nil }
        let imagePoint = CGPoint(x: point.x - (origin.frame.minX - corner.minX),
                                 y: point.y - (origin.frame.minY - corner.minY))
        guard imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x <= rendered.geometry.imageSize.width,
              imagePoint.y <= rendered.geometry.imageSize.height,
              let cell = rendered.geometry.cell(at: imagePoint) else { return nil }
        return (token.range.location, cell.row, cell.column)
    }

    private func isNearTable(_ state: TableGripState, point: NSPoint) -> Bool {
        guard let (token, parsed) = table(startingAt: state.tableStart),
              let rendered = renderedTable(in: token.range),
              let first = cellFrame(row: 0, column: 0, image: rendered.image,
                                    geometry: rendered.geometry, anchor: rendered.anchor),
              let last = cellFrame(row: parsed.rowCount - 1, column: parsed.columnCount - 1, image: rendered.image,
                                   geometry: rendered.geometry, anchor: rendered.anchor),
              first.host === self else { return false }
        return first.frame.union(last.frame).insetBy(dx: -30, dy: -30).contains(point)
    }

    /// Shows the grips for a cell (also the entry point for a wide table's overlay).
    func showTableGrips(tableStart: Int, row: Int, column: Int) {
        guard showsTableGrips, !isTrackingTableGrip else { return }
        if let state = tableGripState {
            if state.tableStart == tableStart, state.row == row, state.column == column { return }
            state.tableStart = tableStart
            state.row = row
            state.column = column
        } else {
            tableGripState = TableGripState(tableStart: tableStart, row: row, column: column)
        }
        layoutTableGrips()
    }

    func hideTableGrips() {
        guard let state = tableGripState, !isTrackingTableGrip else { return }
        state.columnGrip.removeFromSuperview()
        state.rowGrip.removeFromSuperview()
        state.dropLine.removeFromSuperview()
        tableGripState = nil
    }

    // MARK: Layout

    /// Frames of every column (along the header) or row (down the first column)
    /// in the table's host view, or nil when the table can't be placed.
    private func lineFrames(
        _ axis: TableAxis, tableStart: Int
    ) -> (host: NSView, frames: [NSRect], image: NSImage)? {
        guard let (token, parsed) = table(startingAt: tableStart),
              let rendered = renderedTable(in: token.range) else { return nil }
        var frames: [NSRect] = []
        var host: NSView?
        let count = axis == .column ? parsed.columnCount : parsed.rowCount
        for i in 0..<count {
            guard let placed = cellFrame(
                row: axis == .row ? i : 0, column: axis == .column ? i : 0,
                image: rendered.image, geometry: rendered.geometry, anchor: rendered.anchor
            ) else { return nil }
            host = host ?? placed.host
            guard placed.host === host else { return nil }
            frames.append(placed.frame)
        }
        guard let host else { return nil }
        return (host, frames, rendered.image)
    }

    /// Puts the grips beside the hovered cell's column and row. Call after
    /// anything that can move or re-render the table.
    func layoutTableGrips() {
        guard let state = tableGripState else { return }
        guard showsTableGrips,
              let columns = lineFrames(.column, tableStart: state.tableStart),
              let rows = lineFrames(.row, tableStart: state.tableStart),
              state.column < columns.frames.count, state.row < rows.frames.count else {
            hideTableGrips()
            return
        }
        // A wide table is clipped by its overlay; a grip outside the clip hides.
        var clip: NSRect?
        if columns.host !== self,
           let overlay = wideTableOverlays.values.first(where: { $0.superview === columns.host && $0.currentImage === columns.image }) {
            clip = overlay.frame
        }
        let long = TableGripView.longSide, short = TableGripView.shortSide

        let columnFrame = columns.frames[state.column]
        let columnGripFrame = NSRect(x: columnFrame.midX - long / 2, y: columnFrame.minY - short - 3,
                                     width: long, height: short)
        let rowFrame = rows.frames[state.row]
        let rowGripFrame = NSRect(x: rowFrame.minX - short - 3, y: rowFrame.midY - long / 2,
                                  width: short, height: long)

        place(state.columnGrip, axis: .column, index: state.column, frame: columnGripFrame,
              host: columns.host, clip: clip, tableStart: state.tableStart)
        place(state.rowGrip, axis: .row, index: state.row, frame: rowGripFrame,
              host: columns.host, clip: clip, tableStart: state.tableStart)
        updateGripSelectionHighlight()
    }

    private func place(
        _ grip: TableGripView, axis: TableAxis, index: Int, frame: NSRect,
        host: NSView, clip: NSRect?, tableStart: Int
    ) {
        grip.owner = self
        grip.index = index
        grip.tableStart = tableStart
        if let clip, !clip.insetBy(dx: -30, dy: -30).contains(CGPoint(x: frame.midX, y: frame.midY)) {
            grip.isHidden = true
            return
        }
        grip.isHidden = false
        if grip.superview !== host { host.addSubview(grip) }
        grip.frame = frame
        grip.needsDisplay = true
        grip.window?.invalidateCursorRects(for: grip)
    }

    /// A grip is lit while its whole row / column is the selection.
    func updateGripSelectionHighlight() {
        guard let state = tableGripState else { return }
        var rowSelected = false, columnSelected = false
        if let selection = tableSelectionState, selection.tableStart == state.tableStart,
           let (_, parsed) = table(startingAt: state.tableStart) {
            switch selection.selection.shape(in: parsed) {
            case .rows: rowSelected = selection.selection.rows.contains(state.row)
            case .columns: columnSelected = selection.selection.columns.contains(state.column)
            case .cells: break
            }
        }
        state.rowGrip.isSelected = rowSelected
        state.columnGrip.isSelected = columnSelected
    }

    // MARK: Click and drag

    var isTrackingTableGrip: Bool { tableGripDragInProgress }

    /// Click selects the grip's row / column; a drag moves it.
    func trackTableGrip(_ grip: TableGripView, startEvent: NSEvent) {
        guard let window, let host = grip.superview,
              let (_, parsed) = table(startingAt: grip.tableStart) else { return }
        let axis = grip.axis
        let from = grip.index
        // The header row is selectable but stays where it is.
        let movable = axis == .column || from >= 1
        let start = host.convert(startEvent.locationInWindow, from: nil)
        let tableStart = grip.tableStart

        tableGripDragInProgress = true
        defer {
            tableGripDragInProgress = false
            tableGripState?.dropLine.removeFromSuperview()
        }

        var dragging = false
        var target = from
        while let event = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true
        ) {
            let point = host.convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseUp { break }
            guard movable else { continue }
            if !dragging {
                guard hypot(point.x - start.x, point.y - start.y) > 4 else { continue }
                dragging = true
                NSCursor.closedHand.push()
            }
            guard let frames = lineFrames(axis, tableStart: tableStart), frames.host === host else { continue }
            let lowest = axis == .row ? 1 : 0
            let along = axis == .column ? point.x : point.y
            var nearest = lowest
            for (i, frame) in frames.frames.enumerated() where i >= lowest {
                let mid = axis == .column ? frame.midX : frame.midY
                let nearestFrame = frames.frames[nearest]
                let nearestMid = axis == .column ? nearestFrame.midX : nearestFrame.midY
                if abs(along - mid) < abs(along - nearestMid) { nearest = i }
            }
            target = nearest
            showDropLine(axis: axis, from: from, target: target, frames: frames.frames, host: host)
        }
        if dragging { NSCursor.pop() }

        endTableCellEditing(restoreFocus: false)
        window.makeFirstResponder(self)
        if dragging, target != from {
            moveTableLine(tableStart: tableStart, axis: axis, from: from, to: target)
        } else if !dragging {
            let selection = axis == .row
                ? TableCellSelection(rows: from...from, columns: 0...(parsed.columnCount - 1))
                : TableCellSelection(rows: 0...(parsed.rowCount - 1), columns: from...from)
            setTableSelection(tableStart: tableStart, selection)
        }
        updateGripSelectionHighlight()
    }

    /// The line sits on the edge the dragged row / column will end up beside.
    private func showDropLine(axis: TableAxis, from: Int, target: Int, frames: [NSRect], host: NSView) {
        guard let state = tableGripState, target < frames.count else { return }
        let frame = frames[target]
        let after = target > from
        let thickness: CGFloat = 3
        var rect: NSRect
        if axis == .column {
            let x = after ? frame.maxX : frame.minX
            let top = frames.first?.minY ?? frame.minY
            let bottom = (rowsExtent(host: host, tableStart: state.tableStart) ?? frame.maxY)
            rect = NSRect(x: x - thickness / 2, y: top, width: thickness, height: bottom - top)
        } else {
            let y = after ? frame.maxY : frame.minY
            let left = frames.first?.minX ?? frame.minX
            let right = columnsExtent(host: host, tableStart: state.tableStart) ?? frame.maxX
            rect = NSRect(x: left, y: y - thickness / 2, width: right - left, height: thickness)
        }
        if state.dropLine.superview !== host { host.addSubview(state.dropLine) }
        state.dropLine.frame = rect
        state.dropLine.needsDisplay = true
    }

    private func rowsExtent(host: NSView, tableStart: Int) -> CGFloat? {
        lineFrames(.row, tableStart: tableStart)?.frames.last?.maxY
    }

    private func columnsExtent(host: NSView, tableStart: Int) -> CGFloat? {
        lineFrames(.column, tableStart: tableStart)?.frames.last?.maxX
    }

    /// Moves one row / column and keeps it selected.
    func moveTableLine(tableStart: Int, axis: TableAxis, from: Int, to: Int) {
        guard let (token, parsed) = table(startingAt: tableStart) else { return }
        let moved = axis == .row ? parsed.movingRow(from: from, to: to) : parsed.movingColumn(from: from, to: to)
        let newSource = moved.markdownSource()
        guard newSource != parsed.markdownSource() else { return }
        suppressTableEntry = true
        MarkdownLists.performEdit(self, replace: token.range, with: newSource)
        suppressTableEntry = false
        let selection = axis == .row
            ? TableCellSelection(rows: to...to, columns: 0...(parsed.columnCount - 1))
            : TableCellSelection(rows: 0...(parsed.rowCount - 1), columns: to...to)
        setTableSelection(tableStart: tableStart, selection)
        if let state = tableGripState {
            if axis == .row { state.row = to } else { state.column = to }
        }
        layoutTableGrips()
    }
}
