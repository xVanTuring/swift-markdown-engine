//
//  MarkdownDisplayRenderer.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) Read-only Markdown for display, in segments.
//
//  For embedders that show Markdown they never edit — chat transcripts, quiz
//  text — and want it cheap to lay out and to re-wrap at a new width. The
//  editor keeps the whole document in one TextKit 2 view with its source
//  hidden in place; here the same parse (`DocumentAST`, so the result matches
//  the editor: `$…$` rules, escapes, extensions) becomes plain styled text runs
//  plus the pieces that are not text (code, display math, tables, rules,
//  standalone images). The embedder lays each segment out on its own — text
//  runs with TextKit 1 / CoreText — so a width change re-wraps text instead of
//  re-styling a hidden-source document.
//
//  Paragraphs, headings and lists that follow each other form ONE text segment
//  (one selectable run); a line break inside a paragraph is U+2028, so it does
//  not pick up paragraph spacing.
//

import AppKit

/// One displayable piece of a Markdown document.
public enum MarkdownDisplaySegment {
    /// Paragraphs, headings and lists in a row.
    case text(NSAttributedString, range: NSRange)
    /// A block quote's text; the embedder draws the bar.
    case quote(NSAttributedString, range: NSRange)
    /// A fenced code block: the info-string language and the code between the fences.
    case code(language: String?, code: String, range: NSRange)
    /// `$$ … $$` display math (delimiters stripped).
    case math(latex: String, range: NSRange)
    /// A GFM table's source; render it with ``MarkdownDisplayRenderer/tableImage(source:style:availableWidth:appearance:)``.
    case table(source: String, range: NSRange)
    /// A thematic break.
    case rule(range: NSRange)
    /// A paragraph that is nothing but one image (`![alt](url)` or `![[target]]`).
    case image(url: String, alt: String, range: NSRange)

    /// The segment's source range in the Markdown text (UTF-16).
    public var range: NSRange {
        switch self {
        case .text(_, let r), .quote(_, let r), .code(_, _, let r), .math(_, let r),
             .table(_, let r), .rule(let r), .image(_, _, let r):
            return r
        }
    }
}

/// What display segments are styled with.
public struct MarkdownDisplayStyle {
    /// Theme, heading scale, list indent, inline-code scale, LaTeX renderer,
    /// extensions, code background (``SyntaxHighlighter/backgroundColor()``)
    /// and table appearance come from here.
    public var configuration: MarkdownEditorConfiguration
    /// Body text font.
    public var font: NSFont

    public init(configuration: MarkdownEditorConfiguration, font: NSFont) {
        self.configuration = configuration
        self.font = font
    }
}

public enum MarkdownDisplayRenderer {

    /// On an inline formula's attachment character: its Markdown source (`$…$`),
    /// so a copy can put the formula back as text.
    public static let sourceAttribute = NSAttributedString.Key("MarkdownDisplaySource")

    /// Scheme of the `.link` a `[[target]]` carries: `x-markdown-wiki:<target, percent-encoded>`.
    public static let wikiLinkScheme = "x-markdown-wiki"

    /// The target of a wiki link produced here, or nil for any other link.
    public static func wikiLinkTarget(_ link: Any) -> String? {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == wikiLinkScheme else { return nil }
        let encoded = url.absoluteString.dropFirst(wikiLinkScheme.count + 1)
        return String(encoded).removingPercentEncoding
    }

    // MARK: Segments

