//
//  NativeTextView+TableCellEditing.swift
//  MarkdownEngine
//
//  In-place table editing. A table stays rendered; clicking a cell opens a
//  small editor over it that holds the cell's raw Markdown (so `**bold**`,
//  `` `code` ``, `$x$` are editable as source). Leaving the cell writes it back
//  to the document as one undoable edit and the table re-renders.
//

import AppKit

// MARK: - Session

/// Where the open editor is: which table (by the document offset of its first
/// character), which cell, and the editor view itself.
final class TableEditSession {
    var tableStart: Int
    var row: Int
    var column: Int
    let editor: TableCellEditorView
    /// Set once the session is being torn down, so a resign-first-responder
    /// triggered by the teardown itself doesn't end it a second time.
    var isFinishing = false
    /// Pending write of the editor's text to the document (see `scheduleTableCellSync`).
    var pendingSync: DispatchWorkItem?
    /// The editor's text is taller than its cell, so the row has to grow;
    /// set by `layoutTableCellEditor`.
    var outgrewCell = false

    init(tableStart: Int, row: Int, column: Int, editor: TableCellEditorView) {
        self.tableStart = tableStart
        self.row = row
        self.column = column
        self.editor = editor
    }
}

/// Where the caret goes when editing leaves a cell.
enum TableCellMove {
    /// Tab: next cell, wrapping to the next row; past the end it appends a row.
    case next
    /// Shift-Tab: previous cell, wrapping to the previous row.
    case previous
    /// Up arrow on the first line: cell above; above the header leaves the table.
    case up
    /// Down arrow on the last line: cell below; below the last row leaves the table.
    case down
    /// Left arrow at the start of the text: end of the previous cell.
    case left
    /// Right arrow at the end of the text: start of the next cell.
    case right
}

enum TableExit {
    case stay, above, below
}

// MARK: - Editor view

/// The single-cell editor. Plain text, wraps inside the cell's width, grows
/// downward when its text is taller than the cell.
final class TableCellEditorView: NSTextView {
    weak var owner: NativeTextView?
    /// Keeps in-cell undo out of the document's undo stack: this view is gone
    /// by the time the document edit is undone.
    private let cellUndoManager = UndoManager()

    override var undoManager: UndoManager? { cellUndoManager }

    /// The text system is built by hand so the view owns it outright; a text
    /// view must be handed a strong reference to the storage it displays.
    private let backingStorage: NSTextStorage

    init(owner: NativeTextView) {
        self.owner = owner
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        backingStorage = storage
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        wantsLayer = true
        layer?.borderWidth = 1.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        owner?.layoutTableCellEditor()
        // Text that no longer fits its cell would spill over the row below for
        // the length of the debounce; write it now so the row grows at once. That
        // holds while an input method is composing too: the write leaves the
        // editor's text (and its marked range) alone, and waiting would leave the
        // composition wrapped over the rows below until it is committed.
        if let owner, owner.tableEditSession?.outgrewCell == true {
            owner.tableEditSession?.pendingSync?.cancel()
            owner.syncTableCellToDocument()
            return
        }
        owner?.scheduleTableCellSync()
    }

