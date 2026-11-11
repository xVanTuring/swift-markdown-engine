//
//  SwiftMathCJKTests.swift
//  MarkdownEngineLatexTests
//
//  SwiftMath's parser drops every character outside ASCII, so `[X]_补` set as
//  `[X]` and `\text{且}` as nothing. The bridge parses each CJK character as a
//  Cyrillic stand-in and puts it back into the atom afterwards.
//
//  Typesets directly instead of through `SwiftMathBridge.render`: the bridge's
//  disk cache would hand back an earlier run's image and never typeset again.
//

import AppKit
import Testing
import SwiftMath
import MarkdownEngine
@testable import MarkdownEngineLatex

@MainActor
@Suite("SwiftMath CJK characters")
struct SwiftMathCJKTests {
    private func parsed(_ latex: String) throws -> MTMathList {
        let (parseable, originals) = SwiftMathBridge.standInsForCJK(latex)
        var error: NSError?
        let list = try #require(MTMathListBuilder.build(fromString: parseable, error: &error), "\(latex)")
        #expect(error == nil, "\(latex)")
        SwiftMathBridge.restoreCJK(in: list, originals)
        return list
    }

    private func width(_ latex: String) throws -> CGFloat {
        _ = NSApplication.shared
        let label = MTMathUILabel()
        label.mathList = try parsed(latex)
        label.fontSize = 18
        label.layoutSubtreeIfNeeded()
        return try #require(label.displayList, "\(latex)").width
    }

    @Test("a formula without CJK goes to the parser unchanged")
    func noCJKUnchanged() {
        let latex = #"\frac{a}{b} + Ж"#
        let (parseable, originals) = SwiftMathBridge.standInsForCJK(latex)
        #expect(parseable == latex)
        #expect(originals.isEmpty)
    }

    @Test("CJK comes back in the atoms, a script takes one character as in TeX")
    func restoredInAtoms() throws {
        let sub = try #require(try parsed("[X]_补").atoms.last?.subScript)
        #expect(sub.atoms.map(\.nucleus) == ["补"])

        let loose = try parsed("x_补码")
        #expect(loose.atoms.first?.subScript?.atoms.map(\.nucleus) == ["补"])
        #expect(loose.atoms.dropFirst().map(\.nucleus) == ["码"])

        let grouped = try parsed("x_{补码}")
        #expect(grouped.atoms.first?.subScript?.atoms.map(\.nucleus) == ["补", "码"])

        let frac = try #require(try parsed(#"\frac{分子}{分母}"#).atoms.first as? MTFraction)
        #expect(frac.numerator?.atoms.map(\.nucleus) == ["分", "子"])
        #expect(frac.denominator?.atoms.map(\.nucleus) == ["分", "母"])
    }

    @Test("stand-ins avoid Cyrillic the formula already uses")
    func standInsAvoidUsedCyrillic() throws {
        let latex = "А+Б+补"   // А and Б are the first two stand-ins
        let (parseable, originals) = SwiftMathBridge.standInsForCJK(latex)
        #expect(parseable == "А+Б+В")
        #expect(originals == ["В": "补"])
        #expect(try parsed(latex).atoms.map(\.nucleus) == ["А", "+", "Б", "+", "补"])
    }

    @Test("CJK right after a command name does not run into it")
    func afterControlWord() throws {
        #expect(SwiftMathBridge.standInsForCJK(#"x=1\quad时"#).latex.hasSuffix(#"\quad А"#))
        #expect(SwiftMathBridge.standInsForCJK(#"a\\时"#).latex == #"a\\А"#)   // `\\` is a whole command
        #expect(SwiftMathBridge.standInsForCJK(#"a\,时"#).latex == #"a\,А"#)
        #expect(try parsed(#"x=1\quad时"#).atoms.last?.nucleus == "时")
    }

    @Test("CJK takes up room when typeset", arguments: [
        ("[X]_补", "[X]"),
        (#"x>0 \text{且} y>0"#, #"x>0 \text{} y>0"#),
        (#"\frac{分子}{2}"#, #"\frac{}{2}"#),
        (#"\sqrt{补}"#, #"\sqrt{}"#),
    ])
    func typesetsWithRoom(_ latex: String, without: String) throws {
        #expect(try width(latex) > width(without) + 5, "\(latex)")
    }
}
