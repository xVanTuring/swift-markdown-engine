//
//  QuoteSyntax.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) What sits INSIDE a block quote beyond inline text:
//
//  • Display math. A quote line whose content starts with `$$` opens a block
//    formula, closed by the next `$$` — on the same line, or on a later line of
//    the same quote (`> $$` ⏎ `> \frac{a}{b}` ⏎ `> $$`). The `>` markers of the
//    continuation lines belong to the quote, not to the formula
//    (`QuoteMath.latexBody`). Outside quotes the block parser already makes
//    `$$` its own block; inside, a quote line is never a `$$` block, so the
//    blockquote tokenizer emits these tokens itself.
//
//  • Obsidian callouts. `> [!type] Title` as the first line of a quote level
//    turns that level into a callout box: tinted, its bar in the type colour,
//    an icon before the title (the type's name when no title is written).
//    `[!type]+` / `[!type]-` (foldable) are recognised; folding is not done —
//    the callout always shows expanded. Callouts nest (`> > [!tip]`).
//
//  The quote-line grammar is the one the blockquote tokenizer and styler use:
//  up to three spaces / tabs, then `>` repeated, each optionally followed by one
//  space or tab.
//

import AppKit
import CoreText

enum QuoteSyntax {

    static let gt: unichar = 0x3E
    static let space: unichar = 0x20
    static let tab: unichar = 0x09
    static let lf: unichar = 0x0A
    static let cr: unichar = 0x0D
    static let dollar: unichar = 0x24

    /// One physical line, read as a quote line.
    struct Line: Equatable {
        /// The whole line, newline included.
        let range: NSRange
        /// End of the line's text (before its newline).
        let contentEnd: Int
        /// Number of `>` — 0 when the line is not a quote line.
        let level: Int
        let markerStart: Int
        /// Just past the last `>` and the space / tab after it.
        let markerEnd: Int

        var markerRange: NSRange { NSRange(location: markerStart, length: markerEnd - markerStart) }
        var contentRange: NSRange { NSRange(location: markerEnd, length: max(0, contentEnd - markerEnd)) }
        /// The line without its newline.
        var textRange: NSRange { NSRange(location: range.location, length: contentEnd - range.location) }
    }

    static func isWS(_ c: unichar) -> Bool { c == space || c == tab }