    /// The host's table items for the open cell, on top of the editor's own
    /// text menu. The engine ships no items of its own — see the seam in
    /// `TableCellMenu.swift`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let owner else { return menu }
        return owner.tableCellContextMenu(menu)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // Deferred: AppKit is mid-way through changing the responder chain.
            DispatchQueue.main.async { [weak owner, weak self] in
                guard let owner, let self, owner.tableEditSession?.editor === self else { return }
                owner.endTableCellEditing(restoreFocus: false)
            }
        }
        return resigned
    }

    override func doCommand(by selector: Selector) {
        guard let owner else { super.doCommand(by: selector); return }
        switch selector {
        case #selector(insertTab(_:)):
            owner.moveTableCellEditor(.next)
        case #selector(insertBacktab(_:)):
            owner.moveTableCellEditor(.previous)
        case #selector(insertNewline(_:)),
             #selector(insertLineBreak(_:)),
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            // Return breaks the line inside the cell (stored as `<br>`); the
            // row grows with it.
            insertText("\n", replacementRange: selectedRange())
        case #selector(cancelOperation(_:)):
            owner.endTableCellEditing(exit: .stay)
        case #selector(moveUp(_:)):
            if isCaretOnFirstLine { owner.moveTableCellEditor(.up) } else { super.doCommand(by: selector) }
        case #selector(moveDown(_:)):
            if isCaretOnLastLine { owner.moveTableCellEditor(.down) } else { super.doCommand(by: selector) }
        case #selector(moveLeft(_:)):
            if selectedRange() == NSRange(location: 0, length: 0) {
                owner.moveTableCellEditor(.left)
            } else {
                super.doCommand(by: selector)
            }
        case #selector(moveRight(_:)):
            let end = (string as NSString).length
            if selectedRange() == NSRange(location: end, length: 0) {
                owner.moveTableCellEditor(.right)
            } else {
                super.doCommand(by: selector)
            }
        default:
            super.doCommand(by: selector)
        }
    }

    private func lineY(at location: Int) -> CGFloat {
        firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil).minY
    }

    private var isCaretOnFirstLine: Bool {
        abs(lineY(at: selectedRange().location) - lineY(at: 0)) < 1
    }

    private var isCaretOnLastLine: Bool {
        let length = (string as NSString).length
        return abs(lineY(at: NSMaxRange(selectedRange())) - lineY(at: length)) < 1
    }

    /// Width of the longest line on one row, padding included.
    func requiredWidth(of text: String? = nil) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        let longest = (text ?? string).components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        return ceil(longest) + textContainerInset.width * 2 + 2
    }

    /// Height the text needs at the current width, padding included.
    func requiredHeight() -> CGFloat {
        let padding = textContainerInset.height * 2
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            return ceil(tlm.usageBoundsForTextContainer.height) + padding
        }
        if let lm = layoutManager, let tc = textContainer {
            lm.ensureLayout(for: tc)
            return ceil(lm.usedRect(for: tc).height) + padding
        }
        return 0
    }
}

// MARK: - NativeTextView

extension NativeTextView {

    /// In-place table editing applies to an editable view in rendered mode.
    var canEditTablesInPlace: Bool {
        configuration.editsTablesInPlace && !configuration.rawSourceMode && isEditable
    }

    // MARK: Lookup

    private var tableCoordinator: NativeTextViewCoordinator? {
        delegate as? NativeTextViewCoordinator
    }

    /// The table token starting at `start`, with its parsed form.
    func table(startingAt start: Int) -> (token: MarkdownToken, table: MarkdownStyler.ParsedTable)? {
        guard let coordinator = tableCoordinator else { return nil }
        let parsed = coordinator.parsedDocument(for: string)
        guard let token = parsed.tokens.first(where: { $0.kind == .table && $0.range.location == start }) else {
            return nil
        }
        let ns = string as NSString
        guard NSMaxRange(token.range) <= ns.length else { return nil }
        let source = ns.substring(with: token.range)
        guard let table = MarkdownStyler.tableMeta(for: source).parsed else { return nil }
        return (token, table)
    }

    /// The table token whose source contains `location`.
    func tableToken(containing location: Int) -> MarkdownToken? {
        guard let coordinator = tableCoordinator else { return nil }
        let parsed = coordinator.parsedDocument(for: string)
        return parsed.tokens.first { $0.kind == .table && NSLocationInRange(location, $0.range) }
    }

