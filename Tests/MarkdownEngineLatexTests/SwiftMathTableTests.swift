//
//  SwiftMathTableTests.swift
//  MarkdownEngineLatexTests
//
//  SwiftMath's `aligned` only takes two columns and its parser does not read `\\[6pt]`;
//  the bridge builds such environments itself (LatexTables.swift).
//
//  Typesets directly instead of through `SwiftMathBridge.render`: the bridge's disk cache
//  would hand back an earlier run's image and never typeset again.
//

import AppKit
import Testing
import SwiftMath
import MarkdownEngine
@testable import MarkdownEngineLatex

@MainActor
@Suite("SwiftMath table environments")
struct SwiftMathTableTests {
    private func parsed(_ latex: String) throws -> MTMathList {
        var error: NSError?
        let list = try #require(SwiftMathBridge.parseFormula(latex, error: &error), "\(latex): \(String(describing: error))")
        #expect(error == nil, "\(latex)")
        SwiftMathBridge.settleBinarySigns(in: list)
        SwiftMathBridge.keepTablesIntactInLabel(list)   // as the bridge does before handing it to the label
        return list
    }

    private func table(_ latex: String) throws -> MTMathTable {
        var found: MTMathTable?
        SwiftMathBridge.forEachList(in: try parsed(latex)) { list in
            if found == nil { found = list.atoms.lazy.compactMap { $0 as? MTMathTable }.first }
        }
        return try #require(found, "\(latex)")
    }

    private func display(_ latex: String) throws -> MTMathListDisplay {
        _ = NSApplication.shared
        let label = MTMathUILabel()
        label.mathList = try parsed(latex)
        label.fontSize = 20
        label.labelMode = .display
        label.layoutSubtreeIfNeeded()
        return try #require(label.displayList, "\(latex)")
    }

    private func nuclei(_ list: MTMathList) -> [String] { list.atoms.map(\.nucleus) }

    private func contains(_ list: MTMathList, _ nucleus: String) -> Bool {
        var found = false
        SwiftMathBridge.forEachList(in: list) { found = found || $0.atoms.contains { $0.nucleus == nucleus } }
        return found
    }