    public static func segments(for markdown: String, style: MarkdownDisplayStyle) -> [MarkdownDisplaySegment] {
        let ns = markdown as NSString
        let builder = Builder(style: style)
        let nodes = DocumentAST.parse(markdown, registry: style.configuration.extensionRegistry)

        var out: [MarkdownDisplaySegment] = []
        var run = NSMutableAttributedString()
        var runRange: NSRange?
        func flushRun() {
            if run.length > 0, let r = runRange { out.append(.text(run, range: r)) }
            run = NSMutableAttributedString()
            runRange = nil
        }
        func addToRun(_ s: NSAttributedString, _ r: NSRange) {
            guard s.length > 0 else { return }
            if run.length > 0 {
                run.append(NSAttributedString(string: "\n", attributes: builder.separatorAttributes))
            }
            run.append(s)
            runRange = runRange.map { NSUnionRange($0, r) } ?? r
        }

        for node in nodes {
            switch node {
            case .paragraph(let r, let inlines):
                if let image = soleImage(inlines, ns) {
                    flushRun()
                    out.append(.image(url: image.url, alt: image.alt, range: r))
                } else {
                    addToRun(builder.paragraph(inlines, ns), r)
                }
            case .heading(let level, let r, _, let inlines):
                addToRun(builder.heading(level: level, inlines, ns), r)
            case .list(let r, let items):
                addToRun(builder.list(items, ns), r)
            case .blockquote(let r, _):
                flushRun()
                out.append(.quote(builder.quote(range: r, ns), range: r))
            case .codeBlock(let r):
                flushRun()
                let parts = codeParts(ns.substring(with: r))
                out.append(.code(language: parts.language, code: parts.code, range: r))
            case .blockLatex(let r):
                flushRun()
                out.append(.math(latex: mathBody(ns.substring(with: r)), range: r))
            case .table(let r):
                flushRun()
                out.append(.table(source: ns.substring(with: r), range: r))
            case .thematicBreak(let r):
                flushRun()
                out.append(.rule(range: r))
            case .blank:
                continue
            case .ext(let node):
                addToRun(builder.paragraph(node.inlines, ns), node.range)
            }
        }
        flushRun()
        return out
    }

    // MARK: Tables