    /// The line starting at `lineStart` (a line start in `ns`).
    static func line(in ns: NSString, at lineStart: Int) -> Line {
        // Foundation finds the line end in bulk; walking it per character through
        // a bridged Swift string costs far more on long CJK lines.
        var end = lineStart
        var contentEnd = lineStart
        if lineStart < ns.length {
            ns.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: lineStart, length: 0))
        }
        var i = lineStart
        var indent = 0
        while i < contentEnd, indent < 3, isWS(ns.character(at: i)) { i += 1; indent += 1 }
        let markerStart = i
        var level = 0
        while i < contentEnd, ns.character(at: i) == gt {
            level += 1
            i += 1
            if i < contentEnd, isWS(ns.character(at: i)) { i += 1 }
        }
        return Line(range: NSRange(location: lineStart, length: end - lineStart),
                    contentEnd: contentEnd, level: level,
                    markerStart: level > 0 ? markerStart : lineStart,
                    markerEnd: level > 0 ? i : lineStart)
    }

    /// Every line touching `range` (which should start at a line start).
    static func lines(in ns: NSString, range: NSRange) -> [Line] {
        var out: [Line] = []
        var start = range.location
        let end = min(NSMaxRange(range), ns.length)
        while start < end {
            let l = line(in: ns, at: start)
            out.append(l)
            if NSMaxRange(l.range) <= start { break }
            start = NSMaxRange(l.range)
        }
        return out
    }

    /// The run of consecutive quote lines around `location` — what the block
    /// parser groups into one blockquote block. Nil when that line is no quote
    /// line. The walk is capped; a quote longer than the cap is cut there.
    static func blockRange(around location: Int, in ns: NSString, cap: Int = 4000) -> NSRange? {
        guard location >= 0, location <= ns.length, ns.length > 0 else { return nil }
        let here = ns.lineRange(for: NSRange(location: min(location, ns.length - 1), length: 0))
        guard line(in: ns, at: here.location).level > 0 else { return nil }
        var start = here.location
        var steps = 0
        while start > 0, steps < cap {
            let prev = ns.lineRange(for: NSRange(location: start - 1, length: 0))
            guard line(in: ns, at: prev.location).level > 0 else { break }
            start = prev.location
            steps += 1
        }
        var end = NSMaxRange(here)
        steps = 0
        while end < ns.length, steps < cap {
            let next = line(in: ns, at: end)
            guard next.level > 0, NSMaxRange(next.range) > end else { break }
            end = NSMaxRange(next.range)
            steps += 1
        }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Display math in quotes

enum QuoteMath {

    /// `.blockLatex` tokens for every `$$…$$` that opens a quote line's content
    /// inside `range` (one blockquote block). Ranges are in `ns`'s coordinates.
    static func tokens(in ns: NSString, range: NSRange) -> [MarkdownToken] {
        guard ns.range(of: "$$", options: [], range: range).location != NSNotFound else { return [] }
        let lines = QuoteSyntax.lines(in: ns, range: range)
        var out: [MarkdownToken] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            var p = l.markerEnd
            while p < l.contentEnd, QuoteSyntax.isWS(ns.character(at: p)) { p += 1 }
            guard l.level > 0, p + 1 < l.contentEnd,
                  ns.character(at: p) == QuoteSyntax.dollar, ns.character(at: p + 1) == QuoteSyntax.dollar else {
                i += 1
                continue
            }
            // Closed on the same line: at least one character between the pairs.
            if let close = doubleDollar(in: ns, from: p + 3, to: l.contentEnd) {
                out.append(token(open: p, close: close))
                i += 1
                continue
            }
            // Closed by the first later line of this quote that holds a `$$`.
            var closedAt: Int?
            var j = i + 1
            while j < lines.count {
                if let close = doubleDollar(in: ns, from: lines[j].markerEnd, to: lines[j].contentEnd) {
                    out.append(token(open: p, close: close))
                    closedAt = j
                    break
                }
                j += 1
            }
            i = (closedAt ?? i) + 1
        }
        return out
    }

    /// The formula of a quote's `$$` token: the content with each continuation
    /// line's `>` markers taken off (they belong to the quote).
    static func latexBody(_ raw: String) -> String {
        guard raw.contains("\n") || raw.contains("\r") else { return raw }
        let ns = raw as NSString
        var out = ""
        var first = true
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, lineRange, enclosing, _ in
            let lineNS = ns.substring(with: lineRange) as NSString
            let body: String
            if first {
                body = lineNS as String
            } else {
                let l = QuoteSyntax.line(in: lineNS, at: 0)
                body = l.level > 0 ? lineNS.substring(from: l.markerEnd) : lineNS as String
            }
            out += body
            out += ns.substring(with: NSRange(location: NSMaxRange(lineRange), length: NSMaxRange(enclosing) - NSMaxRange(lineRange)))
            first = false
        }
        return out
    }

    /// Where a `$$` token sits in a quote: the quote line it opens on, or nil when
    /// the token is not preceded (on its line) by quote markers and blanks only.
    static func quoteLine(of token: MarkdownToken, in ns: NSString) -> QuoteSyntax.Line? {
        guard token.range.location < ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: token.range.location, length: 0)).location
        let l = QuoteSyntax.line(in: ns, at: lineStart)
        guard l.level > 0, token.range.location >= l.markerEnd else { return nil }
        var k = l.markerEnd
        while k < token.range.location {
            guard QuoteSyntax.isWS(ns.character(at: k)) else { return nil }
            k += 1
        }
        return l
    }

    /// `range` with the spans of `tokens` cut out — what inline parsing of a
    /// quote block covers (a formula's `\{` must not become an escape).
    static func inlineSegments(of range: NSRange, excluding tokens: [MarkdownToken]) -> [NSRange] {
        guard !tokens.isEmpty else { return [range] }
        var out: [NSRange] = []
        var cursor = range.location
        for t in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            if t.range.location > cursor {
                out.append(NSRange(location: cursor, length: t.range.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(t.range))
        }
        if cursor < NSMaxRange(range) {
            out.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return out
    }

    /// First `$$` with both characters in `from ..< to`.
    private static func doubleDollar(in ns: NSString, from: Int, to: Int) -> Int? {
        let start = max(0, from)
        guard to - start >= 2 else { return nil }
        let r = ns.range(of: "$$", options: .literal, range: NSRange(location: start, length: to - start))
        return r.location == NSNotFound ? nil : r.location
    }

    private static func token(open: Int, close: Int) -> MarkdownToken {
        MarkdownToken(kind: .blockLatex,
                      range: NSRange(location: open, length: close + 2 - open),
                      contentRange: NSRange(location: open + 2, length: close - open - 2),
                      markerRanges: [NSRange(location: open, length: 2), NSRange(location: close, length: 2)])
    }
}

// MARK: - Callouts

/// One callout type: Obsidian's names and aliases, colours and icons.
struct CalloutType: Equatable {
    /// Canonical name (`note`, `warning`, …); unknown types fall back to `note`'s look.
    let name: String
    let color: NSColor
    /// SF Symbol standing in for Obsidian's Lucide icon.
    let symbol: String

    static func == (a: CalloutType, b: CalloutType) -> Bool { a.name == b.name }

    /// Obsidian's default palette (RGB); blue and purple are lighter in dark mode, as there.
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let red = rgb(233, 49, 71)
    static let orange = rgb(236, 117, 0)
    static let green = rgb(8, 185, 78)
    static let cyan = rgb(0, 191, 188)
    static let blue = dynamic(light: rgb(8, 109, 221), dark: rgb(2, 122, 255))
    static let purple = dynamic(light: rgb(120, 82, 238), dark: rgb(168, 130, 255))
    static let gray = rgb(158, 158, 158)

    private static let table: [String: (name: String, color: NSColor, symbol: String)] = {
        var t: [String: (String, NSColor, String)] = [:]
        func add(_ names: [String], _ color: NSColor, _ symbol: String) {
            for n in names { t[n] = (names[0], color, symbol) }
        }
        add(["note"], blue, "pencil")
        add(["abstract", "summary", "tldr"], cyan, "list.clipboard")
        add(["info"], blue, "info.circle")
        add(["todo"], blue, "checkmark.circle")
        add(["tip", "hint", "important"], cyan, "flame")
        add(["success", "check", "done"], green, "checkmark")
        add(["question", "help", "faq"], orange, "questionmark.circle")
        add(["warning", "caution", "attention"], orange, "exclamationmark.triangle")
        add(["failure", "fail", "missing"], red, "xmark")
        add(["danger", "error"], red, "bolt")
        add(["bug"], red, "ladybug")
        add(["example"], purple, "list.bullet")
        add(["quote", "cite"], gray, "quote.opening")
        return t
    }()

    static func resolve(_ raw: String) -> CalloutType {
        let key = raw.lowercased()
        let entry = table[key] ?? table["note"]!
        return CalloutType(name: entry.name, color: entry.color, symbol: entry.symbol)
    }
}

/// A callout's first line: `[!type]`, the optional fold sign, the title.
struct CalloutHeader: Equatable {
    let type: CalloutType
    /// The type as written (`EXAMPLE`, `faq` …).
    let typeText: String
    /// `[!type]`, fold sign and the blanks up to the title (or the line end).
    let markerRange: NSRange
    /// The written title, trimmed; nil when none.
    let titleRange: NSRange?

    /// What Obsidian shows when no title is written: the type as written, first letter capitalised.
    var defaultTitle: String {
        guard let f = typeText.first else { return "" }
        return f.uppercased() + typeText.dropFirst().lowercased()
    }

    /// `[!type]` (+/-) (title) at `from` ..< `to`; nil when the content is no callout header.
    static func parse(_ ns: NSString, from: Int, to: Int) -> CalloutHeader? {
        var p = from
        while p < to, QuoteSyntax.isWS(ns.character(at: p)) { p += 1 }
        guard p + 3 < to, ns.character(at: p) == 0x5B /* [ */, ns.character(at: p + 1) == 0x21 /* ! */ else { return nil }
        var q = p + 2
        while q < to {
            let c = ns.character(at: q)
            let isName = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2D /* - */ || c == 0x5F /* _ */
            guard isName else { break }
            q += 1
        }
        guard q > p + 2, q < to, ns.character(at: q) == 0x5D /* ] */ else { return nil }
        let typeText = ns.substring(with: NSRange(location: p + 2, length: q - p - 2))
        var r = q + 1
        if r < to, ns.character(at: r) == 0x2B /* + */ || ns.character(at: r) == 0x2D /* - */ { r += 1 }
        // Anything but a blank right after `]` / the fold sign: `[!note]x` is no header.
        guard r == to || QuoteSyntax.isWS(ns.character(at: r)) else { return nil }
        while r < to, QuoteSyntax.isWS(ns.character(at: r)) { r += 1 }
        var titleEnd = to
        while titleEnd > r, QuoteSyntax.isWS(ns.character(at: titleEnd - 1)) { titleEnd -= 1 }
        return CalloutHeader(type: CalloutType.resolve(typeText),
                             typeText: typeText,
                             markerRange: NSRange(location: p, length: r - p),
                             titleRange: titleEnd > r ? NSRange(location: r, length: titleEnd - r) : nil)
    }
}

/// How one quote line lays out: its levels (callout or plain), whether each
/// level carries on to the next line, the callout header it opens.
struct QuoteLineLayout: Equatable {
    let line: QuoteSyntax.Line
    /// Per level, outermost first: the callout type when that level is a callout. `count == line.level`.
    let levels: [CalloutType?]
    /// Per level: the next line of the block keeps this level open.
    let continues: [Bool]
    /// The callout this line opens (its innermost level), if any.
    let header: CalloutHeader?
    let isLastInBlock: Bool

    /// A callout ends on this line (bottom padding goes after it).
    var calloutEnds: Bool {
        zip(levels, continues).contains { $0.0 != nil && !$0.1 }
    }
    /// The innermost level is a callout: the line's text reads as callout body (not muted).
    var innermostCallout: CalloutType? { levels.last ?? nil }
    var hasCallout: Bool { levels.contains { $0 != nil } }

    /// Where the line's text starts: past one gutter slot per level, plus half a slot.
    var textIndent: CGFloat {
        let slot = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        return CGFloat(line.level) * slot + slot * 0.5
    }

    /// Spacing below the line: the paragraph spacing after a quote's last line,
    /// plus a callout's bottom padding when one ends here, plus a little room
    /// under a callout's title when its body follows.
    func spacingBelow(baseParagraphSpacing: CGFloat, padding: CGFloat) -> CGFloat {
        let titleGap: CGFloat = header != nil && continues.last == true ? round(padding * 0.6) : 0
        return (isLastInBlock ? baseParagraphSpacing : 0) + (calloutEnds ? padding : 0) + titleGap
    }
}

enum CalloutScan {

    /// Layout of every line of one blockquote block (`range` = the block).
    /// Without `callouts`, every level is plain.
    static func layout(of range: NSRange, in ns: NSString, callouts: Bool = true) -> [QuoteLineLayout] {
        let lines = QuoteSyntax.lines(in: ns, range: range).filter { $0.level > 0 }
        let hasMarker = callouts && ns.range(of: "[!", options: [], range: range).location != NSNotFound
        var stack: [CalloutType?] = []
        var out: [QuoteLineLayout] = []
        out.reserveCapacity(lines.count)
        for (i, l) in lines.enumerated() {
            let opened = stack.count
            if l.level < stack.count { stack.removeLast(stack.count - l.level) }
            var header: CalloutHeader?
            if l.level > opened {
                while stack.count < l.level { stack.append(nil) }
                if hasMarker, let h = CalloutHeader.parse(ns, from: l.markerEnd, to: l.contentEnd) {
                    stack[l.level - 1] = h.type
                    header = h
                }
            }
            let nextLevel = i + 1 < lines.count ? lines[i + 1].level : 0
            out.append(QuoteLineLayout(line: l, levels: stack,
                                       continues: (0..<l.level).map { nextLevel >= $0 + 1 },
                                       header: header,
                                       isLastInBlock: i + 1 == lines.count))
        }
        return out
    }

    /// Layout of the quote line at `lineStart` alone (its block is found around it).
    static func layout(ofLineAt lineStart: Int, in ns: NSString, callouts: Bool = true) -> QuoteLineLayout? {
        guard let block = QuoteSyntax.blockRange(around: lineStart, in: ns) else { return nil }
        return layout(of: block, in: ns, callouts: callouts).first { $0.line.range.location == lineStart }
    }

    /// `[!type]` markers of lines whose content starts like a callout header —
    /// without the level bookkeeping (a header that does not open its level is
    /// only kept out of the incomplete-link colouring, which is harmless).
    static func headerMarkers(in range: NSRange, in ns: NSString) -> [NSRange] {
        guard ns.range(of: "[!", options: [], range: range).location != NSNotFound else { return [] }
        return QuoteSyntax.lines(in: ns, range: range).compactMap { l in
            l.level > 0 ? CalloutHeader.parse(ns, from: l.markerEnd, to: l.contentEnd)?.markerRange : nil
        }
    }

    /// Does any line of the block open a callout?
    static func hasCallout(_ range: NSRange, in ns: NSString) -> Bool {
        guard ns.range(of: "[!", options: [], range: range).location != NSNotFound else { return false }
        return layout(of: range, in: ns).contains { $0.header != nil }
    }
}

/// Per-line drawing info for the fragment (`.blockquoteDecoration`): each
/// level's callout colour (nil = plain bar) and whether the level runs on into
/// the next line. On a fragment's last line, a level that runs on reaches down
/// through all of the line's paragraph spacing; one that ends stops `gapBelow`
/// short of it — the part of the spacing that is the gap after the quote, not
/// room inside it (a callout's bottom padding, a formula preview).
final class QuoteLineDecoration: NSObject {
    let colors: [NSColor?]
    let continues: [Bool]
    let gapBelow: CGFloat

    private init(colors: [NSColor?], continues: [Bool], gapBelow: CGFloat) {
        self.colors = colors
        self.continues = continues
        self.gapBelow = gapBelow
    }

    private struct Key: Hashable {
        let types: [String?]
        let continues: [Bool]
        let gapBelow: CGFloat
    }
    private static let lock = NSLock()
    private static var interned: [Key: QuoteLineDecoration] = [:]

    /// One shared instance per distinct decoration: the text storage compares
    /// neighbouring attribute runs constantly, and equal-by-identity is the cheap case.
    static func make(levels: [CalloutType?], continues: [Bool], gapBelow: CGFloat) -> QuoteLineDecoration {
        let key = Key(types: levels.map { $0?.name }, continues: continues, gapBelow: gapBelow)
        lock.lock()
        defer { lock.unlock() }
        if let known = interned[key] { return known }
        if interned.count > 512 { interned.removeAll() }
        let made = QuoteLineDecoration(colors: levels.map { $0?.color }, continues: continues, gapBelow: gapBelow)
        interned[key] = made
        return made
    }

    var hasCallout: Bool { colors.contains { $0 != nil } }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? QuoteLineDecoration else { return false }
        if o === self { return true }
        // Colours are the shared `CalloutType` constants: identity is enough.
        return o.gapBelow == gapBelow && o.continues == continues
            && o.colors.count == colors.count
            && zip(o.colors, colors).allSatisfy { $0.0 === $0.1 }
    }

    override var hash: Int {
        var h = Hasher()
        h.combine(continues)
        h.combine(gapBelow)
        h.combine(colors.map { $0 == nil })
        return h.finalize()
    }
}

