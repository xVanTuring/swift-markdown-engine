//
//  InlineParserTests.swift
//  MarkdownEngineTests
//
//  Phase 2 — test-first specification of the inline parser. Ranges are
//  relative to the parsed string.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("Phase 2 — inline parser")
struct InlineParserTests {

    private func r(_ location: Int, _ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }

    @Test("empty string yields no nodes")
    func empty() {
        #expect(InlineParser.parse("") == [])
    }

    @Test("plain text is a single text node")
    func plainText() {
        #expect(InlineParser.parse("hello") == [.text(r(0, 5))])
    }

    @Test("a code span splits the surrounding text")
    func codeSpan() {
        #expect(InlineParser.parse("a `code` b") == [
            .text(r(0, 2)),
            .code(range: r(2, 6), content: r(3, 4)),
            .text(r(8, 2)),
        ])
    }

    @Test("an unclosed backtick run stays literal text")
    func unclosedBacktick() {
        #expect(InlineParser.parse("a `b") == [.text(r(0, 4))])
    }

    // MARK: - Emphasis (asterisks)

    @Test("single asterisks → italic")
    func italic() {
        #expect(InlineParser.parse("*x*") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("double asterisks → bold")
    func bold() {
        #expect(InlineParser.parse("**x**") == [
            .emphasis(.bold, range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple asterisks → bold+italic")
    func boldItalic() {
        #expect(InlineParser.parse("***x***") == [
            .emphasis(.boldItalic, range: r(0, 7), markers: [r(0, 3), r(4, 3)], children: [.text(r(3, 1))]),
        ])
    }

    @Test("nested emphasis builds a tree")
    func nestedEmphasis() {
        #expect(InlineParser.parse("**a *b* c**") == [
            .emphasis(.bold, range: r(0, 11), markers: [r(0, 2), r(9, 2)], children: [
                .text(r(2, 2)),
                .emphasis(.italic, range: r(4, 3), markers: [r(4, 1), r(6, 1)], children: [.text(r(5, 1))]),
                .text(r(7, 2)),
            ]),
        ])
    }

    @Test("intraword asterisks still emphasize")
    func intrawordAsterisk() {
        #expect(InlineParser.parse("a*b*c") == [
            .text(r(0, 1)),
            .emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))]),
            .text(r(4, 1)),
        ])
    }

    // MARK: - Emphasis (underscores)

    @Test("single underscores → italic")
    func underscoreItalic() {
        #expect(InlineParser.parse("_x_") == [
            .emphasis(.italic, range: r(0, 3), markers: [r(0, 1), r(2, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("intraword underscores stay literal (GFM)")
    func intrawordUnderscore() {
        #expect(InlineParser.parse("a_b_c") == [.text(r(0, 5))])
    }

    // MARK: - Emphasis × code-span precedence

    @Test("emphasis wraps a code span")
    func emphasisWrapsCode() {
        #expect(InlineParser.parse("*a `c` b*") == [
            .emphasis(.italic, range: r(0, 9), markers: [r(0, 1), r(8, 1)], children: [
                .text(r(1, 2)),
                .code(range: r(3, 3), content: r(4, 1)),
                .text(r(6, 2)),
            ]),
        ])
    }

    @Test("delimiters inside a code span are ignored")
    func delimitersInsideCodeIgnored() {
        #expect(InlineParser.parse("`*x*`") == [.code(range: r(0, 5), content: r(1, 3))])
    }

    // MARK: - Wiki-links & image embeds

    @Test("plain wiki-link")
    func wikiLink() {
        #expect(InlineParser.parse("[[Name]]") == [
            .wikiLink(range: r(0, 8), name: r(2, 4), id: nil, markers: [r(0, 2), r(6, 2)]),
        ])
    }

    @Test("wiki-link with id")
    func wikiLinkWithId() {
        #expect(InlineParser.parse("[[Name|abc]]") == [
            .wikiLink(range: r(0, 12), name: r(2, 4), id: r(7, 3), markers: [r(0, 2), r(10, 2)]),
        ])
    }

    @Test("image embed")
    func imageEmbed() {
        #expect(InlineParser.parse("![[Pic]]") == [
            .imageEmbed(range: r(0, 8), target: r(3, 3), markers: [r(0, 3), r(6, 2)]),
        ])
    }

    // MARK: - Links & images

    @Test("markdown link, text recursively parsed")
    func markdownLink() {
        #expect(InlineParser.parse("[text](url)") == [
            .link(range: r(0, 11), textRange: r(1, 4), url: r(7, 3),
                  markers: [r(0, 1), r(5, 1), r(6, 1), r(10, 1)], children: [.text(r(1, 4))]),
        ])
    }

    @Test("markdown link permits inline code inside its label")
    func linkContainsInlineCode() {
        #expect(InlineParser.parse("[`App`](/tmp/App.swift:56)") == [
            .link(
                range: r(0, 26),
                textRange: r(1, 5),
                url: r(8, 17),
                markers: [r(0, 1), r(6, 1), r(7, 1), r(25, 1)],
                children: [.code(range: r(1, 5), content: r(2, 3))]
            ),
        ])
    }

    @Test("markdown link permits multiple inline code spans in its label")
    func linkContainsMultipleInlineCodeSpans() {
        #expect(InlineParser.parse("[`a` and `b`](u)") == [
            .link(
                range: r(0, 16),
                textRange: r(1, 11),
                url: r(14, 1),
                markers: [r(0, 1), r(12, 1), r(13, 1), r(15, 1)],
                children: [
                    .code(range: r(1, 3), content: r(2, 1)),
                    .text(r(4, 5)),
                    .code(range: r(9, 3), content: r(10, 1)),
                ]
            ),
        ])
    }

    @Test("claimed span crossing a link-label boundary rejects the link")
    func codeCrossingLinkLabelBoundaryRejectsLink() {
        #expect(InlineParser.parse("[a `b](u)`") == [
            .text(r(0, 3)),
            .code(range: r(3, 7), content: r(4, 5)),
        ])
    }

    @Test("markdown link permits escaped punctuation inside its label")
    func linkContainsEscapedPunctuation() {
        #expect(InlineParser.parse(#"[\*](u)"#) == [
            .link(
                range: r(0, 7),
                textRange: r(1, 2),
                url: r(5, 1),
                markers: [r(0, 1), r(3, 1), r(4, 1), r(6, 1)],
                children: [.escape(range: r(1, 2), character: r(2, 1), marker: r(1, 1))]
            ),
        ])
    }

    @Test("markdown-looking text inside code remains inert")
    func codeContainingLinkStaysOpaque() {
        #expect(InlineParser.parse("`[a](b)`") == [
            .code(range: r(0, 8), content: r(1, 6)),
        ])
    }

    @Test("link URL keeps balanced parentheses (bug 4)")
    func linkWithBalancedParens() {
        #expect(InlineParser.parse("[a](b(c))") == [
            .link(range: r(0, 9), textRange: r(1, 1), url: r(4, 4),
                  markers: [r(0, 1), r(2, 1), r(3, 1), r(8, 1)], children: [.text(r(1, 1))]),
        ])
    }

    @Test("image")
    func image() {
        #expect(InlineParser.parse("![alt](u)") == [
            .image(range: r(0, 9), alt: r(2, 3), url: r(7, 1), markers: [r(0, 2), r(5, 1), r(6, 1), r(8, 1)]),
        ])
    }

    @Test("emphasis inside link text")
    func linkContainsEmphasis() {
        #expect(InlineParser.parse("[*x*](u)") == [
            .link(range: r(0, 8), textRange: r(1, 3), url: r(6, 1),
                  markers: [r(0, 1), r(4, 1), r(5, 1), r(7, 1)],
                  children: [.emphasis(.italic, range: r(1, 3), markers: [r(1, 1), r(3, 1)], children: [.text(r(2, 1))])]),
        ])
    }

    @Test("emphasis wraps a link")
    func emphasisWrapsLink() {
        #expect(InlineParser.parse("*[a](b)*") == [
            .emphasis(.italic, range: r(0, 8), markers: [r(0, 1), r(7, 1)], children: [
                .link(range: r(1, 6), textRange: r(2, 1), url: r(5, 1),
                      markers: [r(1, 1), r(3, 1), r(4, 1), r(6, 1)], children: [.text(r(2, 1))]),
            ]),
        ])
    }

    // MARK: - Inline LaTeX

    @Test("inline math")
    func inlineLatex() {
        #expect(InlineParser.parse("$a+b$") == [
            .inlineLatex(range: r(0, 5), content: r(1, 3), markers: [r(0, 1), r(4, 1)]),
        ])
    }

    @Test("a plain number is math, prices in prose are not")
    func numbersAreLatex() {
        for source in ["$0$", "$1$", "$3.14$", "$-5$", "$1,000$"] {
            let length = (source as NSString).length
            #expect(InlineParser.parse(source) == [
                .inlineLatex(range: r(0, length), content: r(1, length - 2),
                             markers: [r(0, 1), r(length - 1, 1)]),
            ], "\(source)")
        }
        #expect(InlineParser.parse("$5 and $10") == [.text(r(0, 10))])
    }

    @Test("a $…$ span that would cross a code span is not math (bug 3)")
    func dollarAcrossCodeNotLatex() {
        #expect(InlineParser.parse("$x `c` y$") == [
            .text(r(0, 3)),
            .code(range: r(3, 3), content: r(4, 1)),
            .text(r(6, 3)),
        ])
    }

    @Test("a LaTeX command spelled backslash + punctuation (`\\,`) stays inside the math")
    func latexPunctuationCommandIsNotAnEscape() {
        // `\,` is a thin space in LaTeX, not a Markdown escape of `,` — claiming
        // it as an escape used to reject the whole formula.
        #expect(InlineParser.parse(#"$P\,dx + Q\,dy$"#) == [
            .inlineLatex(range: r(0, 15), content: r(1, 13), markers: [r(0, 1), r(14, 1)]),
        ])
    }

    @Test("an escape outside the math is still an escape")
    func escapeBesideLatex() {
        #expect(InlineParser.parse(#"\*$a\,b$"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .inlineLatex(range: r(2, 6), content: r(3, 4), markers: [r(2, 1), r(7, 1)]),
        ])
    }

    @Test("an escaped dollar neither opens nor closes math")
    func escapedDollarIsNotADelimiter() {
        #expect(InlineParser.parse(#"\$a+b$"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 4)),
        ])
        #expect(InlineParser.parse(#"$a+b\$"#) == [
            .text(r(0, 4)),
            .escape(range: r(4, 2), character: r(5, 1), marker: r(4, 1)),
        ])
    }

    @Test("function-call notation is math even without operators")
    func functionCallIsLatex() {
        for source in ["$u(x,y)$", "$f(x)$", "$f'(x)$", "$(x, y)$", "$f(0.5)$"] {
            let length = (source as NSString).length
            #expect(InlineParser.parse(source) == [
                .inlineLatex(range: r(0, length), content: r(1, length - 2),
                             markers: [r(0, 1), r(length - 1, 1)]),
            ], "\(source)")
        }
    }

    @Test("prose between two dollars is still not math")
    func proseBetweenDollarsNotLatex() {
        for source in ["$5 (approx) and $", "$(US) and $", "$hello world$", "$f(x) and g$"] {
            let length = (source as NSString).length
            #expect(InlineParser.parse(source) == [.text(r(0, length))], "\(source)")
        }
    }

    @Test("math inside bold keeps both")
    func latexInsideBold() {
        let source = #"**a $P\,dx$ b $u(x,y)$**"#
        #expect(InlineParser.parse(source) == [
            .emphasis(.bold, range: r(0, 24), markers: [r(0, 2), r(22, 2)], children: [
                .text(r(2, 2)),
                .inlineLatex(range: r(4, 7), content: r(5, 5), markers: [r(4, 1), r(10, 1)]),
                .text(r(11, 3)),
                .inlineLatex(range: r(14, 8), content: r(15, 6), markers: [r(14, 1), r(21, 1)]),
            ]),
        ])
    }

    /// The source text of every formula and every bold span, in document order (nested ones included).
    private func spans(_ source: String) -> (latex: [String], bold: [String]) {
        let ns = source as NSString
        var latex: [String] = [], bold: [String] = []
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .inlineLatex(let range, _, _): latex.append(ns.substring(with: range))
                case .emphasis(let kind, let range, _, let children):
                    if kind == .bold { bold.append(ns.substring(with: range)) }
                    walk(children)
                case .link(_, _, _, _, let children): walk(children)
                default: break
                }
            }
        }
        walk(InlineParser.parse(source))
        return (latex, bold)
    }

    @Test("prime notation is math")
    func primesAreLatex() {
        for source in ["$y'$", "$y''$", "$f'$", "$xy'$", "$y'''$"] {
            #expect(spans(source).latex == [source], "\(source)")
        }
        #expect(spans("$abcd'$").latex.isEmpty)
    }

    @Test("Chinese prose between two dollars is not math, Chinese inside \\text is")
    func bareCJKNotLatex() {
        #expect(spans("$ 用**常数**系数 $").latex.isEmpty)
        #expect(spans("$ 用**常数**系数 $").bold == ["**常数**"])
        #expect(spans(#"$x>0 \text{且} y>0$"#).latex == [#"$x>0 \text{且} y>0$"#])
    }

    @Test("one formula the heuristic misses no longer pairs the rest across Chinese prose")
    func chineseSentenceWithPrimes() {
        let source = #"它把 $y$、$y'$、$y''$ 用**常数**系数拼起来。这就要求 $y'$、$y''$ 和 $y$ 是"同一类东西""#
        let s = spans(source)
        #expect(s.latex == ["$y$", "$y'$", "$y''$", "$y'$", "$y''$", "$y$"])
        #expect(s.bold == ["**常数**"])
    }

    @Test("bold closes before full-width punctuation even after an ASCII quote")
    func boldBeforeFullWidthParen() {
        #expect(spans(#"理由：**指数函数是"特征函数"**（和矩阵"#).bold == [#"**指数函数是"特征函数"**"#])
        #expect(spans(#"理由：**指数函数是"特征函数"**(和矩阵"#).bold == [#"**指数函数是"特征函数"**"#])
    }

    @Test("bold next to CJK text with full-width quotes inside still works")
    func boldBesideCJKQuotes() {
        #expect(spans("的**“特征函数”**是").bold == ["**“特征函数”**"])
        #expect(spans("“**特征函数**”").bold == ["**特征函数**"])
        #expect(spans("（**注**）").bold == ["**注**"])
        #expect(spans("系数：**常数**，").bold == ["**常数**"])
        #expect(spans("“**$x$**”").bold == ["**$x$**"])
        // Full-width punctuation still counts as a letter: strict CommonMark would reject both of these.
        #expect(spans("前文**（注）**1后文").bold == ["**（注）**"])
        #expect(spans("前文**“特征函数”**a后文").bold == ["**“特征函数”**"])
    }

    // MARK: - Strikethrough (extension-supplied `~~…~~` span)

    private var strikeRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: [StrikethroughExtension()])
    }

    private func strike(range: NSRange, markers: [NSRange], children: [InlineNode]) -> InlineNode {
        .ext(ExtensionInlineNode(
            extensionID: StrikethroughExtension.identifier,
            range: range,
            contentRange: NSRange(location: NSMaxRange(markers[0]),
                                  length: markers[1].location - NSMaxRange(markers[0])),
            markers: markers, children: children))
    }

    @Test("without a registered extension, ~~x~~ stays literal text")
    func strikethroughUnregisteredStaysLiteral() {
        #expect(InlineParser.parse("~~x~~") == [.text(r(0, 5))])
    }

    @Test("strikethrough, content recursively parsed")
    func strikethrough() {
        #expect(InlineParser.parse("~~x~~", registry: strikeRegistry) == [
            strike(range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple tildes do not strike")
    func tripleTildeNotStrike() {
        #expect(InlineParser.parse("~~~x~~~", registry: strikeRegistry) == [.text(r(0, 7))])
    }

    @Test("~~abc~~~ stays literal (closer must not extend a longer run)")
    func strikethroughRejectsCloserRun() {
        #expect(InlineParser.parse("~~abc~~~", registry: strikeRegistry) == [.text(r(0, 8))])
    }

    @Test("strikethrough wraps emphasis")
    func strikeWrapsEmphasis() {
        #expect(InlineParser.parse("~~*x*~~", registry: strikeRegistry) == [
            strike(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    @Test("an extension sharing a built-in trigger char is reachable when the built-in fails")
    func extensionReachableAfterBuiltInFails() {
        // `$hello world$` is rejected by the built-in math heuristic (prose); a
        // registered `$…$` extension must still get its chance (fall-through).
        struct DollarSpan: MarkdownExtension {
            var id: String { "dollar-span" }
            var inline: InlineSyntax? { InlineSyntax(open: "$", close: "$", parsesContent: false) }
            func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] { [:] }
            func html(childrenHTML: String) -> String { childrenHTML }
        }
        let registry = ExtensionRegistry(extensions: [DollarSpan()])
        let nodes = InlineParser.parse("$hello world$", registry: registry)
        guard case .ext(let node) = nodes.first else {
            Issue.record("expected extension span, got \(nodes)")
            return
        }
        #expect(node.extensionID == "dollar-span")
        // And the built-in still wins when it matches: real math parses as latex.
        let mathNodes = InlineParser.parse("$x^2 + y$", registry: registry)
        guard case .inlineLatex = mathNodes.first else {
            Issue.record("built-in latex must win over the extension, got \(mathNodes)")
            return
        }
    }

    @Test("both extensions registered: ~~ and == coexist and nest")
    func strikeAndHighlightCoexist() {
        let registry = ExtensionRegistry(extensions: [HighlightExtension(), StrikethroughExtension()])
        let nodes = InlineParser.parse("~~a~~ ==b==", registry: registry)
        #expect(nodes.count == 3)   // strike, " ", highlight
        if case .ext(let first) = nodes[0] { #expect(first.extensionID == StrikethroughExtension.identifier) }
        if case .ext(let last) = nodes[2] { #expect(last.extensionID == HighlightExtension.identifier) }
    }

    // MARK: - Highlight (extension-supplied `==…==` span)

    private var highlightRegistry: ExtensionRegistry {
        ExtensionRegistry(extensions: [HighlightExtension()])
    }

    private func hi(range: NSRange, markers: [NSRange], children: [InlineNode]) -> InlineNode {
        .ext(ExtensionInlineNode(
            extensionID: HighlightExtension.identifier,
            range: range,
            contentRange: NSRange(location: NSMaxRange(markers[0]),
                                  length: markers[1].location - NSMaxRange(markers[0])),
            markers: markers, children: children))
    }

    @Test("without a registered extension, ==x== stays literal text")
    func highlightUnregisteredStaysLiteral() {
        #expect(InlineParser.parse("==x==") == [.text(r(0, 5))])
    }

    @Test("highlight, content recursively parsed")
    func highlight() {
        #expect(InlineParser.parse("==x==", registry: highlightRegistry) == [
            hi(range: r(0, 5), markers: [r(0, 2), r(3, 2)], children: [.text(r(2, 1))]),
        ])
    }

    @Test("triple equals do not highlight")
    func tripleEqualsNotHighlight() {
        #expect(InlineParser.parse("===x===", registry: highlightRegistry) == [.text(r(0, 7))])
    }

    @Test("==abc=== matches ==abc==, trailing = is plain text")
    func highlightToleratesTrailingTripleEquals() {
        #expect(InlineParser.parse("==abc===", registry: highlightRegistry) == [
            hi(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [.text(r(2, 3))]),
            .text(r(7, 1)),
        ])
    }

    @Test("highlight wraps emphasis")
    func highlightWrapsEmphasis() {
        #expect(InlineParser.parse("==*x*==", registry: highlightRegistry) == [
            hi(range: r(0, 7), markers: [r(0, 2), r(5, 2)], children: [
                .emphasis(.italic, range: r(2, 3), markers: [r(2, 1), r(4, 1)], children: [.text(r(3, 1))]),
            ]),
        ])
    }

    @Test("a lone = inside content aborts the highlight candidate")
    func highlightLoneEqualsAborts() {
        #expect(InlineParser.parse("==a=b==", registry: highlightRegistry) == [.text(r(0, 7))])
    }

    @Test("highlight never crosses a code span")
    func highlightDoesNotCrossCodeSpan() {
        // The backtick run is claimed first; the == candidate overlapping it is rejected.
        #expect(InlineParser.parse("==a `b==` c", registry: highlightRegistry) == [
            .text(r(0, 4)),
            .code(range: r(4, 5), content: r(5, 3)),
            .text(r(9, 2)),
        ])
    }

    // MARK: - Backslash escapes

    @Test("escaped punctuation becomes an escape node")
    func backslashEscape() {
        #expect(InlineParser.parse(#"\*x"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
        ])
    }

    @Test("escaped asterisks do not emphasize")
    func escapedStarsNotEmphasis() {
        #expect(InlineParser.parse(#"\*a\*"#) == [
            .escape(range: r(0, 2), character: r(1, 1), marker: r(0, 1)),
            .text(r(2, 1)),
            .escape(range: r(3, 2), character: r(4, 1), marker: r(3, 1)),
        ])
    }

    @Test("backslash inside a code span is literal (no escape)")
    func escapeInsideCodeIgnored() {
        #expect(InlineParser.parse(#"`\*`"#) == [.code(range: r(0, 4), content: r(1, 2))])
    }
}
