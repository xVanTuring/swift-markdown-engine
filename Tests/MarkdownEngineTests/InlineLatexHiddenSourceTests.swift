//
//  InlineLatexHiddenSourceTests.swift
//  MarkdownEngineTests
//
//  A rendered `$…$` hides its source by SIZE, not only by a clear colour:
//  NSTextView.selectedTextAttributes carries a `selectedTextColor` that
//  repaints every selected glyph opaque, so a colour-hidden closing `$` came
//  back under the selection highlight, drawn over the next character. Shrinking
//  it must not move the formula either — a line holding nothing but the
//  formula keeps the baseline of a line with text in it.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Inline LaTeX hidden source")
struct InlineLatexHiddenSourceTests {

    private struct StubRenderer: LatexRenderer {
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            let size = CGSize(width: 20, height: 10)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: -2)
        }
    }

    private static let fontSize: CGFloat = 16

    /// Styled the way the editor does it: the styler's ranges painted over the
    /// base attributes. The caret sits in a trailing paragraph, away from every formula.
    private func makeTextView(_ text: String) -> (NativeTextView, MarkdownEditorConfiguration) {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(latex: StubRenderer())
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = config
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: NSFont.systemFont(ofSize: Self.fontSize).fontName,
            fontSize: Self.fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: config
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(string: text))
        let length = (text as NSString).length
        let ranges = MarkdownStyler.styleAttributes(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            layoutBridge: tv.layoutBridge,
            caretLocation: length,
            activeTokenIndices: [],
            configuration: config
        )
        TextStylingService.applyStyledRanges(
            ranges,
            paragraphs: [NSRange(location: 0, length: length)],
            baseAttributes: [.font: font, .foregroundColor: config.theme.bodyText, .paragraphStyle: style],
            to: tv.textStorage
        )
        return (tv, config)
    }

    /// Baseline of the character at `index` measured from the top of its line box
    /// (`MarkdownTextLayoutFragment.drawPosition` adds the line's origin, which also
    /// carries paragraph spacing, to this), and the height of that line.
    private func line(at index: Int, in tv: NativeTextView) throws -> (baseline: CGFloat, height: CGFloat) {
        let tlm = try #require(tv.textLayoutManager)
        let tcm = try #require(tlm.textContentManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var result: (baseline: CGFloat, height: CGFloat)?
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            let local = index - start
            for line in fragment.textLineFragments {
                let r = line.characterRange
                if local >= r.location, local < NSMaxRange(r) {
                    result = (line.locationForCharacter(at: local).y, line.typographicBounds.height)
                    return false
                }
            }
            return true
        }
        return try #require(result)
    }

    @Test("every source character of a rendered formula is shrunk, closing $ included")
    func sourceHiddenBySize() throws {
        for (text, formula) in [
            ("a $x+1$ b\n\nend", NSRange(location: 2, length: 5)),
            ("**a $x+1$ b**\n\nend", NSRange(location: 4, length: 5)),
            ("# a $x+1$ b\n\nend", NSRange(location: 4, length: 5)),
        ] {
            let (tv, config) = makeTextView(text)
            let storage = try #require(tv.textStorage)
            for i in formula.location..<NSMaxRange(formula) {
                let font = try #require(storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)
                #expect(font.pointSize <= config.markers.hiddenMarkerFontSize,
                        "\(text.debugDescription) index \(i) is \(font.pointSize)pt")
            }
        }
    }

    @Test("a line holding only a formula keeps the baseline and height of a line with text")
    func formulaOnlyLineKeepsBaseline() throws {
        // Index of the first content char (the one carrying the image) in each pair.
        for (text, alone, withText) in [
            ("$x+1$\n\nab $x+1$\n\nend", 1, 11),
            ("# $x+1$\n\n# ab $x+1$\n\nend", 3, 15),
        ] {
            let (tv, _) = makeTextView(text)
            let a = try line(at: alone, in: tv)
            let b = try line(at: withText, in: tv)
            #expect(abs(a.baseline - b.baseline) < 0.5, "\(text.debugDescription): baseline \(a.baseline) vs \(b.baseline)")
            #expect(abs(a.height - b.height) < 0.5, "\(text.debugDescription): line height \(a.height) vs \(b.height)")
        }
    }
}