/// The icon (and, with no written title, the type's name) a callout header shows
/// in place of `[!type]`. Drawn on demand so the colour follows light / dark.
enum CalloutHeaderImage {
    struct Result {
        let image: NSImage
        /// How far the image's bottom sits below the text baseline.
        let descent: CGFloat
    }

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    /// `title` = the default title to draw after the icon, or nil when the line has its own.
    static func image(type: CalloutType, title: String?, font: NSFont, titleFont: NSFont) -> Result? {
        let descent = -font.descender
        let key = "\(type.name)|\(title ?? "")|\(font.fontName)|\(font.pointSize)" as NSString
        if let cached = cache.object(forKey: key) { return Result(image: cached, descent: descent) }
        let height = ceil(font.ascender - font.descender)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.92, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: type.symbol, accessibilityDescription: type.name)?
            .withSymbolConfiguration(symbolConfig) else { return nil }
        let gap = round(font.pointSize * 0.4)
        let titleLine = title.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [.font: titleFont]))
        }
        let titleWidth = titleLine.map { ceil(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let width = ceil(symbol.size.width) + gap + titleWidth

        let color = type.color
        let symbolSize = symbol.size
        let capHeight = font.capHeight
        let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { _ in
            // Resolved here, under the appearance being drawn for (blue / purple differ in dark mode).
            let resolved = color.usingColorSpace(.sRGB) ?? color
            let symbolY = descent + (capHeight - symbolSize.height) / 2
            symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [resolved]))?
                .draw(in: CGRect(x: 0, y: symbolY, width: symbolSize.width, height: symbolSize.height))
            if let title, let cg = NSGraphicsContext.current?.cgContext {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: title, attributes: [.font: titleFont, .foregroundColor: resolved]))
                cg.saveGState()
                cg.textMatrix = .identity
                cg.textPosition = CGPoint(x: ceil(symbolSize.width) + gap, y: descent)
                CTLineDraw(line, cg)
                cg.restoreGState()
            }
            return true
        }
        image.cacheMode = .never
        cache.setObject(image, forKey: key)
        return Result(image: image, descent: descent)
    }
}

extension NSAttributedString.Key {
    /// `QuoteLineDecoration` — on every character of a quote line.
    static let blockquoteDecoration = NSAttributedString.Key("BlockquoteDecoration")
    /// CGFloat — a centred block image is centred in the container minus this
    /// much on the left (a formula inside a quote centres within the quote).
    static let latexBlockCenterInset = NSAttributedString.Key("LatexBlockCenterInset")
}