    /// The rendered image of the table at `range`, with its cell layout and anchor character.
    private func renderedTable(in range: NSRange) -> (image: NSImage, geometry: TableGeometry, anchor: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return nil }
        var found: (NSImage, TableGeometry, NSRange)?
        storage.enumerateAttribute(.latexImage, in: clamped, options: []) { value, attrRange, stop in
            if let image = value as? NSImage, let geometry = image.tableGeometry {
                found = (image, geometry, NSRange(location: attrRange.location, length: 1))
                stop.pointee = true
            }
        }
        return found
    }

    /// Where a cell sits, in the coordinates of the view that hosts the editor.
    /// Wide (scrolling) tables live in an overlay, so the editor joins it there.
    private func cellFrame(
        row: Int, column: Int,
        image: NSImage, geometry: TableGeometry, anchor: NSRange
    ) -> (host: NSView, frame: NSRect)? {
        guard let cell = geometry.cellRect(row: row, column: column), let storage = textStorage else { return nil }

        if let sourceID = storage.attribute(.scrollableBlockSourceID, at: anchor.location, effectiveRange: nil) as? Int {
            // The overlay is keyed by the table's content and refreshed lazily,
            // so right after an edit it can still be the old one (or missing).
            // Bring it up to date first, or the editor lands on stale geometry.
            if wideTableOverlays[sourceID]?.currentImage !== image {
                updateWideTableOverlays(immediately: true)
            }
            guard let overlay = wideTableOverlays[sourceID], overlay.currentImage === image else { return nil }
            // The overlay's image view is not flipped; the geometry is top-down.
            let inImageView = NSRect(x: cell.minX, y: image.size.height - cell.maxY,
                                     width: cell.width, height: cell.height)
            let inOverlay = overlay.convert(inImageView, from: overlay.tableImageViewForEditing)
            let host = overlay.superview ?? self
            return (host, host.convert(inOverlay, from: overlay))
        }

        guard let bridge = layoutBridge, let container = bridge.firstTextContainer else { return nil }
        let anchorRect = bridge.boundingRect(forCharacterRange: anchor, in: container)
        guard !anchorRect.isEmpty else { return nil }
        // The image is centred in its line, exactly as the layout fragment draws it.
        let imageTop = anchorRect.minY + max(0, (anchorRect.height - image.size.height) / 2)
        return (self, NSRect(
            x: textContainerOrigin.x + anchorRect.minX + cell.minX,
            y: textContainerOrigin.y + imageTop + cell.minY,
            width: cell.width,
            height: cell.height
        ))
    }

    // MARK: Entry points

    /// A click on a narrow table's image opens the cell under it. Wide tables
    /// get their clicks through the overlay (`WideTableImageView`).
    func beginTableCellEditingIfHit(event: NSEvent) -> Bool {
        guard canEditTablesInPlace, let storage = textStorage, storage.length > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let probe = min(max(characterIndexForInsertion(at: point), 0), storage.length - 1)
        guard let token = tableToken(containing: probe)
                ?? tableToken(containing: (storage.string as NSString).paragraphRange(
                    for: NSRange(location: probe, length: 0)).location),
              let rendered = renderedTable(in: token.range) else { return false }

        for row in 0..<rendered.geometry.rowCount {
            for column in 0..<rendered.geometry.columnCount {
                guard let placed = cellFrame(row: row, column: column, image: rendered.image,
                                             geometry: rendered.geometry, anchor: rendered.anchor),
                      placed.host === self, placed.frame.contains(point) else { continue }
                return beginTableCellEditing(tableStart: token.range.location, row: row, column: column,
                                             clickPoint: point)
            }
        }
        return false
    }

    /// Opens the editor on a cell, committing any cell already open.
    @discardableResult
    func beginTableCellEditing(
        tableStart: Int, row: Int, column: Int,
        clickPoint: NSPoint? = nil, selectAll: Bool = false
    ) -> Bool {
        guard canEditTablesInPlace else { return false }
        // Closing the open cell can rewrite its table; a table further down
        // then starts at a different offset.
        let previousStart = tableEditSession?.tableStart
        let lengthBefore = (string as NSString).length
        endTableCellEditing(restoreFocus: false)
        var tableStart = tableStart
        if let previousStart, previousStart < tableStart {
            tableStart += (string as NSString).length - lengthBefore
        }

        guard let (token, parsed) = table(startingAt: tableStart) else { return false }
        let row = min(max(row, 0), parsed.rowCount - 1)
        let column = min(max(column, 0), parsed.columnCount - 1)

        let editor = TableCellEditorView(owner: self)
        let session = TableEditSession(tableStart: token.range.location, row: row, column: column, editor: editor)
        tableEditSession = session
        loadTableCell(into: session, from: parsed)

        guard layoutTableCellEditor() else {
            editor.removeFromSuperview()
            tableEditSession = nil
            return false
        }
        window?.makeFirstResponder(editor)
        if selectAll {
            editor.selectAll(nil)
        } else if let clickPoint, editor.superview === self {
            let index = editor.characterIndexForInsertion(at: editor.convert(clickPoint, from: self))
            editor.setSelectedRange(NSRange(location: min(index, (editor.string as NSString).length), length: 0))
        } else {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
        return true
    }

    /// The caret reached a table by keyboard or programmatically: open a cell.
    /// Coming from above lands on the header, from below on the last row.
    func enterTableIfCaretInside(location: Int, previousLocation: Int?) {
        guard canEditTablesInPlace, tableEditSession == nil, !suppressTableEntry,
              let token = tableToken(containing: location) else { return }
        let fromBelow = (previousLocation ?? 0) >= NSMaxRange(token.range)
        let start = token.range.location
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tableEditSession == nil,
                  let (_, parsed) = self.table(startingAt: start) else { return }
            self.beginTableCellEditing(tableStart: start, row: fromBelow ? parsed.rowCount - 1 : 0,
                                       column: 0, selectAll: true)
        }
    }

    // MARK: Moving and ending

    func moveTableCellEditor(_ move: TableCellMove) {
        guard let session = tableEditSession, let (_, parsed) = table(startingAt: session.tableStart) else {
            endTableCellEditing(restoreFocus: true)
            return
        }
        let lastRow = parsed.rowCount - 1
        let lastColumn = parsed.columnCount - 1
        var row = session.row
        var column = session.column
        var appendsRow = false

        switch move {
        case .next:
            if column < lastColumn { column += 1 } else if row < lastRow { row += 1; column = 0 } else { appendsRow = true }
        case .right:
            if column < lastColumn { column += 1 } else if row < lastRow { row += 1; column = 0 } else { return }
        case .previous, .left:
            if column > 0 { column -= 1 } else if row > 0 { row -= 1; column = lastColumn } else { return }
        case .up:
            if row > 0 { row -= 1 } else { endTableCellEditing(exit: .above); return }
        case .down:
            if row < lastRow { row += 1 } else { endTableCellEditing(exit: .below); return }
        }

        var edited = parsed
        if appendsRow {
            edited = edited.insertingRow(at: edited.rowCount)
            row = edited.rowCount - 1
            if move == .next { column = 0 }
        }
        _ = commitCellText(of: session, into: edited)

        session.row = row
        session.column = column
        guard let (_, fresh) = table(startingAt: session.tableStart) else {
            endTableCellEditing(restoreFocus: true)
            return
        }
        loadTableCell(into: session, from: fresh)
        layoutTableCellEditor()
        let editor = session.editor
        let selectsAll = move == .next || move == .previous
        if selectsAll {
            editor.selectAll(nil)
        } else {
            let length = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: move == .right ? 0 : length, length: 0))
        }
    }

    /// Commits the open cell and closes the editor.
    func endTableCellEditing(exit: TableExit = .stay, restoreFocus: Bool = true) {
        guard let session = tableEditSession, !session.isFinishing else { return }
        session.isFinishing = true
        session.pendingSync?.cancel()
        if let (_, parsed) = table(startingAt: session.tableStart) {
            _ = commitCellText(of: session, into: parsed)
        }
        let tableRange = table(startingAt: session.tableStart)?.token.range
        session.editor.removeFromSuperview()
        tableEditSession = nil

        if restoreFocus { window?.makeFirstResponder(self) }
        guard let tableRange else { return }
        let length = (string as NSString).length
        var target: Int?
        switch exit {
        case .above:
            target = max(0, tableRange.location - 1)
        case .below:
            target = min(NSMaxRange(tableRange) + 1, length)
        case .stay:
            // The document caret must not be left inside the (collapsed) source.
            if NSLocationInRange(selectedRange().location, tableRange) {
                target = min(NSMaxRange(tableRange) + 1, length)
            }
        }
        if let target {
            suppressTableEntry = true
            setSelectedRange(NSRange(location: target, length: 0))
            suppressTableEntry = false
        }
    }

    // MARK: Document writes

    /// How long typing pauses before the cell is written to the document.
    private static let tableCellSyncDelay: TimeInterval = 0.05

    /// Writes the cell to the document shortly after typing pauses, so the
    /// table re-renders and its row grows with the text instead of the editor
    /// spilling over the rows below. Waits while an input method is composing.
    func scheduleTableCellSync() {
        guard let session = tableEditSession, !session.isFinishing else { return }
        session.pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, !session.isFinishing, self.tableEditSession === session else { return }
            if session.editor.hasMarkedText() {
                self.scheduleTableCellSync()
                return
            }
            self.syncTableCellToDocument()
        }
        session.pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tableCellSyncDelay, execute: work)
    }

    /// Writes the open cell's text into the document now (no-op when unchanged).
    func syncTableCellToDocument() {
        guard let session = tableEditSession, !session.isFinishing,
              let (_, parsed) = table(startingAt: session.tableStart) else { return }
        commitCellText(of: session, into: parsed)
        layoutTableCellEditor()
    }

    /// Puts the editor's text into `parsed` at the session's cell and, when
    /// that changes the table, replaces the table's source in one edit.
    /// Returns whether the document changed.
    @discardableResult
    private func commitCellText(of session: TableEditSession, into parsed: MarkdownStyler.ParsedTable) -> Bool {
        guard let (token, current) = table(startingAt: session.tableStart) else { return false }
        let edited = parsed.settingCell(row: session.row, column: session.column, to: session.editor.string)
        let newSource = edited.markdownSource()
        // Rewriting a table nobody changed would normalize its spacing and
        // dirty the document, so only write when the content differs.
        guard newSource != current.markdownSource() else { return false }
        suppressTableEntry = true
        MarkdownLists.performEdit(self, replace: token.range, with: newSource)
        suppressTableEntry = false
        return true
    }

    func loadTableCell(into session: TableEditSession, from parsed: MarkdownStyler.ParsedTable) {
        let raw = parsed.cell(row: session.row, column: session.column) ?? ""
        let editor = session.editor
        editor.string = MarkdownStyler.expandCellLineBreaks(raw)
        editor.font = tableCoordinator.map {
            TextStylingService.makeBaseFontAndStyle(
                fontName: $0.fontName, fontSize: $0.fontSize,
                layoutBridge: $0.layoutBridge, configuration: $0.configuration
            ).0
        } ?? .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = configuration.theme.bodyText
        editor.insertionPointColor = configuration.theme.bodyText
        editor.backgroundColor = backgroundColor.alphaComponent > 0 ? backgroundColor : .textBackgroundColor
        editor.drawsBackground = true
        editor.textContainerInset = NSSize(width: 12, height: 6)
        switch parsed.alignments[session.column] {
        case .left: editor.alignment = .left
        case .center: editor.alignment = .center
        case .right: editor.alignment = .right
        }
    }

    // MARK: Layout

    /// Puts the editor over its cell. Call after anything that can move or
    /// re-render the table. Returns false (and closes the session) when the
    /// table or cell can no longer be found.
    @discardableResult
    func layoutTableCellEditor() -> Bool {
        guard let session = tableEditSession, !session.isFinishing else { return false }
        guard let (token, parsed) = table(startingAt: session.tableStart),
              session.row < parsed.rowCount, session.column < parsed.columnCount,
              let rendered = renderedTable(in: token.range),
              let placed = cellFrame(row: session.row, column: session.column, image: rendered.image,
                                     geometry: rendered.geometry, anchor: rendered.anchor) else {
            if session.editor.superview != nil { session.editor.isHidden = true }
            return false
        }
        let editor = session.editor
        editor.isHidden = false
        if editor.superview !== placed.host {
            editor.removeFromSuperview()
            placed.host.addSubview(editor)
        }
        // A table overlay that was replaced after the editor was added sits
        // above it, and the table image is transparent — the cell's own text
        // would show through. Move the editor to the top. Re-adding it would
        // make it resign first responder, so reorder in place instead.
        if placed.host.subviews.last !== editor {
            placed.host.sortSubviews({ a, b, context in
                guard let context else { return .orderedSame }
                let top = Unmanaged<NSView>.fromOpaque(context).takeUnretainedValue()
                if a === top { return .orderedDescending }
                if b === top { return .orderedAscending }
                return .orderedSame
            }, context: Unmanaged.passUnretained(editor).toOpaque())
        }
        var frame = placed.frame
        // The column only widens once the typed text is written to the document
        // (a beat later). Until then let the editor grow sideways to fit its
        // longest line, or the new text wraps for a moment and snaps back. A cell
        // that already wraps in the table (its column is at the width cap) keeps
        // wrapping, since the column will not widen for it.
        let fit = editor.requiredWidth()
        let wrapsInTable = editor.requiredWidth(of: MarkdownStyler.expandCellLineBreaks(parsed.cell(row: session.row, column: session.column) ?? "")) > frame.width
        if fit > frame.width, !wrapsInTable {
            frame.size.width = min(fit, max(frame.width, placed.host.bounds.width - frame.minX))
        }
        editor.frame = frame
        // Taller text pushes the editor's bottom edge down over the rows below.
        let needed = editor.requiredHeight()
        session.outgrewCell = needed > placed.frame.height + 0.5
        if needed > frame.height {
            frame.size.height = needed
            editor.frame = frame
        }
        return true
    }
}

