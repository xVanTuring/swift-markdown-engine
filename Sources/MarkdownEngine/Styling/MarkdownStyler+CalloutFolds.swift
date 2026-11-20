//
//  MarkdownStyler+CalloutFolds.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) Foldable callouts — `> [!type]-` (starts collapsed) and
//  `> [!type]+` (starts expanded). The header's icon gets a disclosure chevron
//  in front and is the click target (`CalloutFoldTarget`); a collapsed callout
//  shows its title line only. Runs LAST, so hiding the body wins over every
//  earlier pass (formula images, highlights, wiki-link labels). The caret on a
//  hidden line shows the body again — typing never goes into invisible text.
//  Folding is view state in `CalloutFolds`; the text is never edited.
//

import AppKit

extension MarkdownStyler {

    static func styleCalloutFolds(_ ctx: StylingContext, folds: CalloutFolds?, caret: Int, selection: NSRange?) -> [StyledRange] {
        let quoteStyle = ctx.configuration.blockquote
        guard quoteStyle.rendersCallouts else { return [] }
        let quotes = ctx.scoped(StylingContext.indexed(ctx.tokens, .blockquote))
        guard !quotes.isEmpty else { return [] }
        let ns = ctx.nsText

        // Same metrics the quote's own lines are styled with (`MarkdownASTStyler`).
        let baseLineHeight = ceil(ctx.baseFont.ascender - ctx.baseFont.descender + ctx.baseFont.leading)
        let baseParagraphSpacing = ceil(baseLineHeight * ctx.configuration.paragraph.spacingFactor)
        let pad = quoteStyle.calloutPadding
        let hiddenFont = ctx.latexMarkerFont
        let bold = NSFont(descriptor: ctx.baseFont.fontDescriptor.withSymbolicTraits(.bold), size: ctx.baseFont.pointSize)
            ?? .boldSystemFont(ofSize: ctx.baseFont.pointSize)

        func touchesCaret(_ r: NSRange) -> Bool {
            if NSLocationInRange(caret, r) { return true }
            if let selection, selection.length > 0, NSIntersectionRange(selection, r).length > 0 { return true }
            return false
        }

        var attrs: [StyledRange] = []
        var doneUpTo = -1   // quote lines are tokens of their own: one pass per quote, not per line
        for (_, token) in quotes {
            guard token.range.location >= doneUpTo,
                  let block = QuoteSyntax.blockRange(around: token.range.location, in: ns) else { continue }
            doneUpTo = NSMaxRange(block)
            guard ns.range(of: "[!", options: [], range: block).location != NSNotFound else { continue }
            let layouts = CalloutScan.layout(of: block, in: ns)
            for (hi, q) in layouts.enumerated() {
                guard let header = q.header, let sign = header.foldSign else { continue }
                let level = q.line.level
                var end = hi
                while end + 1 < layouts.count, layouts[end + 1].line.level >= level { end += 1 }
                let defaultCollapsed = sign == "-"
                let key = CalloutFolds.key(headerLine: q.line, in: ns)
                let collapsed = folds?.isCollapsed(key, defaultCollapsed: defaultCollapsed) ?? defaultCollapsed
                let body = end > hi
                    ? NSRange(location: layouts[hi + 1].line.range.location,
                              length: NSMaxRange(layouts[end].line.range) - layouts[hi + 1].line.range.location)
                    : nil
                let shown = !collapsed || body == nil || touchesCaret(body!)

                // Header: chevron + icon (+ the type's name), unless the caret shows its source.
                let headerLine = q.line.textRange
                let headerActive = NSLocationInRange(caret, headerLine) || caret == NSMaxRange(headerLine)
                if !headerActive, header.markerRange.length > 0,
                   let icon = CalloutHeaderImage.image(type: header.type,
                                                       title: header.titleRange == nil ? header.defaultTitle : nil,
                                                       font: ctx.baseFont, titleFont: bold,
                                                       chevron: shown ? .expanded : .collapsed) {
                    let anchor = NSRange(location: header.markerRange.location, length: 1)
                    let anchorChar = ns.substring(with: anchor)
                    attrs.append((anchor, [
                        .latexImage: icon.image,
                        .latexBounds: NSValue(rect: CGRect(x: 0, y: icon.descent,
                                                           width: icon.image.size.width, height: icon.image.size.height)),
                        .foregroundColor: NSColor.clear,
                        .font: hiddenFont,
                        .kern: icon.image.size.width - HeadingHelpers.textWidth(anchorChar, font: hiddenFont),
                        .calloutFoldTarget: CalloutFoldTarget(key: key, defaultCollapsed: defaultCollapsed),
                    ]))
                }
                guard !shown else { continue }

                // Collapsed: no room under the title, then every body line squeezed to nothing;
                // the last keeps the spacing below it (the box's bottom padding, the gap after the quote).
                let headerPara = NSMutableParagraphStyle()
                headerPara.firstLineHeadIndent = q.textIndent
                headerPara.headIndent = q.textIndent
                let headerHeight = baseLineHeight + quoteStyle.extraLineHeight + pad
                headerPara.minimumLineHeight = headerHeight
                headerPara.maximumLineHeight = headerHeight
                headerPara.paragraphSpacing = 0
                attrs.append((ns.paragraphRange(for: headerLine), [.paragraphStyle: headerPara]))

                for k in (hi + 1)...end {
                    let l = layouts[k].line
                    let p = NSMutableParagraphStyle()
                    p.maximumLineHeight = 1
                    p.minimumLineHeight = 0
                    p.paragraphSpacingBefore = 0
                    p.paragraphSpacing = k == end
                        ? layouts[k].spacingBelow(baseParagraphSpacing: baseParagraphSpacing, padding: pad)
                        : 0
                    p.lineBreakMode = .byClipping
                    attrs.append((ns.paragraphRange(for: l.textRange), [.paragraphStyle: p]))
                    guard l.textRange.length > 0 else { continue }
                    let text = ns.substring(with: l.textRange)
                    attrs.append((l.textRange, [
                        .foregroundColor: NSColor.clear,
                        .font: hiddenFont,
                        .kern: -hiddenRunKern(text, font: hiddenFont),
                        .baselineOffset: 0,
                        .latexImage: NSNull(),
                        .wikiLinkDisplay: NSNull(),
                        .markdownBlockBackground: NSNull(),
                        .backgroundColor: NSColor.clear,
                        .underlineStyle: 0,
                        .strikethroughStyle: 0,
                    ]))
                }
            }
        }
        return attrs
    }
}
