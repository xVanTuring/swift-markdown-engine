//
//  LatexTables.swift
//  MarkdownEngineLatex
//
//  Two gaps in SwiftMath's table environments, filled before its parser sees them:
//
//  - `aligned` (and `split` / `eqalign`) only takes exactly two columns, so the amsmath way of
//    putting a second right/left pair beside the first — `e^x &= \sum … & -\infty &< x < +\infty` —
//    failed to parse and the whole formula showed as source. A single column failed the same way.
//  - `\\[6pt]` (extra space below a row) is not read: `[6pt]` was set as text at the start of
//    the next row.
//
//  Such an environment is cut out of the formula and built here instead: its rows and cells are
//  split on its own `\\` and `&`, each cell is parsed through `parseFormula` again (so nested
//  environments and CJK work inside it), the table comes from SwiftMath's public factory (or is
//  laid out as amsmath's `aligned`), and it goes back into the parsed formula where a stand-in
//  letter held its place. Environments that need neither still go to SwiftMath's parser untouched.
//

import Foundation
import SwiftMath

extension SwiftMathBridge {
    /// Parses a formula as `MTMathListBuilder.build` does, plus the table environments SwiftMath cannot
    /// read itself (see the file header) and CJK characters (`standInsForCJK`). Binary signs are not
    /// settled here: the caller runs `settleBinarySigns` on the whole result.
    static func parseFormula(_ latex: String, error: inout NSError?) -> MTMathList? {
        // Rows written at the top level with `\\[…]`: the formula itself is SwiftMath's default table.
        let top = LatexTableSource(latex)
        if top.hasRowOptions {
            guard let table = makeTable(environment: nil, top, error: &error) else { return nil }
            return MTMathList(atom: table)
        }

        var tables: [String: MTMathAtom] = [:]
        // Stand-ins avoid every Cyrillic letter in the whole formula, cells included: a cell's own
        // letters end up in the result, and `putBack` must not take one of them for a stand-in.
        var pool = (UInt32(0x0410)...UInt32(0x044F)).compactMap(Unicode.Scalar.init)
            .filter { !latex.unicodeScalars.contains($0) }
        pool.reverse()   // so `popLast` hands them out in order
        let rest = cutOutTables(latex, pool: &pool, into: &tables, error: &error)
        guard error == nil else { return nil }

        let (parseable, cjk) = standInsForCJK(rest)
        guard let list = MTMathListBuilder.build(fromString: parseable, error: &error), error == nil else { return nil }
        restoreCJK(in: list, cjk)
        putBack(tables, in: list)
        return list
    }

    /// `latex` with each environment that SwiftMath cannot read replaced by a stand-in letter; the
    /// tables built for them go into `tables` under that letter. Environments left in place are
    /// searched for such environments inside them.
    private static func cutOutTables(
        _ latex: String, pool: inout [Unicode.Scalar], into tables: inout [String: MTMathAtom], error: inout NSError?
    ) -> String {
        guard latex.contains(#"\begin"#) else { return latex }
        let u = Array(latex.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard let env = LatexTableSource.environment(in: u, at: i) else {
                out.append(u[i])
                i += 1
                continue
            }
            let body = String(String.UnicodeScalarView(u[env.body]))
            let rows = LatexTableSource(body)
            let needed = rows.hasRowOptions || (alignedEnvironments.contains(env.name) && rows.columnCount != 2)
            if needed, let standIn = pool.popLast() {
                guard let table = makeTable(environment: env.name, rows, error: &error) else { return latex }
                tables[String(standIn)] = table
                // Spaces keep the letter off a command name before it (`\quad\begin…`): SwiftMath reads
                // Cyrillic letters as part of a control word. Math mode ignores the spaces themselves.
                out.append(" "); out.append(standIn); out.append(" ")
            } else {
                out.append(contentsOf: u[env.begin])
                out.append(contentsOf: cutOutTables(body, pool: &pool, into: &tables, error: &error).unicodeScalars)
                if error != nil { return latex }
                out.append(contentsOf: u[env.end])
            }
            i = env.end.upperBound
        }
        return String(out)
    }

    /// The table for one environment (`nil` = SwiftMath's default table, rows at the top level of a
    /// formula), with the `\\[…]` spacing applied.
    private static func makeTable(environment: String?, _ rows: LatexTableSource, error: inout NSError?) -> MTMathAtom? {
        var cells: [[MTMathList]] = []
        for row in rows.cells {
            var lists: [MTMathList] = []
            for cell in row {
                guard let list = parseFormula(cell, error: &error) else { return nil }
                lists.append(list)
            }
            cells.append(lists)
        }

        let atom: MTMathAtom
        if let environment, alignedEnvironments.contains(environment) {
            guard let table = alignedTable(cells, environment: environment) else { return nil }
            atom = table
        } else {
            var factoryError: NSError?
            guard let table = MTMathAtomFactory.table(withEnvironment: environment, rows: cells, error: &factoryError) else {
                error = factoryError ?? NSError(domain: "MarkdownEngineLatex", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cannot build the \(environment ?? "default") table",
                ])
                return nil
            }
            atom = table
        }
        // Matrices with delimiters and `cases` come back as an inner atom around the table.
        let table = atom as? MTMathTable ?? (atom as? MTInner)?.innerList?.atoms.lazy.compactMap { $0 as? MTMathTable }.first
        table?.interRowAdditionalSpacing += rows.extraRowSpacingInJots
        return atom
    }

