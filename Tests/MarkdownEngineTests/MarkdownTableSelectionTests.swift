//
//  MarkdownTableSelectionTests.swift
//  MarkdownEngineTests
//

import Testing
@testable import MarkdownEngine

@Suite("Markdown table selection model")
struct MarkdownTableSelectionTests {

    private let source = """
    | A | B | C |
    | --- | --- | --- |
    | 1 | 2 | 3 |
    | 4 | 5 | 6 |
    | 7 | 8 | 9 |
    """

    private func parse(_ s: String? = nil) throws -> MarkdownStyler.ParsedTable {
        try #require(MarkdownStyler.parseTableSource(s ?? source))
    }

    private func sel(_ r: ClosedRange<Int>, _ c: ClosedRange<Int>) -> TableCellSelection {
        TableCellSelection(rows: r, columns: c)
    }

    @Test("shape tells whole rows, whole columns and plain blocks apart")
    func shapes() throws {
        let t = try parse()
        #expect(sel(2...3, 0...2).shape(in: t) == .rows)
        #expect(sel(0...3, 1...1).shape(in: t) == .columns)
        #expect(sel(1...2, 0...1).shape(in: t) == .cells)
        #expect(sel(0...3, 0...2).shape(in: t) == .cells)
    }

    @Test("clearing empties only the selected cells")
    func clearing() throws {
        let t = try parse().clearing(sel(1...2, 1...2))
        #expect(t.rows == [["1", "", ""], ["4", "", ""], ["7", "8", "9"]])
        #expect(t.header == ["A", "B", "C"])
    }

    @Test("removing rows leaves the header alone and keeps order")
    func removingRows() throws {
        let t = try parse()
        #expect(t.removingRows(2...3).rows == [["1", "2", "3"]])
        #expect(t.removingRows(0...1).rows == [["4", "5", "6"], ["7", "8", "9"]])
        #expect(t.removingRows(0...0).rows == t.rows)
    }

    @Test("removing columns keeps at least one")
    func removingColumns() throws {
        let t = try parse()
        #expect(t.removingColumns(1...1).header == ["A", "C"])
        #expect(t.removingColumns(0...1).rows == [["3"], ["6"], ["9"]])
        #expect(t.removingColumns(0...2).columnCount == 3)
    }

    @Test("moving a row or column to any position")
    func moving() throws {
        let t = try parse()
        #expect(t.movingRow(from: 1, to: 3).rows == [["4", "5", "6"], ["7", "8", "9"], ["1", "2", "3"]])
        #expect(t.movingRow(from: 3, to: 1).rows == [["7", "8", "9"], ["1", "2", "3"], ["4", "5", "6"]])
        #expect(t.movingRow(from: 0, to: 2).rows == t.rows)
        #expect(t.movingRow(from: 2, to: 0).rows == t.rows)
        let c = t.movingColumn(from: 0, to: 2)
        #expect(c.header == ["B", "C", "A"])
        #expect(c.rows[0] == ["2", "3", "1"])
    }

    @Test("clearThenRemove: content is cleared first, then the row goes")
    func twoStage() throws {
        let t = try parse()
        let rows = sel(2...2, 0...2)
        let first = t.deleting(rows, behavior: .clearThenRemove)
        #expect(first.table.rows[1] == ["", "", ""])
        #expect(first.selection == rows)
        let second = first.table.deleting(rows, behavior: .clearThenRemove)
        #expect(second.table.rows == [["1", "2", "3"], ["7", "8", "9"]])
        #expect(second.selection == nil)
    }

    @Test("clearOnly never changes the shape, removeOnly ignores content")
    func otherBehaviors() throws {
        let t = try parse()
        let col = sel(0...3, 1...1)
        let cleared = t.deleting(col, behavior: .clearOnly)
        #expect(cleared.table.columnCount == 3)
        #expect(cleared.table.header == ["A", "", "C"])
        let removed = t.deleting(col, behavior: .removeOnly)
        #expect(removed.table.header == ["A", "C"])
        #expect(removed.selection == nil)
    }

    @Test("a plain block is only ever cleared; an empty header row stays")
    func blocksAndHeader() throws {
        let t = try parse()
        let block = sel(1...2, 0...1)
        let a = t.deleting(block, behavior: .removeOnly)
        #expect(a.table.rowCount == t.rowCount)
        #expect(a.table.rows[0] == ["", "", "3"])
        let header = sel(0...0, 0...2)
        let b = t.clearing(header).deleting(header, behavior: .clearThenRemove)
        #expect(b.table.rowCount == t.rowCount)
        #expect(b.selection == header)
    }
}
