//
//  SwiftMathBinarySpacingTests.swift
//  MarkdownEngineLatexTests
//
//  SwiftMath turns a binary `+`/`-` into an ordinary sign when the atom before it
//  is a relation, an opening bracket, punctuation or another operator (TeX rules
//  5–6) — but it looks only at the atom right before it, and a spacing command
//  (`\,` `\;` `\quad`) sits in between. The typesetter then meets an invalid
//  pair such as relation + binary and trips an `assert` (a crash in Debug
//  builds; release builds silently drop the spacing).
//
//  Typesets directly instead of through `SwiftMathBridge.render`: the bridge's
//  disk cache would hand back an earlier run's image and never typeset again,
//  so a regression would pass.
//

import AppKit
import Testing
import SwiftMath
import MarkdownEngine
@testable import MarkdownEngineLatex

@MainActor
@Suite("SwiftMath binary signs beside spacing")
struct SwiftMathBinarySpacingTests {
    @Test("a sign next to a spacing command typesets", arguments: [
        #"x = \; -1"#,
        #"x =\, -1"#,
        #"(\,-1)"#,
        #"x = \quad -1"#,
        #"f(x) = x^2, \quad -1 \le x \le 1"#,
        #"x - \quad = 0"#,
        #"a + \, + b"#,
        #"\frac{a = \, -1}{2}"#,
        #"x^{= \, -1}"#,
        #"\sqrt{(\,-1)}"#,
        #"\left( a = \; -b \right)"#,
        #"\begin{aligned} y &= \; -x \\ z &= 1 \end{aligned}"#,
        #"\displaystyle = \quad -x"#,
    ])
    func typesets(_ latex: String) throws {
        _ = NSApplication.shared
        var error: NSError?
        let list = try #require(MTMathListBuilder.build(fromString: latex, error: &error))
        SwiftMathBridge.settleBinarySigns(in: list)
        let label = MTMathUILabel()
        label.mathList = list
        label.layoutSubtreeIfNeeded()   // typesets; a sign left binary trips SwiftMath's assert here
        #expect(label.displayList != nil, "\(latex)")
    }

    @Test("only signs TeX would make unary change")
    func onlyInvalidSignsChange() throws {
        func types(_ latex: String) throws -> [MTMathAtomType] {
            var error: NSError?
            let list = try #require(MTMathListBuilder.build(fromString: latex, error: &error))
            SwiftMathBridge.settleBinarySigns(in: list)
            return list.atoms.map(\.type).filter { $0 != .space }
        }
        #expect(try types("a - b").contains(.binaryOperator))            // between operands: stays binary
        #expect(try types(#"a \, - \, b"#).contains(.binaryOperator))    // spacing around it changes nothing
        #expect(try !types(#"a = \, - b"#).contains(.binaryOperator))    // after a relation: unary
    }
}
