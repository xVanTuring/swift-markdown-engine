//
//  TableCellEditingTests.swift
//  MarkdownEngineTests
//
//  In-place table editing: the table stays rendered with the caret inside it,
//  a cell editor opens on a cell, and leaving a cell writes it back to the
//  document as Markdown.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Table cell editing")
struct TableCellEditingTests {

    private static let table = "| a | b |\n|---|---|\n| 1 | 2 |"
    private static let doc = "intro\n\n\(table)\n\noutro\n"
    private static let tableStart = 7

    private func makeEditor(
        _ storage: String = doc, editsInPlace: Bool = true
    ) -> (NativeTextView, NativeTextViewCoordinator) {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.editsTablesInPlace = editsInPlace
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = configuration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        let coordinator = NativeTextViewCoordinator(
            text: .constant(storage),
            fontName: "SF Pro Text",
            fontSize: 14,
            isWikiLinkActive: .constant(false),
            onLinkClick: nil,
            onInlineSelectionChange: nil
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.configuration = configuration
        if let layoutManager = textView.textLayoutManager {
            let bridge = LayoutBridge(layoutManager)
            coordinator.layoutBridge = bridge
            textView.layoutBridge = bridge
        }
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return (textView, coordinator)
    }

    private func tableTokenIndex(_ coordinator: NativeTextViewCoordinator, _ tv: NativeTextView) -> Int? {
        coordinator.parsedDocument(for: tv.string).tokens.firstIndex { $0.kind == .table }
    }

    // MARK: Rendered state

    @Test func tableStaysRenderedWhileTheCaretIsInside() throws {
        let (tv, coordinator) = makeEditor()
        let parsed = coordinator.parsedDocument(for: tv.string)
        let index = try #require(tableTokenIndex(coordinator, tv))
        let inside = Self.tableStart + 3
        let active = coordinator.activeTokenIndices(
            parsed: parsed, selection: NSRange(location: inside, length: 0),
            in: tv.string as NSString, suppressed: false)
        #expect(!active.contains(index))
    }

    @Test func tableShowsSourceWhenInPlaceEditingIsOff() throws {
        let (tv, coordinator) = makeEditor(editsInPlace: false)
        let parsed = coordinator.parsedDocument(for: tv.string)
        let index = try #require(tableTokenIndex(coordinator, tv))
        let active = coordinator.activeTokenIndices(
            parsed: parsed, selection: NSRange(location: Self.tableStart + 3, length: 0),
            in: tv.string as NSString, suppressed: false)
        #expect(active.contains(index))
        #expect(!tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
    }

    // MARK: Row / column operations in the editor

    private static let wide = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |"
    private static let threeColumns = "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n"

    @Test func insertRowBelowAddsARowAndKeepsTheCell() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        tv.applyTableOperation(.insertRowBelow)
        #expect(tv.string == "| A | B |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n| 3 | 4 |\n")
        #expect(tv.tableEditSession?.row == 1)
        #expect(tv.tableEditSession?.editor.string == "1")
    }