// MARK: - Row / column operations and the table menu

extension NativeTextView {

    /// Applies a row / column edit relative to the open cell. What the editor
    /// holds (even if not yet written) is kept, and the editor stays on the
    /// same content.
    func applyTableOperation(_ operation: TableOperation) {
        guard let session = tableEditSession, !session.isFinishing,
              let (token, current) = table(startingAt: session.tableStart) else { return }
        session.pendingSync?.cancel()
        let withCell = current.settingCell(row: session.row, column: session.column, to: session.editor.string)
        guard operation.isAvailable(row: session.row, column: session.column, in: withCell) else { return }
        let result = operation.apply(to: withCell, row: session.row, column: session.column)

        suppressTableEntry = true
        MarkdownLists.performEdit(self, replace: token.range, with: result.table.markdownSource())
        suppressTableEntry = false

        session.row = result.row
        session.column = result.column
        guard let (_, fresh) = table(startingAt: session.tableStart) else {
            endTableCellEditing()
            return
        }
        loadTableCell(into: session, from: fresh)
        layoutTableCellEditor()
        session.editor.setSelectedRange(NSRange(location: (session.editor.string as NSString).length, length: 0))
    }

    /// The menu to pop up in the cell editor: the editor's own menu, handed to
    /// the host's ``NativeTextViewWrapper/onTableCellContextMenu`` hook along
    /// with everything it needs to build the table items. Without a hook — the
    /// default — the menu comes back untouched.
    func tableCellContextMenu(_ menu: NSMenu) -> NSMenu {
        guard let hook = tableCoordinator?.onTableCellContextMenu,
              let context = tableCellMenuContext() else { return menu }
        return hook(menu, context)
    }

    /// What the host's menu needs about the open cell; nil when no cell is open
    /// or its row / column no longer resolves inside the table.
    func tableCellMenuContext() -> TableCellMenuContext? {
        guard let session = tableEditSession,
              let (_, parsed) = table(startingAt: session.tableStart),
              session.row < parsed.rowCount, session.column < parsed.columnCount else { return nil }
        return TableCellMenuContext(
            row: session.row,
            column: session.column,
            rowCount: parsed.rowCount,
            columnCount: parsed.columnCount,
            alignment: TableEditAlignment(parsed.alignments[session.column]),
            perform: { [weak self] operation in
                self?.applyTableOperation(operation.operation)
            }
        )
    }

    /// Right-click on a table's image opens the cell under the pointer and
    /// shows its menu.
    override func rightMouseDown(with event: NSEvent) {
        if beginTableCellEditingIfHit(event: event),
           let editor = tableEditSession?.editor,
           let menu = editor.menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: editor)
            return
        }
        super.rightMouseDown(with: event)
    }
}