    /// `MTMathUILabel.mathList`'s setter runs `MTMathListBuilder.mathListToString`, which edits the list
    /// while writing it out: it deletes the `{}` that `aligned` puts before its second column (so `=`
    /// lost its space on the left) and the text style that matrices put at the start of every cell (so
    /// matrix cells were set in display style). It only does so by the table's environment name, which
    /// nothing else reads — the typesetter does not — so the name is cleared before the label sees it.
    static func keepTablesIntactInLabel(_ list: MTMathList?) {
        forEachList(in: list) { list in
            for case let table as MTMathTable in list.atoms
            where ["aligned", "split", "eqalign", "matrix"].contains(table.environment) {
                table.environment = ""
            }
        }
    }

    /// The environments SwiftMath lays out as amsmath's `aligned` (and only with two columns).
    private static let alignedEnvironments: Set<String> = ["aligned", "split", "eqalign"]

    /// amsmath's `aligned` with any number of columns: right/left pairs, the left one set as `{}cell`
    /// (so `&= b` spaces `=` as a relation), and 1em between one pair and the next (`\minalignsep`).
    /// With two columns this is exactly SwiftMath's own `aligned`.
    private static func alignedTable(_ cells: [[MTMathList]], environment: String) -> MTMathTable? {
        var error: NSError?
        guard let table = MTMathAtomFactory.table(withEnvironment: nil, rows: cells, error: &error) as? MTMathTable,
              error == nil else { return nil }
        table.environment = environment
        table.interRowAdditionalSpacing = 1
        table.interColumnSpacing = 0
        let columns = table.numColumns
        for column in 0..<columns {
            table.set(alignment: column % 2 == 0 ? .right : .left, forColumn: column)
        }
        // The 1em between pairs is glue between the columns in amsmath, so it is there even when a column
        // is empty (`&0, && n = 0`). SwiftMath gives a cell with nothing to draw no width, a lone space
        // included, so each gap goes in front of the cells of the next column that has something in it:
        // inside a right-aligned cell it ends up between the widest cell and the pair before.
        let filled = (0..<columns).map { column in
            table.cells.contains { column < $0.count && !$0[column].atoms.isEmpty }
        }
        var gapsBefore = [Int](repeating: 0, count: columns)
        var pending = 0
        for column in 0..<columns {
            if column > 0, column % 2 == 0 { pending += 1 }
            if pending > 0, filled[column] { gapsBefore[column] = pending; pending = 0 }
        }
        for row in table.cells {
            for (column, cell) in row.enumerated() {
                let empty = cell.atoms.isEmpty
                if column % 2 == 1 { cell.atoms.insert(emptyOrdinary(), at: 0) }
                guard !empty else { continue }
                for _ in 0..<gapsBefore[column] {
                    if let quad = MTMathAtomFactory.atom(forLatexSymbol: "quad") { cell.atoms.insert(quad, at: 0) }
                }
            }
        }
        return table
    }