    // The two formulas from the bug report (2026-11-20).
    static let seriesTable = #"""
    \begin{aligned}
    e^x            &= \sum_{n=0}^{\infty} \frac{x^n}{n!},                                          & -\infty &< x < +\infty \\[6pt]
    \frac{1}{1+x}  &= \sum_{n=0}^{\infty} (-1)^n x^n,                                              &      -1 &< x < 1 \\[6pt]
    \frac{1}{1-x}  &= \sum_{n=0}^{\infty} x^n,                                                     &      -1 &< x < 1 \\[6pt]
    \ln(1+x)       &= \sum_{n=1}^{\infty} (-1)^{n-1} \frac{x^n}{n},                                &      -1 &< x \leq 1 \\[6pt]
    \sin x         &= \sum_{n=0}^{\infty} (-1)^n \frac{x^{2n+1}}{(2n+1)!},                         & -\infty &< x < +\infty \\[6pt]
    \cos x         &= \sum_{n=0}^{\infty} (-1)^n \frac{x^{2n}}{(2n)!},                             & -\infty &< x < +\infty \\[6pt]
    (1+x)^\alpha   &= \sum_{n=0}^{\infty} \frac{\alpha(\alpha-1)\cdots(\alpha-n+1)}{n!}x^n,        & \text{收敛域} &\text{见下}
    \end{aligned}
    """#

    static let taylorTable = #"""
    \begin{aligned}
    e^x            &= 1 + x + \frac{1}{2!}x^2 + \cdots + \frac{1}{n!}x^n + o(x^n) \\[6pt]
    \sin x         &= x - \frac{x^3}{3!} + \cdots + (-1)^n \frac{x^{2n+1}}{(2n+1)!} + o(x^{2n+1}) \\[6pt]
    \cos x         &= 1 - \frac{x^2}{2!} + \frac{x^4}{4!} - \cdots + (-1)^n \frac{x^{2n}}{(2n)!} + o(x^{2n}) \\[6pt]
    \frac{1}{1-x}  &= 1 + x + x^2 + \cdots + x^n + o(x^n) \\[6pt]
    \frac{1}{1+x}  &= 1 - x + x^2 - \cdots + (-1)^n x^n + o(x^n) \\[6pt]
    \ln(1+x)       &= x - \frac{x^2}{2} + \frac{x^3}{3} - \cdots + (-1)^{n-1} \frac{x^n}{n} + o(x^n) \\[6pt]
    (1+x)^\alpha   &= 1 + \alpha x + \frac{\alpha(\alpha-1)}{2!}x^2 + \cdots + \frac{\alpha(\alpha-1)\cdots(\alpha-n+1)}{n!}x^n + o(x^n)
    \end{aligned}
    """#

    @Test("SwiftMath alone fails the first and sets [6pt] as text in the second")
    func swiftMathAlone() {
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: Self.seriesTable, error: &error)
        #expect(error != nil)
        error = nil
        let list = MTMathListBuilder.build(fromString: Self.taylorTable, error: &error)
        let table = list?.atoms.compactMap { $0 as? MTMathTable }.first
        #expect(table?.cells[1][0].atoms.first?.nucleus == "[")
    }

    @Test("four-column aligned: right/left pairs, {} before the left cells, 1em between the pairs")
    func fourColumnAligned() throws {
        let t = try table(Self.seriesTable)
        #expect(t.numRows == 7)
        #expect(t.numColumns == 4)
        #expect(t.alignments == [.right, .left, .right, .left])
        #expect(t.interColumnSpacing == 0)
        for row in t.cells {
            #expect(row[1].atoms.first?.type == .ordinary && row[1].atoms.first?.nucleus == "")
            #expect(row[3].atoms.first?.type == .ordinary && row[3].atoms.first?.nucleus == "")
            #expect((row[2].atoms.first as? MTMathSpace)?.space == 18)
        }
        // `& -\infty`: the minus starts its cell, so it is a sign, not a binary operator
        #expect(t.cells[0][2].atoms.dropFirst().first?.type == .unaryOperator)
        #expect(t.cells[0][3].atoms.dropFirst().first?.type == .relation)   // `&< x`
        // CJK inside a cell still comes through
        #expect(contains(t.cells[6][2], "收"))
        #expect(contains(t.cells[6][3], "见"))
        #expect(try display(Self.seriesTable).width > 0)
    }

    @Test("\\\\[6pt] is space below the row, not text")
    func rowSpacing() throws {
        let t = try table(Self.taylorTable)
        #expect(t.numColumns == 2)
        #expect(abs(t.interRowAdditionalSpacing - 3) < 0.0001)   // aligned's own 1 jot + 6pt = 0.6em = 2 jots
        for cell in t.cells.joined() {
            #expect(!contains(cell, "[") && !contains(cell, "]"))
        }
        let plain = Self.taylorTable.replacingOccurrences(of: #"\\[6pt]"#, with: #"\\"#)
        let rowsWithSpace = try display(Self.taylorTable)
        let rowsWithout = try display(plain)
        let extra = (rowsWithSpace.ascent + rowsWithSpace.descent) - (rowsWithout.ascent + rowsWithout.descent)
        #expect(abs(extra - 6 * 0.6 * 20) < 0.5, "\(extra)")   // 6 gaps × 0.6em at 20pt
    }

    @Test("a two-column aligned without options still goes to SwiftMath's parser")
    func twoColumnsUntouched() throws {
        let latex = #"x + \begin{aligned} a &= b \\ c &= d \end{aligned}"#
        var error: NSError?
        let native = try #require(MTMathListBuilder.build(fromString: latex, error: &error))
        SwiftMathBridge.keepTablesIntactInLabel(native)
        #expect(MTMathListBuilder.mathListToString(try parsed(latex)) == MTMathListBuilder.mathListToString(native))
    }

    @Test("two-column aligned built by the bridge matches SwiftMath's own")
    func twoColumnsSameLayout() throws {
        let spaced = try display(#"\begin{aligned} a &= b \\[0pt] c &= d \end{aligned}"#)
        let native = try display(#"\begin{aligned} a &= b \\ c &= d \end{aligned}"#)
        #expect(abs(spaced.width - native.width) < 0.001)
        #expect(abs(spaced.ascent - native.ascent) < 0.001)
        #expect(abs(spaced.descent - native.descent) < 0.001)
    }

    @Test("dimensions")
    func dimensions() {
        #expect(LatexTableSource.em("6pt") == 0.6)
        #expect(LatexTableSource.em(" -3 pt ") == -0.3)
        #expect(LatexTableSource.em("1em") == 1)
        #expect(LatexTableSource.em("0.5ex").map { abs($0 - 0.215277) < 0.0001 } == true)
        #expect(LatexTableSource.em(".5em") == 0.5)
        #expect(LatexTableSource.em(#"2\jot"#) == 0.6)
        #expect(LatexTableSource.em(#"\jot"#) == 0.3)
        #expect(LatexTableSource.em("0,1") == nil)
        #expect(LatexTableSource.em("x") == nil)
        #expect(LatexTableSource.em("pt") == nil)
        #expect(LatexTableSource.em("") == nil)
    }

    @Test("rows and cells split on the table's own separators only")
    func splitting() {
        let s = LatexTableSource(#"a & \{b\} \\[2pt] \text{c & d} & \begin{matrix} 1 & 2 \\ 3 & 4 \end{matrix} \\* e \cr f"#)
        #expect(s.cells.count == 4)
        #expect(s.cells[0] == ["a ", #" \{b\} "#])
        #expect(s.cells[1] == [#" \text{c & d} "#, #" \begin{matrix} 1 & 2 \\ 3 & 4 \end{matrix} "#])
        #expect(s.cells[2] == [" e "])
        #expect(s.cells[3] == [" f"])
        #expect(s.rowGaps == [0.2, 0, 0])
        #expect(s.hasRowOptions)
    }

    @Test("an interval after \\\\ is the next row's content")
    func intervalAfterRowBreak() throws {
        let s = LatexTableSource(#"x &\in \\ [0, 1] &\cup (2, 3)"#)
        #expect(!s.hasRowOptions)
        #expect(s.cells[1].first == " [0, 1] ")
        let t = try table(#"\begin{aligned} x &\in \\ [0, 1] &\cup (2, 3) \end{aligned}"#)
        #expect(t.cells[1][0].atoms.first?.nucleus == "[")
    }

    @Test("uneven gaps are spread over every row break")
    func unevenGaps() throws {
        let t = try table(#"\begin{aligned} a &= 1 \\ b &= 2 \\[9pt] c &= 3 \end{aligned}"#)
        #expect(abs(t.interRowAdditionalSpacing - (1 + 0.45 / 0.3)) < 0.0001)
    }

    @Test("spacing in other environments and at the top level")
    func otherEnvironments() throws {
        let cases = try table(#"f(x) = \begin{cases} 0, & x < 0 \\[3pt] 1, & x \geq 0 \end{cases}"#)
        #expect(cases.environment == "cases")
        #expect(abs(cases.interRowAdditionalSpacing - 1) < 0.0001)   // 0 + 0.3em
        #expect(cases.cells[1][0].atoms.contains { $0.nucleus == "1" })
        #expect(!cases.cells[1][0].atoms.contains { $0.nucleus == "[" })

        let matrix = try table(#"\begin{pmatrix} 1 & 2 \\[1em] 3 & 4 \end{pmatrix}"#)
        #expect(abs(matrix.interRowAdditionalSpacing - 1 / 0.3) < 0.0001)

        let top = try parsed(#"\displaystyle a = b \\[6pt] c = d"#)
        let topTable = try #require(top.atoms.first as? MTMathTable)
        #expect(top.atoms.count == 1)
        #expect(topTable.numRows == 2)
        #expect(abs(topTable.interRowAdditionalSpacing - 3) < 0.0001)   // default table's 1 jot + 2
    }

    @Test("one-column aligned and an odd column count")
    func otherColumnCounts() throws {
        let one = try table(#"\begin{aligned} a + b \\ c \end{aligned}"#)
        #expect(one.alignments == [.right])
        // `&&`: the empty right column still keeps the pairs 1em apart (the space moves to the next column)
        let empty = try table(#"\begin{aligned} &0, && n = 0 \\ &1, && n > 0 \end{aligned}"#)
        #expect(empty.cells.allSatisfy { $0[2].atoms.isEmpty && ($0[3].atoms.first as? MTMathSpace)?.space == 18 })
        let gapped = try display(#"\begin{aligned} &0, && n = 0 \end{aligned}"#).width
        let tight = try display(#"0, n = 0"#).width
        #expect(gapped > tight + 15, "\(gapped) vs \(tight)")   // 18mu instead of the 3mu after `,` = 15mu ≈ 16.7pt at 20pt
        let three = try table(#"\begin{aligned} a &= b & c \end{aligned}"#)
        #expect(three.alignments == [.right, .left, .right])
        #expect(try display(#"\begin{aligned} a + b \\ c \end{aligned}"#).width > 0)
    }

    @Test("nested: wider aligned inside \\left\\{ … \\right. and inside a cases cell, a matrix inside a cell")
    func nested() throws {
        let piecewise = try parsed(#"f(n) = \left\{\begin{aligned} &0, && n = 0 \\ &1, && n > 0 \end{aligned}\right."#)
        let inner = try #require(piecewise.atoms.last as? MTInner)
        let t = try #require(inner.innerList?.atoms.first as? MTMathTable)
        #expect(t.numColumns == 4)

        let inCases = try table(#"\begin{cases} \begin{aligned} a &= b & c &= d \end{aligned} & x > 0 \\ 0 & x \leq 0 \end{cases}"#)
        #expect(inCases.environment == "cases")
        let cell = inCases.cells[0][0]
        #expect(cell.atoms.contains { ($0 as? MTMathTable)?.numColumns == 4 })

        let withMatrix = try table(#"\begin{aligned} A &= \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix} & B &= 0 \end{aligned}"#)
        #expect(withMatrix.numColumns == 4)
        #expect(withMatrix.cells[0][1].atoms.contains { $0 is MTInner })
    }

    @Test("stand-ins avoid Cyrillic used inside the cells")
    func standInsAvoidCellLetters() throws {
        let list = try parsed(#"x + \begin{aligned} А &= Б & В &= Г \end{aligned} + y"#)
        #expect(nuclei(list).first == "x")
        let t = try #require(list.atoms.compactMap { $0 as? MTMathTable }.first)
        #expect(t.cells[0][0].atoms.map(\.nucleus) == ["А"])
        #expect(t.cells[0][1].atoms.map(\.nucleus) == ["", "=", "Б"])
        #expect(list.atoms.last?.nucleus == "y")
    }

    @Test("a script after the environment goes on an empty atom after the table")
    func scriptAfterTable() throws {
        let list = try parsed(#"\begin{aligned} a &= b & c &= d \end{aligned}^2"#)
        #expect(list.atoms.count == 2)
        #expect(list.atoms[0] is MTMathTable)
        #expect(list.atoms[1].nucleus == "" && list.atoms[1].superScript?.atoms.first?.nucleus == "2")
    }

    @Test("the label keeps aligned's {} and the matrix cells' text style")
    func labelKeepsTables() throws {
        _ = NSApplication.shared
        // `=` keeps its thick space on the left: as wide as `a = b` set inline
        let aligned = try display(#"\begin{aligned} a &= b \end{aligned}"#)
        let inline = try display("a = b")
        #expect(abs(aligned.width - inline.width) < 0.001, "\(aligned.width) vs \(inline.width)")
        // matrix cells in text style: a fraction in a cell is the same as `\textstyle` makes it
        let matrix = try display(#"\begin{matrix} \frac{1}{2} \end{matrix}"#)
        let text = try display(#"\textstyle \frac{1}{2}"#)
        #expect(abs(matrix.width - text.width) < 0.001)
        let label = MTMathUILabel()
        let list = try parsed(#"\begin{pmatrix} 1 & 2 \end{pmatrix} + \begin{aligned} a &= b \end{aligned}"#)
        label.mathList = list
        var cellStarts: [MTMathAtomType] = []
        SwiftMathBridge.forEachList(in: list) { l in
            for case let t as MTMathTable in l.atoms { cellStarts += t.cells.joined().compactMap { $0.atoms.first?.type } }
        }
        // forEachList visits the outer list's aligned before the matrix inside `\left( … \right)`
        #expect(cellStarts == [.variable, .ordinary, .style, .style])
    }

    @Test("a cell that does not parse fails the whole formula, as before")
    func badCell() {
        var error: NSError?
        #expect(SwiftMathBridge.parseFormula(#"\begin{aligned} a &= \nosuchcommand & c &= d \end{aligned}"#, error: &error) == nil)
        #expect(error != nil)
        error = nil
        #expect(SwiftMathBridge.parseFormula(#"\begin{aligned} a &= b \\[2pt] c &= d \end{cases}"#, error: &error) == nil)
        #expect(error != nil)
    }
}