    private static let tableCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// A table rendered exactly as the editor renders it (same look, same
    /// `TableAppearance`), wrapping its cells to `availableWidth` when it can;
    /// wider than that when its columns cannot shrink further (scroll it).
    /// Colors are resolved under `appearance`. nil when `source` is not a table.
    public static func tableImage(
        source: String, style: MarkdownDisplayStyle, availableWidth: CGFloat, appearance: NSAppearance
    ) -> NSImage? {
        let c = style.configuration
        let key = [appearance.name.rawValue, style.font.fontName, "\(style.font.pointSize)",
                   "\(Double(availableWidth).bitPattern)", "\(c.tableAppearance)",
                   "\(c.extensionRegistry.fingerprint)", "\(ObjectIdentifier(type(of: c.services.latex)))",
                   source].joined(separator: "|") as NSString
        if let hit = tableCache.object(forKey: key) { return hit }
        guard let parsed = MarkdownStyler.parseTableSource(source) else { return nil }
        let image = MarkdownStyler.renderTable(
            parsed, baseFont: style.font, theme: c.theme,
            codeBackgroundColor: c.services.syntaxHighlighter.backgroundColor(),
            latex: c.services.latex, appearance: appearance, availableWidth: availableWidth,
            extensions: c.extensions, style: c.tableAppearance)
        tableCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Block pieces

    /// `![alt](url)` / `![[target]]` alone in a paragraph (whitespace aside).
    private static func soleImage(_ inlines: [InlineNode], _ ns: NSString) -> (url: String, alt: String)? {
        var found: (String, String)?
        for node in inlines {
            switch node {
            case .image(_, let alt, let url, _):
                guard found == nil else { return nil }
                found = (ns.substring(with: url), ns.substring(with: alt))
            case .imageEmbed(_, let target, _):
                guard found == nil else { return nil }
                let t = ns.substring(with: target)
                found = (t, t)
            case .text(let r):
                guard ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            default:
                return nil
            }
        }
        return found
    }

    /// Fenced code: language from the opening fence, body without the fence lines.
    static func codeParts(_ raw: String) -> (language: String?, code: String) {
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let language = lines.first.map { $0.drop { $0 == "`" || $0 == "~" }.trimmingCharacters(in: .whitespaces) }
        var body = Array(lines.dropFirst())
        if let last = body.last, last.hasPrefix("```") || last.hasPrefix("~~~") { body.removeLast() }
        return (language?.isEmpty == false ? language : nil, body.joined(separator: "\n"))
    }

    /// `$$ … $$` → the LaTeX between the delimiters.
    static func mathBody(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$") { s.removeFirst(2) }
        if s.hasSuffix("$$") { s.removeLast(2) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Builder

    private struct Builder {
        let style: MarkdownDisplayStyle
        let theme: MarkdownEditorTheme
        let font: NSFont
        let descriptor: NSFontDescriptor
        let codeFont: NSFont
        let codeBackground: NSColor
        let latex: any LatexRenderer
        let extensionsByID: [String: any MarkdownExtension]
        let registry: ExtensionRegistry

        /// Space after a paragraph / heading / list; between lines of one paragraph.
        var paragraphGap: CGFloat { (font.pointSize * 0.6).rounded() }
        var lineGap: CGFloat { (font.pointSize * 0.2).rounded() }

        init(style: MarkdownDisplayStyle) {
            self.style = style
            theme = style.configuration.theme
            font = style.font
            descriptor = style.font.fontDescriptor
            codeFont = .monospacedSystemFont(
                ofSize: (style.font.pointSize * style.configuration.inlineCode.fontSizeScale).rounded(),
                weight: .regular)
            codeBackground = style.configuration.services.syntaxHighlighter.backgroundColor()
            latex = style.configuration.services.latex
            var byID: [String: any MarkdownExtension] = [:]
            for ext in style.configuration.extensions { byID[ext.id] = ext }
            extensionsByID = byID
            registry = style.configuration.extensionRegistry
        }

        var separatorAttributes: [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: theme.bodyText, .paragraphStyle: bodyParagraph()]
        }

        func bodyParagraph(after: CGFloat? = nil, before: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineGap
            p.paragraphSpacing = after ?? paragraphGap
            p.paragraphSpacingBefore = before
            return p
        }

        // Blocks

        func paragraph(_ inlines: [InlineNode], _ ns: NSString) -> NSAttributedString {
            let out = NSMutableAttributedString()
            append(inlines, ns, font: font, link: nil, into: out)
            trimTrailingBreaks(out)
            out.addAttribute(.paragraphStyle, value: bodyParagraph(), range: NSRange(location: 0, length: out.length))
            return out
        }

        func heading(level: Int, _ inlines: [InlineNode], _ ns: NSString) -> NSAttributedString {
            let l = min(max(level, 1), 6)
            let multipliers = style.configuration.headings.fontMultipliers
            let tops = style.configuration.headings.topSpacingEm
            let size = (font.pointSize * (multipliers.indices.contains(l - 1) ? multipliers[l - 1] : 1)).rounded()
            let headingFont = NSFont(descriptor: descriptor.withSymbolicTraits(.bold), size: size)
                ?? .boldSystemFont(ofSize: size)
            let out = NSMutableAttributedString()
            append(inlines, ns, font: headingFont, link: nil, into: out)
            trimTrailingBreaks(out)
            let before = size * (tops.indices.contains(l - 1) ? tops[l - 1] : 0) + font.pointSize * 0.3
            out.addAttribute(.paragraphStyle, value: bodyParagraph(after: (font.pointSize * 0.35).rounded(), before: before.rounded()),
                             range: NSRange(location: 0, length: out.length))
            return out
        }

        func quote(range: NSRange, _ ns: NSString) -> NSAttributedString {
            let stripped = ns.substring(with: range)
                .components(separatedBy: "\n")
                .map(Self.stripQuoteMarkers)
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            let inner = stripped as NSString
            let out = NSMutableAttributedString()
            append(InlineParser.parse(stripped, registry: registry), inner, font: font, link: nil, into: out)
            trimTrailingBreaks(out)
            out.addAttribute(.paragraphStyle, value: bodyParagraph(after: 0), range: NSRange(location: 0, length: out.length))
            return out
        }

        private static func stripQuoteMarkers(_ line: String) -> String {
            var s = Substring(line)
            var indent = 0
            while let c = s.first, c == " " || c == "\t", indent < 3 { s = s.dropFirst(); indent += 1 }
            while s.first == ">" {
                s = s.dropFirst()
                if s.first == " " || s.first == "\t" { s = s.dropFirst() }
            }
            return String(s)
        }

        /// Items one per paragraph: marker, tab, text, hanging indent. Depth is
        /// read as a stack of raw indents (as `MarkdownHTMLRenderer` does); ordered
        /// items number on from the first one at each level.
        func list(_ items: [ListItem], _ ns: NSString) -> NSAttributedString {
            let indentUnit = style.configuration.lists.indentPerLevel
            // Markers first (numbering needs the whole level), then one column wide
            // enough for the widest marker plus half an em.
            var indents: [Int] = []
            var counters: [Int?] = []
            var entries: [(item: ListItem, depth: Int, marker: String)] = []
            for item in items {
                while let last = indents.last, item.indent < last { indents.removeLast(); counters.removeLast() }
                if indents.last.map({ item.indent > $0 }) ?? true {
                    indents.append(item.indent)
                    counters.append(nil)
                }
                let depth = indents.count - 1
                let marker: String
                if let checkbox = item.checkbox, checkbox.length > 0 {
                    marker = item.checked ? "☑︎" : "☐"
                } else if item.ordered {
                    let n = counters[depth].map { $0 + 1 } ?? (item.number ?? 1)
                    counters[depth] = n
                    marker = "\(n)."
                } else {
                    counters[depth] = nil
                    marker = ["•", "◦", "▪︎"][depth % 3]
                }
                entries.append((item, depth, marker))
            }
            let widest = entries.map { ($0.marker as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let markerColumn = ceil(widest + font.pointSize * 0.5)

            let out = NSMutableAttributedString()
            for (index, entry) in entries.enumerated() {
                let lead = CGFloat(entry.depth) * indentUnit
                let p = NSMutableParagraphStyle()
                p.lineSpacing = lineGap
                p.firstLineHeadIndent = lead
                p.headIndent = lead + markerColumn
                p.tabStops = [NSTextTab(textAlignment: .left, location: lead + markerColumn)]
                p.defaultTabInterval = markerColumn
                p.paragraphSpacing = index == entries.count - 1 ? paragraphGap : (font.pointSize * 0.25).rounded()
                let line = NSMutableAttributedString(string: entry.marker + "\t", attributes: [
                    .font: font, .foregroundColor: theme.bodyText
                ])
                append(entry.item.inlines, ns, font: font, link: nil, into: line)
                trimTrailingBreaks(line)
                line.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: line.length))
                if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: p])) }
                out.append(line)
            }
            return out
        }

        // Inlines

        private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        private func trimTrailingBreaks(_ s: NSMutableAttributedString) {
            while s.length > 0 {
                let last = (s.string as NSString).character(at: s.length - 1)
                guard last == 0x0A || last == 0x2028 || last == 0x0D || last == 0x20 else { break }
                s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1))
            }
        }

        func append(_ nodes: [InlineNode], _ ns: NSString, font f: NSFont, link: Any?, into out: NSMutableAttributedString) {
            func plain(_ text: String, _ f: NSFont, _ link: Any?, autolink: Bool) {
                // A source line break inside a paragraph is a line break, not a new paragraph.
                let text = text.replacingOccurrences(of: "\r\n", with: "\u{2028}")
                    .replacingOccurrences(of: "\n", with: "\u{2028}")
                var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: theme.bodyText]
                if let link { attrs[.link] = link; attrs[.foregroundColor] = theme.link }
                let piece = NSMutableAttributedString(string: text, attributes: attrs)
                if autolink, link == nil, let detector = Self.linkDetector {
                    for match in detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                        guard let url = match.url else { continue }
                        piece.addAttributes([.link: url, .foregroundColor: theme.link], range: match.range)
                    }
                }
                out.append(piece)
            }
            for node in nodes {
                switch node {
                case .text(let r):
                    plain(ns.substring(with: r), f, link, autolink: true)
                case .escape(_, let character, _):
                    plain(ns.substring(with: character), f, link, autolink: false)
                case .emphasis(let kind, _, _, let children):
                    append(children, ns, font: MarkdownStyler.composeEmphasis(
                        f, kind, baseDescriptor: f.fontDescriptor, pointSize: f.pointSize), link: link, into: out)
                case .code(_, let content):
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: (f.pointSize * style.configuration.inlineCode.fontSizeScale).rounded(), weight: .regular),
                        .backgroundColor: codeBackground, .foregroundColor: theme.bodyText,
                    ]
                    if let link { attrs[.link] = link }
                    out.append(NSAttributedString(string: ns.substring(with: content), attributes: attrs))
                case .link(_, _, let url, _, let children):
                    let target = ns.substring(with: url).trimmingCharacters(in: .whitespaces)
                    let value: Any = URL(string: target) ?? target
                    append(children, ns, font: f, link: value, into: out)
                case .image(_, let alt, let url, _):
                    let a = ns.substring(with: alt), u = ns.substring(with: url)
                    plain(a.isEmpty ? u : a, f, URL(string: u) ?? u, autolink: false)
                case .wikiLink(_, let name, _, _):
                    let target = ns.substring(with: name)
                    let encoded = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
                    plain(target, f, URL(string: "\(MarkdownDisplayRenderer.wikiLinkScheme):\(encoded)"), autolink: false)
                case .imageEmbed(_, let target, _):
                    let t = ns.substring(with: target)
                    let encoded = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? t
                    plain(t, f, URL(string: "\(MarkdownDisplayRenderer.wikiLinkScheme):\(encoded)"), autolink: false)
                case .inlineLatex(let range, let content, _):
                    if let entry = latex.render(latex: ns.substring(with: content), mode: .inline,
                                                fontSize: f.pointSize, theme: theme) {
                        let attachment = NSTextAttachment()
                        attachment.image = entry.image
                        // `baselineOffset` is how far the formula reaches BELOW the baseline; an attachment's
                        // bounds.y is measured UP from it (fork fix: it was raised by twice its descent).
                        attachment.bounds = CGRect(x: 0, y: -entry.baselineOffset,
                                                   width: entry.size.width, height: entry.size.height)
                        let piece = NSMutableAttributedString(attachment: attachment)
                        piece.addAttributes([.font: f, MarkdownDisplayRenderer.sourceAttribute: ns.substring(with: range)],
                                            range: NSRange(location: 0, length: piece.length))
                        out.append(piece)
                    } else {
                        plain(ns.substring(with: range), f, link, autolink: false)
                    }
                case .ext(let extNode):
                    let start = out.length
                    if extNode.children.isEmpty {
                        plain(ns.substring(with: extNode.contentRange), f, link, autolink: false)
                    } else {
                        append(extNode.children, ns, font: f, link: link, into: out)
                    }
                    if out.length > start, let ext = extensionsByID[extNode.extensionID] {
                        var attributes = ext.contentAttributes(theme: theme)
                        if let fill = attributes.removeValue(forKey: .markdownBlockBackground) {
                            attributes[.backgroundColor] = fill
                        }
                        out.addAttributes(attributes, range: NSRange(location: start, length: out.length - start))
                    }
                }
            }
        }
    }
}