    @Test func typingPastTheCellWidthGrowsTheEditorInsteadOfWrapping() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        let before = editor.frame
        editor.insertText("a long run of typed text", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.frame.width > before.width)
        #expect(editor.frame.height == before.height)
    }

    /// An input method's composition that outgrows the cell grows the row at
    /// once, and the write does not disturb the composition.
    @Test func composingTextThatOutgrowsTheCellGrowsTheRow() throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        let marked = String(repeating: "d ", count: 300)
        editor.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(tv.string.contains("d d d d d d"))
        #expect(tv.tableEditSession?.editor === editor)
    }

    @Test func textTypedButNotYetWrittenSurvivesAnOperation() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.tableEditSession?.editor.string = "typed"
        tv.applyTableOperation(.insertColumnLeft)
        #expect(tv.string.contains("| 1 |  | typed |"))
        #expect(tv.tableEditSession?.column == 2)
        #expect(tv.tableEditSession?.editor.string == "typed")
    }

    @Test func deleteRowRemovesItAndMovesTheEditor() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        tv.applyTableOperation(.deleteRow)
        #expect(!tv.string.contains("| 1 | 2 |"))
        #expect(tv.string.contains("| 3 | 4 |"))
        #expect(tv.tableEditSession?.editor.string == "3")
    }

    @Test func deleteColumnRemovesItFromEveryRow() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        tv.applyTableOperation(.deleteColumn)
        #expect(tv.string == "| B |\n| --- |\n| 2 |\n| 4 |\n")
    }

    @Test func movingARowReordersTheSource() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 2, column: 0))
        tv.applyTableOperation(.moveRowUp)
        #expect(tv.string == "| A | B |\n| --- | --- |\n| 3 | 4 |\n| 1 | 2 |\n")
        #expect(tv.tableEditSession?.row == 1)
        #expect(tv.tableEditSession?.editor.string == "3")
    }

    @Test func alignmentChangesTheDelimiterRowAndTheEditor() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.applyTableOperation(.align(.right))
        #expect(tv.string.contains("| --- | ---: |"))
        #expect(try #require(tv.tableEditSession?.editor).alignment == .right)
    }

    @Test func anUnavailableOperationLeavesTheDocumentAlone() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 0, column: 0))
        tv.applyTableOperation(.deleteRow)               // the header can't go
        #expect(tv.string == Self.wide + "\n")
    }

    @Test func anOperationIsOneUndoStep() {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        tv.allowsUndo = true
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        tv.applyTableOperation(.insertRowBelow)
        tv.endTableCellEditing()
        tv.undoManager?.undo()
        #expect(tv.string == Self.wide + "\n")
    }

    // MARK: Wide (scrolling) tables

    /// Ten long columns: wider than the 800pt view, so it renders in a
    /// horizontally scrolling overlay instead of in the text flow.
    private static let wideTable: String = {
        let columns = (0..<10).map { "Column\($0)xxxxxxxxxxxx" }
        let header = "| " + columns.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 10)
        let row = "| " + (0..<10).map { "cell\($0)" }.joined(separator: " | ") + " |"
        return [header, rule, row, row].joined(separator: "\n") + "\n"
    }()

    private func currentTableImage(_ tv: NativeTextView) -> NSImage? {
        var found: NSImage?
        tv.textStorage?.enumerateAttribute(
            .latexImage, in: NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        ) { value, _, stop in
            if let image = value as? NSImage, image.tableGeometry != nil { found = image; stop.pointee = true }
        }
        return found
    }

    @Test func aWideTableGetsAScrollingOverlay() {
        let (tv, coordinator) = makeEditor(Self.wideTable); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.wideTableOverlays.count == 1)
    }

    /// The overlay is keyed by the table's content, so a structural edit replaces
    /// it. The editor must follow the NEW overlay and image, not the stale ones.
    @Test func theEditorFollowsTheNewOverlayAfterAColumnIsInserted() throws {
        let (tv, coordinator) = makeEditor(Self.wideTable); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.applyTableOperation(.insertColumnRight)

        let image = try #require(currentTableImage(tv))
        let geometry = try #require(image.tableGeometry)
        #expect(geometry.columnCount == 11)
        let overlay = try #require(tv.wideTableOverlays.values.first)
        #expect(tv.wideTableOverlays.count == 1)
        #expect(overlay.currentImage === image)

        let editor = try #require(tv.tableEditSession?.editor)
        #expect(!editor.isHidden)
        #expect(editor.superview === overlay.superview)
        // The replacement overlay was added after the editor; the editor must
        // still be drawn above it, or the table's own text shows through.
        #expect(editor.superview?.subviews.last === editor)
        let cell = try #require(geometry.cellRect(row: 1, column: 1))
        #expect(abs(editor.frame.width - cell.width) < 1)
        #expect(abs(editor.frame.height - cell.height) < 1)
        // Vertically it sits inside the overlay's band, on the right row.
        #expect(editor.frame.minY >= overlay.frame.minY - 1)
        #expect(editor.frame.maxY <= overlay.frame.maxY + 1)
    }

    @Test func theEditorFollowsTheOverlayAfterAnAlignmentChange() throws {
        let (tv, coordinator) = makeEditor(Self.wideTable); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 2))
        tv.applyTableOperation(.align(.right))
        let image = try #require(currentTableImage(tv))
        let overlay = try #require(tv.wideTableOverlays.values.first)
        #expect(overlay.currentImage === image)
        let cell = try #require(image.tableGeometry?.cellRect(row: 1, column: 2))
        let editor = try #require(tv.tableEditSession?.editor)
        #expect(abs(editor.frame.width - cell.width) < 1)
    }

    // MARK: The table menu seam

    private func rightClickEvent() throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Opens a cell, installs `hook` as the coordinator's table-menu hook and
    /// returns the menu the editor shows plus the context the hook received.
    private func menuForOpenCell(
        _ tv: NativeTextView, _ coordinator: NativeTextViewCoordinator,
        _ hook: @escaping (NSMenu, TableCellMenuContext) -> NSMenu
    ) throws -> (menu: NSMenu, context: TableCellMenuContext) {
        var context: TableCellMenuContext?
        coordinator.onTableCellContextMenu = { menu, ctx in
            context = ctx
            return hook(menu, ctx)
        }
        let editor = try #require(tv.tableEditSession?.editor)
        let menu = try #require(editor.menu(for: try rightClickEvent()))
        return (menu, try #require(context))
    }

    @Test func theHookGetsTheMenuAndTheOpenCellsContext() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        var menuGiven: NSMenu?
        let (menu, context) = try menuForOpenCell(tv, coordinator) { menu, _ in
            menuGiven = menu
            return menu
        }

        #expect(context.row == 1)
        #expect(context.column == 1)
        #expect(context.rowCount == 3)          // header + two body rows
        #expect(context.columnCount == 2)
        #expect(context.alignment == .left)
        // The editor's own text items travel with the menu, and what the hook
        // returns is what is shown.
        #expect(menu === menuGiven)
        #expect(!menu.items.isEmpty)
    }

    @Test func theHookCanReplaceTheMenuItIsGiven() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let (menu, _) = try menuForOpenCell(tv, coordinator) { _, _ in
            let custom = NSMenu()
            custom.addItem(withTitle: "Table", action: nil, keyEquivalent: "")
            return custom
        }
        #expect(menu.items.map(\.title) == ["Table"])
    }

    @Test func isEnabledFollowsTheAvailabilityRules() throws {
        let (tv, coordinator) = makeEditor(Self.threeColumns); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))    // first body row, first column
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }

        #expect(context.isEnabled(.insertRowAbove))
        #expect(context.isEnabled(.insertRowBelow))
        #expect(context.isEnabled(.deleteRow))
        #expect(!context.isEnabled(.moveRowUp))          // can't move up into the header
        #expect(context.isEnabled(.moveRowDown))
        #expect(!context.isEnabled(.moveColumnLeft))     // already the first column
        #expect(context.isEnabled(.moveColumnRight))
        #expect(context.isEnabled(.deleteColumn))
        #expect(context.isEnabled(.alignLeft))           // checked, but still clickable
        #expect(context.isEnabled(.alignCenter))
        #expect(context.isEnabled(.alignRight))
    }

    @Test func theHeaderRowAndLastColumnRestrictTheMenu() throws {
        let (tv, coordinator) = makeEditor(Self.threeColumns); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 0, column: 2))    // header, last column
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }

        #expect(!context.isEnabled(.insertRowAbove))
        #expect(!context.isEnabled(.deleteRow))
        #expect(!context.isEnabled(.moveRowUp))
        #expect(!context.isEnabled(.moveRowDown))        // nothing below the header to swap with
        #expect(context.isEnabled(.insertRowBelow))
        #expect(!context.isEnabled(.moveColumnRight))    // already the last column
        #expect(context.isEnabled(.deleteColumn))        // three columns, so one can go
    }

    @Test func theLastRemainingColumnCannotBeDeleted() throws {
        let (tv, coordinator) = makeEditor("| A |\n| --- |\n| 1 |\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }
        #expect(!context.isEnabled(.deleteColumn))
        #expect(context.isEnabled(.insertColumnLeft))
        #expect(context.isEnabled(.insertColumnRight))
    }

    @Test func theContextReportsTheOpenColumnsAlignment() throws {
        let (tv, coordinator) = makeEditor("| A | B |\n|---|--:|\n| 1 | 2 |\n")
        defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }

        #expect(context.alignment == .right)
        #expect(context.isEnabled(.alignRight))          // checked, but still clickable
        #expect(context.isEnabled(.alignLeft))
    }

    @Test func performLandsOneUndoableEditAndKeepsTheCaretInTheTable() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        tv.allowsUndo = true
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }

        context.perform(.insertRowBelow)
        #expect(tv.string == "| A | B |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n| 3 | 4 |\n")
        #expect(tv.tableEditSession?.row == 1)
        #expect(tv.tableEditSession?.editor.string == "1")

        tv.endTableCellEditing()
        tv.undoManager?.undo()
        #expect(tv.string == Self.wide + "\n")
    }

    @Test func performCanAlignTheColumn() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        let (_, context) = try menuForOpenCell(tv, coordinator) { menu, _ in menu }
        context.perform(.alignRight)
        #expect(tv.string.contains("| --- | ---: |"))
    }

    @Test func withoutAHookTheEditorsOwnMenuIsShownUnchanged() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        let menu = try #require(editor.menu(for: try rightClickEvent()))
        #expect(!menu.items.isEmpty)                     // the ordinary text menu
        #expect(!menu.items.contains { $0.title == "Table" })
    }

    @Test func settingTheHookToNilAddsNothing() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        coordinator.onTableCellContextMenu = { _, _ in
            let custom = NSMenu()
            custom.addItem(withTitle: "Table", action: nil, keyEquivalent: "")
            return custom
        }
        #expect(try #require(editor.menu(for: try rightClickEvent())).items.contains { $0.title == "Table" })

        coordinator.onTableCellContextMenu = nil
        #expect(!(try #require(editor.menu(for: try rightClickEvent())).items.contains { $0.title == "Table" }))
    }

    @Test func theHookIsNotCalledWithoutAnOpenCell() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        var called = false
        coordinator.onTableCellContextMenu = { menu, _ in called = true; return menu }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        tv.endTableCellEditing()
        _ = editor.menu(for: try rightClickEvent())
        #expect(!called)
    }

    @Test func everyInternalOperationHasAPublicCase() {
        let internalOperations: [TableOperation] = [
            .insertRowAbove, .insertRowBelow, .deleteRow, .moveRowUp, .moveRowDown,
            .insertColumnLeft, .insertColumnRight, .deleteColumn, .moveColumnLeft, .moveColumnRight,
            .align(.left), .align(.center), .align(.right),
        ]
        #expect(TableEditOperation.allCases.map { $0.operation } == internalOperations)
        #expect(internalOperations.map { TableEditOperation($0).operation } == internalOperations)
    }

    // MARK: The switch

    @Test func switchingItOffWhileACellIsOpenCommitsAndCloses() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "typed"
        var off = tv.configuration
        off.editsTablesInPlace = false
        tv.configuration = off
        #expect(tv.tableEditSession == nil)
        #expect(tv.string.contains("| typed | 2 |"))
    }

    @Test func rawSourceModeNeverOpensACellEditor() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        var raw = tv.configuration
        raw.rawSourceMode = true
        tv.configuration = raw
        #expect(!tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        #expect(tv.tableEditSession == nil)
    }

    @Test func aReadOnlyViewNeverOpensACellEditor() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        tv.isEditable = false
        #expect(!tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
    }

    @Test func caretEntryIsIgnoredWhenTheSwitchIsOff() async throws {
        let (tv, coordinator) = makeEditor(editsInPlace: false); defer { withExtendedLifetime(coordinator) {} }
        tv.enterTableIfCaretInside(location: Self.tableStart + 2, previousLocation: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(tv.tableEditSession == nil)
    }

    @Test func theDefaultIsOn() {
        #expect(MarkdownEditorConfiguration.default.editsTablesInPlace)
        #expect(MarkdownEditorConfiguration().editsTablesInPlace)
    }

    // MARK: Opening

    @Test func openingACellShowsItsRawMarkdown() throws {
        let (tv, _) = makeEditor("| **a** | b |\n|---|---|\n| 1 | 2 |\n")
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 0, column: 0))
        let session = try #require(tv.tableEditSession)
        #expect(session.editor.string == "**a**")
        #expect(session.editor.superview != nil)
        #expect(session.editor.frame.width > 0)
    }

    /// The text view's own `font` is a hidden-marker size; the editor must use
    /// the body font or its text is laid out at a fraction of a point.
    @Test func theEditorUsesTheBodyFont() throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        #expect((editor.font?.pointSize ?? 0) >= 10)
        let layout = try #require(editor.layoutManager)
        let container = try #require(editor.textContainer)
        #expect(layout.usedRect(for: container).height > 5)
    }

    @Test func aLineBreakCellOpensWithARealNewline() throws {
        let (tv, _) = makeEditor("| a | b |\n|---|---|\n| one<br>two | 2 |\n")
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 0))
        #expect(tv.tableEditSession?.editor.string == "one\ntwo")
    }

    // MARK: Writing back

    @Test func leavingAnEditedCellWritesItBack() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "**done**"
        tv.endTableCellEditing()
        #expect(tv.tableEditSession == nil)
        #expect(tv.string.contains("| **done** | 2 |"))
        #expect(tv.string.hasPrefix("intro\n\n"))
        #expect(tv.string.hasSuffix("\n\noutro\n"))
    }

    @Test func leavingAnUnchangedCellLeavesTheSourceUntouched() {
        // Hand-aligned spacing must survive merely visiting a cell.
        let spaced = "|  a   |  b  |\n|------|-----|\n|  1   |  2  |\n"
        let (tv, _) = makeEditor(spaced)
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.endTableCellEditing()
        #expect(tv.string == spaced)
    }

    @Test func aPipeTypedInACellIsEscaped() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "x | y"
        tv.endTableCellEditing()
        #expect(tv.string.contains("| x \\| y | 2 |"))
    }

    @Test func aTypedNewlineBecomesBr() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "one\ntwo"
        tv.endTableCellEditing()
        #expect(tv.string.contains("| one<br>two | 2 |"))
    }

    @Test func theEditIsOneUndoStep() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        tv.allowsUndo = true
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "changed"
        tv.endTableCellEditing()
        #expect(tv.string.contains("| changed | 2 |"))
        tv.undoManager?.undo()
        #expect(tv.string.contains("| 1 | 2 |"))
    }

    // MARK: Moving

    @Test func tabMovesToTheNextCellAndCommitsTheOne_itLeft() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "X"
        tv.moveTableCellEditor(.next)
        #expect(tv.string.contains("| X | 2 |"))
        #expect(tv.tableEditSession?.row == 1)
        #expect(tv.tableEditSession?.column == 1)
        #expect(tv.tableEditSession?.editor.string == "2")
    }

    @Test func tabWrapsToTheNextRow() {
        let (tv, _) = makeEditor("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n")
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.moveTableCellEditor(.next)
        #expect(tv.tableEditSession?.row == 2)
        #expect(tv.tableEditSession?.column == 0)
        #expect(tv.tableEditSession?.editor.string == "3")
    }

    @Test func tabInTheLastCellAppendsARow() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 1))
        tv.moveTableCellEditor(.next)
        #expect(tv.string.contains("|  |  |"))
        #expect(tv.tableEditSession?.row == 2)
        #expect(tv.tableEditSession?.column == 0)
    }

    @Test func returnBreaksTheLineInsideTheCell() throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(editor.string == "1\n")
        #expect(tv.tableEditSession?.row == 1)          // still in the same cell
        #expect(tv.tableEditSession?.column == 0)
    }

    // MARK: Live sync

    @Test func typingWritesThroughAndTheRowGrows() async throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        let heightBefore = editor.frame.height

        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.insertText("\nsecond\nthird", replacementRange: editor.selectedRange())
        // Taller than the cell: written at once, so the row grows without a
        // frame where the editor spills over the rows below.
        #expect(tv.string.contains("| 1<br>second<br>third | 2 |"))

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(tv.string.contains("| 1<br>second<br>third | 2 |"))
        // The table re-rendered taller and the editor followed its cell.
        #expect(editor.frame.height > heightBefore)
        #expect(tv.tableEditSession?.editor === editor)
        #expect(editor.string == "1\nsecond\nthird")
    }

    /// A bare Return adds an empty line; it must not be trimmed away, or the row
    /// would never grow until text follows.
    @Test func aBareReturnGrowsTheRow() async throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        let editor = try #require(tv.tableEditSession?.editor)
        let heightBefore = editor.frame.height
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(tv.string.contains("| 1<br> | 2 |"))
        #expect(editor.frame.height > heightBefore)
        #expect(editor.string == "1\n")
    }

    @Test func leavingBeforeThePauseStillWritesTheCell() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.insertText("Z", replacementRange: NSRange(location: 1, length: 0))
        tv.endTableCellEditing()
        #expect(tv.string.contains("| 1Z | 2 |"))
    }

    @Test func shiftTabMovesBackAndStopsAtTheFirstCell() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.moveTableCellEditor(.previous)
        #expect(tv.tableEditSession?.row == 0)
        #expect(tv.tableEditSession?.column == 1)
        tv.moveTableCellEditor(.previous)
        tv.moveTableCellEditor(.previous)
        #expect(tv.tableEditSession?.row == 0)
        #expect(tv.tableEditSession?.column == 0)
    }

    // MARK: Leaving the table

    @Test func upFromTheHeaderLeavesAboveTheTable() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 0, column: 0))
        tv.moveTableCellEditor(.up)
        #expect(tv.tableEditSession == nil)
        #expect(tv.selectedRange().location < Self.tableStart)
    }

    @Test func downFromTheLastRowLeavesBelowTheTable() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.moveTableCellEditor(.down)
        #expect(tv.tableEditSession == nil)
        #expect(tv.selectedRange().location > Self.tableStart + Self.table.count)
    }

    @Test func escapeKeepsTheEditAndClosesTheEditor() {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        #expect(tv.beginTableCellEditing(tableStart: Self.tableStart, row: 1, column: 0))
        tv.tableEditSession?.editor.string = "kept"
        tv.endTableCellEditing(exit: .stay)
        #expect(tv.tableEditSession == nil)
        #expect(tv.string.contains("| kept | 2 |"))
    }

    // MARK: Caret entry

    @Test func aCaretArrivingInATableOpensItsFirstCell() async throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        tv.enterTableIfCaretInside(location: Self.tableStart + 2, previousLocation: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(tv.tableEditSession?.row == 0)
        #expect(tv.tableEditSession?.column == 0)
    }

    @Test func aCaretArrivingFromBelowOpensTheLastRow() async throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        tv.enterTableIfCaretInside(location: Self.tableStart + 2,
                                   previousLocation: Self.tableStart + Self.table.count + 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(tv.tableEditSession?.row == 1)
    }

    @Test func aCaretOutsideTablesOpensNothing() async throws {
        let (tv, coordinator) = makeEditor(); defer { withExtendedLifetime(coordinator) {} }
        tv.enterTableIfCaretInside(location: 2, previousLocation: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(tv.tableEditSession == nil)
    }

    // MARK: Cell selection

    @Test func deleteOnASelectedRowClearsThenRemoves() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        tv.setTableSelection(tableStart: 0, TableCellSelection(rows: 2...2, columns: 0...1))
        tv.deleteTableSelection()
        #expect(tv.string == "| A | B |\n| --- | --- |\n| 1 | 2 |\n|  |  |\n")
        #expect(tv.tableSelectionState != nil)
        tv.deleteTableSelection()
        #expect(tv.string == "| A | B |\n| --- | --- |\n| 1 | 2 |\n")
        #expect(tv.tableSelectionState == nil)
    }

    @Test func clearOnlyKeepsTheShape() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        tv.configuration.tableInteraction.deleteBehavior = .clearOnly
        tv.setTableSelection(tableStart: 0, TableCellSelection(rows: 1...1, columns: 0...1))
        tv.deleteTableSelection()
        tv.deleteTableSelection()
        #expect(tv.string == "| A | B |\n| --- | --- |\n|  |  |\n| 3 | 4 |\n")
    }

    @Test func turningSelectionOffDropsIt() throws {
        let (tv, coordinator) = makeEditor(Self.wide + "\n"); defer { withExtendedLifetime(coordinator) {} }
        tv.setTableSelection(tableStart: 0, TableCellSelection(rows: 1...1, columns: 0...1))
        #expect(tv.tableSelectionState != nil)
        tv.configuration.tableInteraction.selectsCells = false
        #expect(tv.tableSelectionState == nil)
    }
}
