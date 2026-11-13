//
//  MarkdownDisplayRendererTests.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) Read-only display segments.
//
import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Markdown display renderer")
struct MarkdownDisplayRendererTests {
    static let style = MarkdownDisplayStyle(configuration: .default, font: .systemFont(ofSize: 13))

    static let doc = """
    # Title

    First **bold** line
    second line with [a link](https://example.com) and www.apple.com.

    1. one
    1. two
       - nested
    3. three

    > quoted *text*
    > more

    ```swift
    let x = 1
    ```

    $$
    a^2 + b^2
    $$

    | A | B |
    |---|---|
    | 1 | 2 |

    ---

    ![diagram](images/d.png)

    See [[Some Note]] after.
    """

    @Test("Blocks become segments; text-like blocks merge into one run")
    func segmentKinds() {
        let segments = MarkdownDisplayRenderer.segments(for: Self.doc, style: Self.style)
        let kinds = segments.map { s -> String in
            switch s {
            case .text: return "text"
            case .quote: return "quote"
            case .code: return "code"
            case .math: return "math"
            case .table: return "table"
            case .rule: return "rule"
            case .image: return "image"
            }
        }
        #expect(kinds == ["text", "quote", "code", "math", "table", "rule", "image", "text"])
        guard case .text(let first, _) = segments[0] else { Issue.record("first is text"); return }
        #expect(first.string.hasPrefix("Title\nFirst bold line\u{2028}second line"))
        guard case .code(let language, let code, _) = segments[2] else { Issue.record("code"); return }
        #expect(language == "swift")
        #expect(code == "let x = 1")
        guard case .math(let latex, _) = segments[3] else { Issue.record("math"); return }
        #expect(latex == "a^2 + b^2")
        guard case .table(let source, _) = segments[4] else { Issue.record("table"); return }
        #expect(source.hasPrefix("| A | B |"))
        guard case .image(let url, let alt, _) = segments[6] else { Issue.record("image"); return }
        #expect(url == "images/d.png" && alt == "diagram")
        guard case .quote(let quote, _) = segments[1] else { Issue.record("quote"); return }
        #expect(quote.string == "quoted text\u{2028}more" || quote.string == "quoted text\nmore")
    }

    @Test("Inline styling: bold, links, autolinks, wiki links")
    func inlineStyling() throws {
        let segments = MarkdownDisplayRenderer.segments(for: Self.doc, style: Self.style)
        guard case .text(let first, _) = segments[0] else { Issue.record("text"); return }
        let s = first.string as NSString
        let bold = s.range(of: "bold")
        let font = try #require(first.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let link = s.range(of: "a link")
        #expect((first.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.host == "example.com")
        let auto = s.range(of: "www.apple.com")
        #expect(first.attribute(.link, at: auto.location, effectiveRange: nil) != nil)
        guard case .text(let last, _) = segments.last! else { Issue.record("last text"); return }
        let wiki = (last.string as NSString).range(of: "Some Note")
        #expect(wiki.location != NSNotFound, "wiki link shows its name, no brackets")
        let value = try #require(last.attribute(.link, at: wiki.location, effectiveRange: nil))
        #expect(MarkdownDisplayRenderer.wikiLinkTarget(value) == "Some Note")
    }

    @Test("Ordered lists number on; nested items indent deeper")
    func lists() throws {
        let segments = MarkdownDisplayRenderer.segments(for: Self.doc, style: Self.style)
        guard case .text(let first, _) = segments[0] else { Issue.record("text"); return }
        let s = first.string
        #expect(s.contains("1.\tone"))
        #expect(s.contains("2.\ttwo"), "lazy `1.` numbering counts on")
        #expect(s.contains("3.\tthree"))
        let ns = s as NSString
        let outer = try #require(first.attribute(.paragraphStyle, at: ns.range(of: "two").location, effectiveRange: nil) as? NSParagraphStyle)
        let inner = try #require(first.attribute(.paragraphStyle, at: ns.range(of: "nested").location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(inner.headIndent > outer.headIndent)
    }

    @Test("Table images follow the configured appearance")
    func tableImage() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.tableAppearance = .rounded
        let style = MarkdownDisplayStyle(configuration: configuration, font: .systemFont(ofSize: 13))
        let image = try #require(MarkdownDisplayRenderer.tableImage(
            source: "| A | B |\n|---|---|\n| 1 | 2 |", style: style, availableWidth: 400,
            appearance: NSAppearance(named: .aqua)!))
        #expect(image.tableGeometry?.style == .rounded)
        #expect(image.size.width <= 400)
        #expect(MarkdownDisplayRenderer.tableImage(source: "not a table", style: style, availableWidth: 400,
                                                   appearance: NSAppearance(named: .aqua)!) == nil)
    }
}

/// A formula 20×10 that reaches 3pt below the baseline.
private struct FixedLatex: LatexRenderer {
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        LatexRenderResult(image: NSImage(size: CGSize(width: 20, height: 10)), size: CGSize(width: 20, height: 10), baselineOffset: 3)
    }
}

@MainActor
@Suite("Markdown display renderer — inline formulas")
struct MarkdownDisplayRendererLatexTests {
    @Test("An inline formula sits on the baseline: its descent goes below it, and copy keeps the source")
    func inlineFormulaBaseline() throws {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.latex = FixedLatex()
        let style = MarkdownDisplayStyle(configuration: configuration, font: .systemFont(ofSize: 13))
        let segments = MarkdownDisplayRenderer.segments(for: "x $a^2$ y", style: style)
        guard case .text(let s, _) = try #require(segments.first) else { Issue.record("text"); return }
        var found: NSTextAttachment?
        var source: String?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, r, _ in
            if let a = value as? NSTextAttachment {
                found = a
                source = s.attribute(MarkdownDisplayRenderer.sourceAttribute, at: r.location, effectiveRange: nil) as? String
            }
        }
        let attachment = try #require(found)
        #expect(attachment.bounds.origin.y == -3)
        #expect(source == "$a^2$")
    }

    @Test("Same in a table cell")
    func tableCellFormulaBaseline() throws {
        let cell = MarkdownStyler.formattedCellString(
            "$a^2$", baseFont: .systemFont(ofSize: 13), header: false, theme: .default,
            codeBackgroundColor: .clear, latex: FixedLatex())
        var y: CGFloat?
        cell.enumerateAttribute(.attachment, in: NSRange(location: 0, length: cell.length)) { value, _, _ in
            if let a = value as? NSTextAttachment { y = a.bounds.origin.y }
        }
        #expect(y == -3)
    }
}
