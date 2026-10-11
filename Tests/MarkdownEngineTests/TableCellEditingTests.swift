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
        // Not written yet: the write waits for typing to pause.
        #expect(tv.string.contains("| 1 | 2 |"))

        try await Task.sleep(nanoseconds: 500_000_000)
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
}
