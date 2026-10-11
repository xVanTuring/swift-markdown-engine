//
//  TaskCheckboxAutoSpaceTests.swift
//  MarkdownEngineTests
//
//  Typing `]` right after `- [` completes the checkbox as `- [ ] ` with the
//  caret after the trailing space.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Task checkbox auto-space")
struct TaskCheckboxAutoSpaceTests {

    /// Types `]` at `caret` in `text`; returns the resulting text, caret, and
    /// whether the handler swallowed the keystroke.
    private func typeBracket(
        in text: String,
        caret: Int,
        enabled: Bool = true
    ) -> (text: String, caret: Int, handled: Bool) {
        let textView = NativeTextView(frame: .zero)
        var config = MarkdownEditorConfiguration.default
        config.lists.autoSpaceTaskCheckbox = enabled
        textView.configuration = config
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        let passThrough = MarkdownLists.handleInsertion(
            textView: textView,
            affectedCharRange: NSRange(location: caret, length: 0),
            replacementString: "]",
            isInsideCodeBlock: false
        )
        return (textView.string, textView.selectedRange().location, !passThrough)
    }

    @Test("`- [` + `]` becomes `- [ ] ` with caret after the space")
    func completesCheckbox() {
        let r = typeBracket(in: "- [", caret: 3)
        #expect(r.text == "- [ ] ")
        #expect(r.caret == 6)
        #expect(r.handled)
    }

    @Test("auto-closed `]` is consumed, not duplicated")
    func consumesAutoClosedBracket() {
        let r = typeBracket(in: "- []", caret: 3)
        #expect(r.text == "- [ ] ")
        #expect(r.caret == 6)
    }

    @Test("an existing space after the bracket is reused")
    func reusesFollowingSpace() {
        let r = typeBracket(in: "- [] foo", caret: 3)
        #expect(r.text == "- [ ] foo")
        #expect(r.caret == 6)
    }

    @Test("indented and ordered items work")
    func indentedAndOrdered() {
        #expect(typeBracket(in: "\t* [", caret: 4).text == "\t* [ ] ")
        #expect(typeBracket(in: "1. [", caret: 4).text == "1. [ ] ")
    }

    @Test("works on a later line")
    func laterLine() {
        let r = typeBracket(in: "intro\n- [", caret: 9)
        #expect(r.text == "intro\n- [ ] ")
        #expect(r.caret == 12)
    }

    @Test("plain text brackets are left alone")
    func ignoresNonListLines() {
        let r = typeBracket(in: "see [", caret: 5)
        #expect(r.text == "see [")
        #expect(!r.handled)
    }

    @Test("disabled by configuration")
    func disabled() {
        let r = typeBracket(in: "- [", caret: 3, enabled: false)
        #expect(r.text == "- [")
        #expect(!r.handled)
    }
}
