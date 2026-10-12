//
//  MarkdownTableEditingTests.swift
//  MarkdownEngineTests
//

import Testing
@testable import MarkdownEngine

@Suite("Markdown table editing model")
struct MarkdownTableEditingTests {

    private let source = """
    | Name | Age |
    | :--- | ---: |
    | Ann | 30 |
    | Bob | 41 |
    """

    private func parse(_ s: String) throws -> MarkdownStyler.ParsedTable {
        try #require(MarkdownStyler.parseTableSource(s))
    }

    @Test("serializing keeps cells and alignment, and re-parses to the same table")
    func roundTrip() throws {
        let table = try parse(source)
        let out = table.markdownSource()
        #expect(out == """
        | Name | Age |
        | --- | ---: |
        | Ann | 30 |
        | Bob | 41 |
        """)
        let again = try parse(out)
        #expect(again.header == table.header)
        #expect(again.rows == table.rows)
        #expect(again.alignments == table.alignments)
    }

    @Test("a pipe in a cell is escaped and survives a round trip")
    func pipeEscaping() throws {
        let table = try parse(source).settingCell(row: 1, column: 0, to: "a | b")
        let out = table.markdownSource()
        #expect(out.contains("| a \\| b | 30 |"))
        #expect(try parse(out).rows[0][0] == "a | b")
    }

    @Test("an existing escape is not escaped twice")
    func noDoubleEscape() {
        #expect(MarkdownStyler.ParsedTable.encodeCell("a \\| b") == "a \\| b")
    }

    @Test("a line break becomes <br>")
    func lineBreak() {
        #expect(MarkdownStyler.ParsedTable.encodeCell("one\ntwo") == "one<br>two")
        #expect(MarkdownStyler.ParsedTable.encodeCell("one\n\ntwo") == "one<br><br>two")
        #expect(MarkdownStyler.ParsedTable.encodeCell("\nedge\n") == "<br>edge<br>")
        #expect(MarkdownStyler.ParsedTable.encodeCell("  pad  ") == "pad")
    }

    @Test("setting a header or body cell")
    func setCell() throws {
        let table = try parse(source)
        #expect(table.settingCell(row: 0, column: 1, to: "Years").header == ["Name", "Years"])
        #expect(table.settingCell(row: 2, column: 0, to: "Zed").rows[1] == ["Zed", "41"])
        #expect(table.settingCell(row: 9, column: 0, to: "x").rows == table.rows)
    }

    @Test("inserting rows keeps the column count")
    func insertRow() throws {
        let table = try parse(source)
        #expect(table.insertingRow(at: 1).rows == [["", ""], ["Ann", "30"], ["Bob", "41"]])
        #expect(table.insertingRow(at: 3).rows == [["Ann", "30"], ["Bob", "41"], ["", ""]])
        #expect(table.insertingRow(at: 0).rows.first == ["", ""])   // clamped below the header
    }

    @Test("removing rows never removes the header")
    func removeRow() throws {
        let table = try parse(source)
        #expect(table.removingRow(at: 1).rows == [["Bob", "41"]])
        #expect(table.removingRow(at: 0).rows == table.rows)
        #expect(table.removingRow(at: 5).rows == table.rows)
    }

    @Test("moving rows swaps neighbours within the body")
    func moveRow() throws {
        let table = try parse(source)
        #expect(table.movingRow(at: 1, by: 1).rows == [["Bob", "41"], ["Ann", "30"]])
        #expect(table.movingRow(at: 1, by: -1).rows == table.rows)   // can't pass the header
        #expect(table.movingRow(at: 2, by: 1).rows == table.rows)
    }

    @Test("inserting and removing columns updates every row and the alignment")
    func columns() throws {
        let table = try parse(source)
        let inserted = table.insertingColumn(at: 1)
        #expect(inserted.header == ["Name", "", "Age"])
        #expect(inserted.alignments == [.left, .left, .right])
        #expect(inserted.rows == [["Ann", "", "30"], ["Bob", "", "41"]])

        let removed = table.removingColumn(at: 0)
        #expect(removed.header == ["Age"])
        #expect(removed.alignments == [.right])
        #expect(removed.rows == [["30"], ["41"]])
    }

    @Test("the last column cannot be removed")
    func keepsLastColumn() throws {
        let single = try parse("| A |\n| --- |\n| 1 |")
        #expect(single.removingColumn(at: 0).columnCount == 1)
    }

    @Test("moving columns carries alignment with it")
    func moveColumn() throws {
        let table = try parse(source).movingColumn(at: 0, by: 1)
        #expect(table.header == ["Age", "Name"])
        #expect(table.alignments == [.right, .left])
        #expect(table.rows == [["30", "Ann"], ["41", "Bob"]])
    }

    @Test("setting alignment shows up in the delimiter row")
    func alignment() throws {
        let out = try parse(source).settingAlignment(.center, column: 0).markdownSource()
        #expect(out.contains("| :---: | ---: |"))
    }
}

@Suite("Table operations on the edited cell")
struct TableOperationTests {

    // header + 2 body rows, 3 columns
    private let source = """
    | A | B | C |
    | --- | --- | --- |
    | 1 | 2 | 3 |
    | 4 | 5 | 6 |
    """

    private func table() throws -> MarkdownStyler.ParsedTable {
        try #require(MarkdownStyler.parseTableSource(source))
    }

    // MARK: Availability

    @Test("the header row can't be removed, moved, or have a row put above it")
    func headerRestrictions() throws {
        let t = try table()
        #expect(!TableOperation.insertRowAbove.isAvailable(row: 0, column: 0, in: t))
        #expect(!TableOperation.deleteRow.isAvailable(row: 0, column: 0, in: t))
        #expect(!TableOperation.moveRowUp.isAvailable(row: 0, column: 0, in: t))
        #expect(!TableOperation.moveRowDown.isAvailable(row: 0, column: 0, in: t))
        #expect(TableOperation.insertRowBelow.isAvailable(row: 0, column: 0, in: t))
    }

    @Test("the first body row can't move up into the header; the last can't move down")
    func rowMoveEdges() throws {
        let t = try table()
        #expect(!TableOperation.moveRowUp.isAvailable(row: 1, column: 0, in: t))
        #expect(TableOperation.moveRowUp.isAvailable(row: 2, column: 0, in: t))
        #expect(TableOperation.moveRowDown.isAvailable(row: 1, column: 0, in: t))
        #expect(!TableOperation.moveRowDown.isAvailable(row: 2, column: 0, in: t))
    }

    @Test("column moves stop at the edges, and the last column can't be deleted")
    func columnEdges() throws {
        let t = try table()
        #expect(!TableOperation.moveColumnLeft.isAvailable(row: 1, column: 0, in: t))
        #expect(!TableOperation.moveColumnRight.isAvailable(row: 1, column: 2, in: t))
        #expect(TableOperation.deleteColumn.isAvailable(row: 1, column: 0, in: t))
        let single = try #require(MarkdownStyler.parseTableSource("| A |\n| --- |\n| 1 |"))
        #expect(!TableOperation.deleteColumn.isAvailable(row: 1, column: 0, in: single))
    }

    @Test("choosing the alignment a column already has is unavailable")
    func alignmentAvailability() throws {
        let t = try table()
        #expect(!TableOperation.align(.left).isAvailable(row: 1, column: 0, in: t))
        #expect(TableOperation.align(.right).isAvailable(row: 1, column: 0, in: t))
    }

    // MARK: Effect on the table and on where the caret ends up

    @Test("insert row above keeps the caret on the same content")
    func insertAbove() throws {
        let r = TableOperation.insertRowAbove.apply(to: try table(), row: 2, column: 1)
        #expect(r.table.rows == [["1", "2", "3"], ["", "", ""], ["4", "5", "6"]])
        #expect(r.table.cell(row: r.row, column: r.column) == "5")
    }

    @Test("insert row below leaves the caret where it was")
    func insertBelow() throws {
        let r = TableOperation.insertRowBelow.apply(to: try table(), row: 1, column: 1)
        #expect(r.table.rows == [["1", "2", "3"], ["", "", ""], ["4", "5", "6"]])
        #expect(r.table.cell(row: r.row, column: r.column) == "2")
    }

    @Test("insert row below the header goes first in the body")
    func insertBelowHeader() throws {
        let r = TableOperation.insertRowBelow.apply(to: try table(), row: 0, column: 0)
        #expect(r.table.rows.first == ["", "", ""])
        #expect(r.table.header == ["A", "B", "C"])
        #expect(r.row == 0)
    }

    @Test("delete row lands on the row that took its place, or the one before at the end")
    func deleteRow() throws {
        let middle = TableOperation.deleteRow.apply(to: try table(), row: 1, column: 2)
        #expect(middle.table.rows == [["4", "5", "6"]])
        #expect(middle.table.cell(row: middle.row, column: middle.column) == "6")

        let last = TableOperation.deleteRow.apply(to: try table(), row: 2, column: 0)
        #expect(last.table.rows == [["1", "2", "3"]])
        #expect(last.row == 1)
    }

    @Test("moving a row carries the caret with it")
    func moveRow() throws {
        let up = TableOperation.moveRowUp.apply(to: try table(), row: 2, column: 1)
        #expect(up.table.rows == [["4", "5", "6"], ["1", "2", "3"]])
        #expect(up.table.cell(row: up.row, column: up.column) == "5")

        let down = TableOperation.moveRowDown.apply(to: try table(), row: 1, column: 1)
        #expect(down.table.cell(row: down.row, column: down.column) == "2")
    }

    @Test("insert column left / right keep the caret on the same content")
    func insertColumns() throws {
        let left = TableOperation.insertColumnLeft.apply(to: try table(), row: 1, column: 1)
        #expect(left.table.header == ["A", "", "B", "C"])
        #expect(left.table.cell(row: left.row, column: left.column) == "2")

        let right = TableOperation.insertColumnRight.apply(to: try table(), row: 1, column: 1)
        #expect(right.table.header == ["A", "B", "", "C"])
        #expect(right.table.cell(row: right.row, column: right.column) == "2")
    }

    @Test("delete column lands on the neighbour, or the one before at the end")
    func deleteColumn() throws {
        let middle = TableOperation.deleteColumn.apply(to: try table(), row: 1, column: 1)
        #expect(middle.table.header == ["A", "C"])
        #expect(middle.table.cell(row: middle.row, column: middle.column) == "3")

        let last = TableOperation.deleteColumn.apply(to: try table(), row: 1, column: 2)
        #expect(last.table.header == ["A", "B"])
        #expect(last.column == 1)
    }

    @Test("moving a column carries the caret and the alignment with it")
    func moveColumn() throws {
        let aligned = try table().settingAlignment(.right, column: 1)
        let r = TableOperation.moveColumnLeft.apply(to: aligned, row: 1, column: 1)
        #expect(r.table.header == ["B", "A", "C"])
        #expect(r.table.alignments == [.right, .left, .left])
        #expect(r.table.cell(row: r.row, column: r.column) == "2")
    }

    @Test("an unavailable operation changes nothing")
    func unavailableIsANoOp() throws {
        let t = try table()
        let r = TableOperation.deleteRow.apply(to: t, row: 0, column: 0)
        #expect(r.table.rows == t.rows)
        #expect(r.table.header == t.header)
        #expect(r.row == 0 && r.column == 0)
    }
}