    /// An ordinary atom with no glyph: the `{}` amsmath puts before a left-aligned cell, and what TeX
    /// attaches scripts to when there is no atom that can take them.
    private static func emptyOrdinary() -> MTMathAtom {
        let atom = MTMathAtomFactory.atom(forCharacter: "|")!   // an ordinary atom; only its glyph goes
        atom.nucleus = ""
        return atom
    }

    /// Puts each table in place of its stand-in letter. Scripts on the stand-in (`\end{aligned}^2`)
    /// move to an empty atom after the table, as SwiftMath's parser does for a script after a table.
    private static func putBack(_ tables: [String: MTMathAtom], in list: MTMathList) {
        guard !tables.isEmpty else { return }
        var spots: [(list: MTMathList, index: Int, table: MTMathAtom)] = []
        forEachList(in: list) { list in
            for (index, atom) in list.atoms.enumerated() where atom.type == .ordinary {
                if let table = tables[atom.nucleus] { spots.append((list, index, table)) }
            }
        }
        // Back to front, so indexes found earlier in the same list stay valid.
        for spot in spots.reversed() {
            let standIn = spot.list.atoms[spot.index]
            spot.list.atoms[spot.index] = spot.table
            if standIn.subScript != nil || standIn.superScript != nil {
                let carrier = emptyOrdinary()
                carrier.subScript = standIn.subScript
                carrier.superScript = standIn.superScript
                spot.list.atoms.insert(carrier, at: spot.index + 1)
            }
        }
    }
}

/// The rows and cells of a table's source, split on its own `\\` (or `\cr`) and `&` — not on those
/// inside braces or inside a nested environment — with the options after each row break.
struct LatexTableSource {
    /// Rows of cell sources, as written (a cell keeps its surrounding spaces).
    private(set) var cells: [[String]] = [[]]
    /// Extra space below each row break, in em of the formula's font: `\\[6pt]` → 0.6, plain `\\` → 0.
    private(set) var rowGaps: [CGFloat] = []
    /// Some row break has `[…]` or `*` after it, which SwiftMath's parser would set as text.
    private(set) var hasRowOptions = false

    var columnCount: Int { cells.map(\.count).max() ?? 0 }

    /// SwiftMath spaces every row of a table alike, so the gaps are spread evenly over the row breaks:
    /// the table is as tall as written. In jots (0.3 em), the unit of `interRowAdditionalSpacing`.
    var extraRowSpacingInJots: CGFloat {
        guard !rowGaps.isEmpty else { return 0 }
        return rowGaps.reduce(0, +) / CGFloat(rowGaps.count) / 0.3
    }

    init(_ source: String) {
        let u = Array(source.unicodeScalars)
        var cell = String.UnicodeScalarView()
        var braces = 0
        func endCell() {
            cells[cells.count - 1].append(String(cell))
            cell = String.UnicodeScalarView()
        }
        var i = 0
        while i < u.count {
            let c = u[i]
            if let env = Self.environment(in: u, at: i) {   // a nested table keeps its own `&` and `\\`
                cell.append(contentsOf: u[env.begin.lowerBound..<env.end.upperBound])
                i = env.end.upperBound
                continue
            }
            if c == "\\", i + 1 < u.count {
                var j = i + 1
                while j < u.count, Self.isLetter(u[j]) { j += 1 }
                let name = String(String.UnicodeScalarView(u[(i + 1)..<j]))
                let isRowBreak = braces == 0 && (u[i + 1] == "\\" || name == "cr")
                if isRowBreak {
                    endCell()
                    cells.append([])
                    i = readRowOptions(u, from: name == "cr" ? j : i + 2)
                    continue
                }
                let end = j > i + 1 ? j : i + 2   // a control word, or `\` and one character (`\{`, `\&`)
                cell.append(contentsOf: u[i..<end])
                i = end
                continue
            }
            if c == "{" { braces += 1 } else if c == "}" { braces = max(0, braces - 1) }
            if c == "&", braces == 0 {
                endCell()
                i += 1
                continue
            }
            cell.append(c)
            i += 1
        }
        endCell()
    }

