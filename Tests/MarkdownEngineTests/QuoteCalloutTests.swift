//
//  QuoteCalloutTests.swift
//  MarkdownEngineTests
//
//  (fork: xVanTuring) Display math inside block quotes and Obsidian callouts.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Quote math and callouts")
struct QuoteCalloutTests {

    private struct Recorder: LatexRenderer {
        final class Box: @unchecked Sendable { var calls: [(String, LatexRenderMode)] = [] }
        let box = Box()
        func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
        func render(latex: String, mode: LatexRenderMode, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
            box.calls.append((latex, mode))
            let size = CGSize(width: 40, height: 20)
            return LatexRenderResult(image: NSImage(size: size), size: size, baselineOffset: 4)
        }
    }

    private static func configuration(_ latex: any LatexRenderer) -> MarkdownEditorConfiguration {
        var c = MarkdownEditorConfiguration.default
        c.services = MarkdownEditorServices(latex: latex)
        return c
    }

    private static func style(_ text: String, caret: Int = -1, latex: any LatexRenderer = Recorder()) -> [StyledRange] {
        _ = NSApplication.shared
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let active = caret < 0 ? Set<Int>() : MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: text as NSString)
        return MarkdownStyler.styleAttributes(text: text, fontName: "Helvetica", fontSize: 14,
                                              caretLocation: caret, activeTokenIndices: active,
                                              configuration: configuration(latex))
    }

    // MARK: - Quote math tokens

    @Test("Single-line $$ in a quote is a block formula; inline parsing skips it")
    func singleLineToken() {
        let text = "> 由 $x$ 得\n> $$\\frac{a}{b} = \\{c\\}$$\n> 故\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let block = tokens.filter { $0.kind == .blockLatex }
        #expect(block.count == 1)
        let ns = text as NSString
        #expect(block.first.map { ns.substring(with: $0.contentRange) } == "\\frac{a}{b} = \\{c\\}")
        // `$x$` outside stays inline math; nothing inline (no `\{` escape) inside the formula.
        #expect(tokens.filter { $0.kind == .inlineLatex }.count == 1)
        let formula = block[0].range
        #expect(!tokens.contains { $0.kind != .blockLatex && $0.kind != .blockquote
            && NSIntersectionRange($0.range, formula).length > 0 })
    }

    @Test("Multi-line $$ in a quote: continuation markers are stripped from the formula")
    func multiLineToken() {
        let text = "> $$\n> \\sum_{k=1}^{n} k\n>  = n\n> $$\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let block = tokens.filter { $0.kind == .blockLatex }
        #expect(block.count == 1)
        let raw = (text as NSString).substring(with: block[0].contentRange)
        #expect(QuoteMath.latexBody(raw) == "\n\\sum_{k=1}^{n} k\n = n\n")
        #expect(block[0].standaloneParagraphRange(in: text as NSString, allowingQuotePrefix: true) != nil)
        #expect(block[0].standaloneParagraphRange(in: text as NSString) == nil)
    }

    @Test("Unclosed or trailing-text $$ in a quote")
    func edgeTokens() {
        #expect(MarkdownTokenizer.parseTokensViaAST(in: "> $$x\n> y\n").filter { $0.kind == .blockLatex }.isEmpty)
        let trailing = "> $$x$$，故\n"
        let t = MarkdownTokenizer.parseTokensViaAST(in: trailing).filter { $0.kind == .blockLatex }
        #expect(t.count == 1)
        #expect(t.first?.standaloneParagraphRange(in: trailing as NSString, allowingQuotePrefix: true) == nil)
        // Not at the start of the quote's content: stays as it was.
        #expect(MarkdownTokenizer.parseTokensViaAST(in: "> a $$x$$\n").filter { $0.kind == .blockLatex }.isEmpty)
    }

    @Test("Quote formula renders in display mode with the quote markers removed")
    func quoteFormulaRenders() {
        let recorder = Recorder()
        let text = "> 得\n> $$\n> a+b\n> $$\n> 故\n"
        let attrs = Self.style(text, latex: recorder)
        #expect(recorder.box.calls.contains { $0.0 == "a+b" && $0.1 == .display })
        #expect(attrs.contains { $0.attributes[.latexImage] != nil && $0.attributes[.latexIsBlock] as? Bool == true })
    }

    @Test("Caret on the `> ` before a quote formula reveals its source")
    func caretOnQuoteMarkerActivates() {
        let text = "> $$a$$\n"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
        let idx = tokens.firstIndex { $0.kind == .blockLatex }!
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: 0, length: 0), tokens: tokens, in: text as NSString)
        #expect(active.contains(idx))
    }

    // MARK: - Callout headers

    @Test("Header grammar")
    func headers() {
        func parse(_ s: String) -> CalloutHeader? {
            let ns = s as NSString
            return CalloutHeader.parse(ns, from: 0, to: ns.length)
        }
        let a = parse("[!example]")
        #expect(a?.type.name == "example")
        #expect(a?.titleRange == nil)
        #expect(a?.defaultTitle == "Example")
        let b = parse("[!WARNING]- 小心 ")
        #expect(b?.type.name == "warning")
        #expect(b.flatMap { $0.titleRange }.map { ("[!WARNING]- 小心 " as NSString).substring(with: $0) } == "小心")
        #expect(b?.markerRange == NSRange(location: 0, length: 12))
        #expect(parse("[!faq]+")?.type.name == "question")
        #expect(parse("[!faq]")?.defaultTitle == "Faq")
        #expect(parse("[!whatever] x")?.type.name == "note")   // unknown → note's look
        #expect(parse("[!note]x") == nil)
        #expect(parse("[note]") == nil)
        #expect(parse("[!]") == nil)
    }

    @Test("Layout: nesting, runs-on and the callout's end")
    func layout() {
        let text = "> [!note] T\n> body\n> > [!tip]\n> > inner\n> back\n"
        let ns = text as NSString
        let q = CalloutScan.layout(of: NSRange(location: 0, length: ns.length), in: ns)
        #expect(q.count == 5)
        #expect(q[0].header?.type.name == "note")
        #expect(q[0].levels.map { $0?.name } == ["note"])
        #expect(q[2].header?.type.name == "tip")
        #expect(q[3].levels.map { $0?.name } == ["note", "tip"])
        #expect(q[3].continues == [true, false])
        #expect(q[3].calloutEnds)
        #expect(q[4].innermostCallout?.name == "note")
        #expect(q[4].isLastInBlock && q[4].calloutEnds)
        // A `[!x]` that does not open its level is just text.
        let mid = "> text\n> [!note]\n" as NSString
        #expect(CalloutScan.layout(of: NSRange(location: 0, length: mid.length), in: mid).allSatisfy { $0.header == nil })
    }

    // MARK: - Styling

    @Test("Callout body keeps the body colour; plain quote text is muted")
    func calloutColours() {
        let theme = MarkdownEditorConfiguration.default.theme
        let text = "> [!example]\n> 设 x\n\n> 引用\n"
        let ns = text as NSString
        let attrs = Self.style(text)
        func colour(at s: String) -> NSColor? {
            let r = ns.range(of: s)
            return attrs.last { NSLocationInRange(r.location, $0.range) && $0.attributes[.foregroundColor] != nil }?
                .attributes[.foregroundColor] as? NSColor
        }
        #expect(colour(at: "设") == theme.bodyText)
        #expect(colour(at: "引用") == theme.mutedText)
        let deco = attrs.compactMap { $0.attributes[.blockquoteDecoration] as? QuoteLineDecoration }
        #expect(deco.contains { $0.hasCallout })
        #expect(deco.contains { !$0.hasCallout })
    }

    @Test("Header marker collapses to an icon away from the caret, shows muted at it")
    func headerIcon() {
        let text = "> [!tip] 标题\n> x\n"
        let away = Self.style(text, caret: (text as NSString).length)
        #expect(away.contains { $0.range.location == 2 && $0.attributes[.latexImage] is NSImage })
        let at = Self.style(text, caret: 3)
        #expect(!at.contains { $0.range.location == 2 && $0.attributes[.latexImage] is NSImage })
        // Never the incomplete-link colour on `[!tip]`.
        let config = MarkdownEditorConfiguration.default
        let faded = config.theme.incompleteLink.withAlphaComponent(config.link.incompleteLinkAlpha)
        #expect(!at.contains { NSIntersectionRange($0.range, NSRange(location: 2, length: 6)).length > 0
            && ($0.attributes[.foregroundColor] as? NSColor) == faded })
    }

    @Test("Callouts can be turned off")
    func calloutsOff() {
        var c = Self.configuration(Recorder())
        c.blockquote.rendersCallouts = false
        _ = NSApplication.shared
        let text = "> [!tip]\n> x\n"
        let attrs = MarkdownStyler.styleAttributes(text: text, fontName: "Helvetica", fontSize: 14,
                                                   caretLocation: -1, activeTokenIndices: [], configuration: c)
        #expect(!attrs.contains { ($0.attributes[.blockquoteDecoration] as? QuoteLineDecoration)?.hasCallout == true })
    }
}
