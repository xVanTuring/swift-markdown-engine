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
        #expect(MarkdownStyler.ParsedTable.encodeCell("one\n\ntwo") == "one<br>two")
        #expect(MarkdownStyler.ParsedTable.encodeCell("\nedge\n") == "edge")
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
