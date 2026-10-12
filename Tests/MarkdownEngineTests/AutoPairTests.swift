//
//  AutoPairTests.swift
//  MarkdownEngineTests
//
//  Auto-closing pairs: typing a closer before the same closer steps over it,
//  and an opener typed over a selection wraps it (repeatably).
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Auto pairs")
struct AutoPairTests {

    /// Types `character` over `selection` in `text`; returns the text, the
    /// resulting selection, and whether the handler swallowed the keystroke.
    private func type(
        _ character: String, in text: String, selection: NSRange, autoClose: Bool = true
    ) -> (text: String, selection: NSRange, handled: Bool) {
        let textView = NativeTextView(frame: .zero)
        var config = MarkdownEditorConfiguration.default
        config.lists.autoClosePairsEnabled = autoClose
        textView.configuration = config
        textView.string = text
        textView.setSelectedRange(selection)
        let passThrough = MarkdownLists.handleInsertion(
            textView: textView, affectedCharRange: selection,
            replacementString: character, isInsideCodeBlock: false
        )
        return (textView.string, textView.selectedRange(), !passThrough)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: Stepping over a closer

    @Test("a closer before the same closer is stepped over", arguments: [
        ("(", ")"), ("[", "]"), ("{", "}"),
    ])
    func stepsOver(open: String, close: String) {
        let r = type(close, in: "a\(open)\(close)", selection: caret(2))
        #expect(r.text == "a\(open)\(close)")
        #expect(r.selection == caret(3))
        #expect(r.handled)
    }

    @Test("typing the opener then the closer leaves one pair")
    func openThenClose() {
        let opened = type("(", in: "", selection: caret(0))
        #expect(opened.text == "()")
        #expect(opened.selection == caret(1))
        let closed = type(")", in: opened.text, selection: opened.selection)
        #expect(closed.text == "()")
        #expect(closed.selection == caret(2))
    }

    @Test("a closer elsewhere is typed normally")
    func closerElsewhere() {
        let r = type(")", in: "(a", selection: caret(2))
        #expect(r.text == "(a")
        #expect(!r.handled)
    }

    @Test("a different closer is not stepped over")
    func differentCloser() {
        #expect(!type("]", in: "(x)", selection: caret(2)).handled)
    }

    @Test("`[[ ]]` steps over both closers")
    func wikiLink() {
        var r = type("]", in: "[[x]]", selection: caret(3))
        #expect(r.selection == caret(4))
        r = type("]", in: r.text, selection: r.selection)
        #expect(r.selection == caret(5))
        #expect(r.text == "[[x]]")
    }

    @Test("no stepping over when auto-closing is off")
    func stepOverOff() {
        #expect(!type(")", in: "()", selection: caret(1), autoClose: false).handled)
    }

    @Test("the task checkbox still completes instead of stepping over")
    func checkboxWins() {
        let r = type("]", in: "- []", selection: caret(3))
        #expect(r.text == "- [ ] ")
    }

    // MARK: Wrapping a selection

    @Test("an opener over a selection wraps it and keeps it selected", arguments: [
        ("(", ")"), ("[", "]"), ("{", "}"), ("=", "="),
        ("*", "*"), ("_", "_"), ("~", "~"), ("`", "`"), ("$", "$"),
    ])
    func wraps(open: String, close: String) {
        let r = type(open, in: "a word b", selection: NSRange(location: 2, length: 4))
        #expect(r.text == "a \(open)word\(close) b")
        #expect(r.selection == NSRange(location: 3, length: 4))
        #expect(r.handled)
    }

    @Test("wrapping repeats: == makes a highlight, (( nests")
    func wrapsRepeatedly() {
        var r = type("=", in: "a word b", selection: NSRange(location: 2, length: 4))
        r = type("=", in: r.text, selection: r.selection)
        #expect(r.text == "a ==word== b")
        #expect(r.selection == NSRange(location: 4, length: 4))
        var p = type("(", in: "word", selection: NSRange(location: 0, length: 4))
        p = type("(", in: p.text, selection: p.selection)
        p = type("(", in: p.text, selection: p.selection)
        #expect(p.text == "(((word)))")
        #expect(p.selection == NSRange(location: 3, length: 4))
    }

    @Test("repeating `*` makes bold, `~` strikethrough, and a backtick a code span")
    func markerRepeats() {
        var r = type("*", in: "word", selection: NSRange(location: 0, length: 4))
        r = type("*", in: r.text, selection: r.selection)
        #expect(r.text == "**word**")
        var t = type("~", in: "word", selection: NSRange(location: 0, length: 4))
        t = type("~", in: t.text, selection: t.selection)
        #expect(t.text == "~~word~~")
    }

    @Test("markers are not wrapped inside a code block")
    func noMarkersInCode() {
        let textView = NativeTextView(frame: .zero)
        textView.configuration = .default
        textView.string = "word"
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        let passThrough = MarkdownLists.handleInsertion(
            textView: textView, affectedCharRange: NSRange(location: 0, length: 4),
            replacementString: "*", isInsideCodeBlock: true
        )
        #expect(passThrough)
        #expect(textView.string == "word")
    }

    @Test("markers without a selection are typed normally", arguments: ["*", "_", "~", "`", "$", "="])
    func markersAlone(marker: String) {
        #expect(!type(marker, in: "a b", selection: caret(1)).handled)
    }

    @Test("`=` without a selection is typed normally")
    func equalsAlone() {
        #expect(!type("=", in: "a b", selection: caret(1)).handled)
    }

    @Test("no wrapping when auto-closing is off")
    func wrapOff() {
        let r = type("(", in: "word", selection: NSRange(location: 0, length: 4), autoClose: false)
        #expect(!r.handled)
    }

    @Test("a selection is wrapped across lines")
    func wrapsAcrossLines() {
        let r = type("=", in: "one\ntwo", selection: NSRange(location: 0, length: 7))
        #expect(r.text == "=one\ntwo=")
        #expect(r.selection == NSRange(location: 1, length: 7))
    }
}