    /// After a row break: an optional `*` (amsmath: no page break here) and `[dimension]`. Only a
    /// real dimension is taken: `\\ [0, 1]` starts the next row with an interval.
    private mutating func readRowOptions(_ u: [Unicode.Scalar], from start: Int) -> Int {
        var i = start
        if i < u.count, u[i] == "*" {
            hasRowOptions = true
            i += 1
        }
        var p = i
        while p < u.count, u[p] == " " || u[p] == "\n" || u[p] == "\t" { p += 1 }
        if p < u.count, u[p] == "[", let close = u[(p + 1)...].firstIndex(of: "]"),
           let em = Self.em(String(String.UnicodeScalarView(u[(p + 1)..<close]))) {
            rowGaps.append(em)
            hasRowOptions = true
            return close + 1
        }
        rowGaps.append(0)
        return i
    }

    /// A TeX dimension (`6pt`, `-0.5em`, `1.2 ex`, `2\jot`) in em of a 10pt font: formulas are drawn at
    /// many sizes, so the space scales with the formula, as it would with the font size in TeX.
    static func em(_ text: String) -> CGFloat? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var numberEnd = t.startIndex
        if numberEnd < t.endIndex, t[numberEnd] == "-" || t[numberEnd] == "+" { numberEnd = t.index(after: numberEnd) }
        while numberEnd < t.endIndex, t[numberEnd].isASCII, t[numberEnd].isNumber || t[numberEnd] == "." {
            numberEnd = t.index(after: numberEnd)
        }
        let number = String(t[..<numberEnd])
        let unit = t[numberEnd...].trimmingCharacters(in: .whitespaces)
        guard let pointsPerUnit = pointsPerUnit[unit] else { return nil }
        let value: Double
        if number.isEmpty || number == "+" || number == "-" {
            guard unit == #"\jot"# else { return nil }   // `[\jot]`: TeX takes a length register alone
            value = number == "-" ? -1 : 1
        } else {
            guard let v = Double(number) else { return nil }
            value = v
        }
        return CGFloat(value * pointsPerUnit / 10)
    }

    private static let pointsPerUnit: [String: Double] = [
        "pt": 1, "bp": 72.27 / 72, "px": 72.27 / 72, "pc": 12, "in": 72.27, "cm": 72.27 / 2.54,
        "mm": 72.27 / 25.4, "dd": 1238.0 / 1157, "cc": 12 * 1238.0 / 1157, "sp": 1.0 / 65536,
        "em": 10, "ex": 4.30554, "mu": 10.0 / 18, #"\jot"#: 3,
    ]

    /// The environment starting at `i` (`\begin{name}` … the matching `\end{name}`), or `nil` if
    /// none starts there or it is never closed.
    static func environment(
        in u: [Unicode.Scalar], at i: Int
    ) -> (name: String, begin: Range<Int>, body: Range<Int>, end: Range<Int>)? {
        guard let begin = command("begin", in: u, at: i) else { return nil }
        var depth = 1
        var p = begin.range.upperBound
        while p < u.count {
            if u[p] == "\\", p + 1 < u.count, !isLetter(u[p + 1]) { p += 2; continue }   // `\\`, `\{`
            if let inner = command("begin", in: u, at: p) {
                depth += 1
                p = inner.range.upperBound
            } else if let end = command("end", in: u, at: p) {
                depth -= 1
                if depth == 0 {
                    guard end.name == begin.name else { return nil }   // SwiftMath reports the mismatch
                    return (begin.name, begin.range, begin.range.upperBound..<end.range.lowerBound, end.range)
                }
                p = end.range.upperBound
            } else {
                p += 1
            }
        }
        return nil
    }

    /// `\begin{name}` / `\end{name}` at `i` (spaces allowed before the brace, as SwiftMath reads it).
    private static func command(_ word: String, in u: [Unicode.Scalar], at i: Int) -> (name: String, range: Range<Int>)? {
        let w = Array(word.unicodeScalars)
        guard i + w.count < u.count, u[i] == "\\", Array(u[(i + 1)...(i + w.count)]) == w else { return nil }
        var p = i + 1 + w.count
        guard p >= u.count || !isLetter(u[p]) else { return nil }   // `\beginning` is another command
        while p < u.count, u[p] == " " { p += 1 }
        guard p < u.count, u[p] == "{", let close = u[(p + 1)...].firstIndex(of: "}") else { return nil }
        let name = String(String.UnicodeScalarView(u[(p + 1)..<close])).trimmingCharacters(in: .whitespaces)
        return (name, i..<(close + 1))
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool { s.isASCII && s.properties.isAlphabetic }
}
