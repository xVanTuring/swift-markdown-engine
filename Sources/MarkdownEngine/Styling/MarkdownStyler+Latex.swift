//
//  MarkdownStyler+Latex.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Block ($$...$$) and inline ($...$) LaTeX formula rendering.
//

import AppKit
import Foundation

extension MarkdownStyler {

    // MARK: Block LaTeX $$...$$

    static func styleBlockLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        var quoteLayouts: [Int: QuoteLineLayout] = [:]   // quote line start → layout; one scan per quote block
        for (idx, token) in ctx.scoped(ctx.blockLatexIndexed) {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawLatexContent = ctx.nsText.substring(with: token.contentRange)
            // (fork: xVanTuring) A `$$` inside a block quote: the `>` markers of its continuation lines are the quote's.
            let quoteLine = QuoteMath.quoteLine(of: token, in: ctx.nsText)
            let latexContent = (quoteLine != nil ? QuoteMath.latexBody(rawLatexContent) : rawLatexContent)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            guard token.standaloneParagraphRange(in: ctx.nsText, allowingQuotePrefix: quoteLine != nil) != nil else { continue }

            let latexFontSize = HeadingHelpers.latexFontSize(for: token, headings: [], baseFont: ctx.baseFont)  // block $$ is never inside a heading

            if let quoteLine {
                styleQuoteBlockLatex(token: token, quoteLine: quoteLine, rawContent: rawLatexContent, latex: latexContent,
                                     isActive: isActive, fontSize: latexFontSize, layouts: &quoteLayouts,
                                     ctx: ctx, attrs: &attrs)
                continue
            }

            if isActive {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                let style = ctx.configuration.blockLatex
                if style.showsPreviewWhileEditing, !latexContent.isEmpty,
                   let entry = ctx.services.latex.render(
                       latex: latexContent,
                       mode: .display,
                       fontSize: latexFontSize,
                       theme: ctx.configuration.theme
                   ) {
                    appendLivePreview(for: token, entry: entry, style: style, ctx: ctx, attrs: &attrs)
                }
            } else if !latexContent.isEmpty,
                      let entry = ctx.services.latex.render(
                          latex: latexContent,
                          mode: .display,
                          fontSize: latexFontSize,
                          theme: ctx.configuration.theme
                      ) {
                _ = appendRenderedStandaloneBlock(
                    for: token,
                    rawContent: rawLatexContent,
                    image: entry.image,
                    imageBounds: CGRect(
                        x: 0,
                        y: entry.baselineOffset,
                        width: entry.size.width,
                        height: entry.size.height
                    ),
                    paragraphSpacingBefore: ctx.configuration.blockLatex.paragraphSpacingBefore,
                    paragraphSpacing: ctx.configuration.blockLatex.paragraphSpacing,
                    alignment: .center,
                    mode: .collapsedSource(markerTexts: ["$$", "$$"]),
                    ctx: ctx,
                    attrs: &attrs
                )
            } else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    /// (fork: xVanTuring) A block formula inside a block quote (`> $$…$$`, or `> $$` ⏎ `> …` ⏎ `> $$`).
    /// Laid out within the quote: centred in the quote's text column, the room above and
    /// below inside the line box (so the bar runs on unbroken), the spacing below the
    /// formula's last line what the quote wants there. Muted like the quote's text,
    /// except in a callout, whose text is in the body colour.
    private static func styleQuoteBlockLatex(
        token: MarkdownToken,
        quoteLine: QuoteSyntax.Line,
        rawContent: String,
        latex: String,
        isActive: Bool,
        fontSize: CGFloat,
        layouts: inout [Int: QuoteLineLayout],
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        let ns = ctx.nsText
        let quoteStyle = ctx.configuration.blockquote
        let style = ctx.configuration.blockLatex
        let lastLineStart = ns.lineRange(for: NSRange(location: max(token.range.location, NSMaxRange(token.range) - 1), length: 0)).location
        if layouts[quoteLine.range.location] == nil,
           let block = QuoteSyntax.blockRange(around: quoteLine.range.location, in: ns) {
            for q in CalloutScan.layout(of: block, in: ns, callouts: quoteStyle.rendersCallouts) {
                layouts[q.line.range.location] = q
            }
        }
        let first = layouts[quoteLine.range.location]
        let last = layouts[lastLineStart] ?? first

        // Same metrics the quote's own lines are styled with (`MarkdownASTStyler`).
        let baseLineHeight = ceil(ctx.baseFont.ascender - ctx.baseFont.descender + ctx.baseFont.leading)
        let baseParagraphSpacing = ceil(baseLineHeight * ctx.configuration.paragraph.spacingFactor)
        let quoteLineHeight = baseLineHeight + quoteStyle.extraLineHeight
        let slot = MarkdownTextLayoutFragment.blockquoteIndentPerLevel
        let indent = first?.textIndent ?? (CGFloat(quoteLine.level) * slot + slot * 0.5)
        let lastSpacing = last?.spacingBelow(baseParagraphSpacing: baseParagraphSpacing, padding: quoteStyle.calloutPadding)
            ?? baseParagraphSpacing

        var theme = ctx.configuration.theme
        if first?.innermostCallout == nil {
            theme.latexLightModeText = theme.mutedText
            theme.latexDarkModeText = theme.mutedText
        }
        guard !latex.isEmpty,
              let entry = ctx.services.latex.render(latex: latex, mode: .display, fontSize: fontSize, theme: theme) else {
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            return
        }
        // Narrower than the container by the quote's indent: shrink a formula that would not fit.
        // Room above and below the formula is `previewGap` each — inside a quote the block
        // spacing of a standalone `$$` (16 / 20 pt) would open holes in the box.
        var size = entry.size
        var baselineOffset = entry.baselineOffset
        let padding = ctx.layoutBridge?.firstTextContainer?.lineFragmentPadding ?? 5
        let available = effectiveContainerWidth(for: ctx) - indent - padding * 2
        if available > 0, size.width > available {
            let k = available / size.width
            size = CGSize(width: available, height: size.height * k)
            baselineOffset *= k
        }
        let imageBounds = CGRect(x: 0, y: baselineOffset, width: size.width, height: size.height)

        if isActive {
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            guard style.showsPreviewWhileEditing,
                  let paraRange = token.standaloneParagraphRange(in: ns, allowingQuotePrefix: true) else { return }
            var paragraphs: [(content: NSRange, full: NSRange)] = []
            ns.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, content, full, _ in
                paragraphs.append((content, full))
            }
            guard let lastPara = paragraphs.last, lastPara.content.length > 0 else { return }
            // The source lines keep the quote's own paragraph styles; the last one makes room for the preview.
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = indent
            para.headIndent = indent
            para.minimumLineHeight = quoteLineHeight
            para.maximumLineHeight = quoteLineHeight
            para.paragraphSpacing = size.height + style.previewGap * 2 + lastSpacing
            attrs.append((lastPara.full, [.paragraphStyle: para]))
            var previewAttrs: [NSAttributedString.Key: Any] = [
                .latexImage: entry.image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: quoteLineHeight + style.previewGap,
            ]
            if style.centersPreview {
                previewAttrs[.latexBlockCentered] = true
                previewAttrs[.latexBlockCenterInset] = indent
            }
            // Hung on the last line's text after its `>` markers: a preview that is not
            // centred starts where that text starts, at the quote's column.
            let lastLine = QuoteSyntax.line(in: ns, at: lastPara.full.location)
            let anchorStart = min(max(lastLine.markerEnd, lastPara.content.location), NSMaxRange(lastPara.content) - 1)
            attrs.append((NSRange(location: anchorStart, length: NSMaxRange(lastPara.content) - anchorStart), previewAttrs))
            return
        }

        _ = appendRenderedStandaloneBlock(
            for: token,
            rawContent: rawContent,
            image: entry.image,
            imageBounds: imageBounds,
            paragraphSpacingBefore: 0,
            paragraphSpacing: 0,
            alignment: .center,
            mode: .collapsedSource(markerTexts: ["$$", "$$"]),
            quote: QuoteBlockLayout(indent: indent,
                                    minimumLineHeight: ceil(size.height + style.previewGap * 2),
                                    lastLineSpacing: lastSpacing),
            ctx: ctx,
            attrs: &attrs
        )
    }

    /// Source stays visible; the rendered formula is drawn in the space reserved
    /// below the LAST source line. A multi-line block spans several paragraphs
    /// and each paragraph's fragment would draw the image, so only the last one
    /// carries it (and the bottom spacing); the first carries the top spacing.
    private static func appendLivePreview(
        for token: MarkdownToken,
        entry: LatexRenderResult,
        style: BlockLatexStyle,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return }
        var paragraphs: [(content: NSRange, full: NSRange)] = []
        ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, content, full, _ in
            paragraphs.append((content, full))
        }
        guard let last = paragraphs.last, last.content.length > 0 else { return }

        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        let imageBounds = CGRect(x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)

        for (i, p) in paragraphs.enumerated() {
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = baseLineHeight
            para.maximumLineHeight = baseLineHeight
            if i == 0 { para.paragraphSpacingBefore = style.paragraphSpacingBefore }
            if i == paragraphs.count - 1 {
                para.paragraphSpacing = entry.size.height + style.previewGap + style.paragraphSpacing
            }
            attrs.append((p.full, [.paragraphStyle: para]))
        }
        var previewAttrs: [NSAttributedString.Key: Any] = [
            .latexImage: entry.image,
            .latexBounds: NSValue(rect: imageBounds),
            .latexIsBlock: true,
            .latexBlockOffsetY: baseLineHeight + style.previewGap
        ]
        if style.centersPreview { previewAttrs[.latexBlockCentered] = true }
        attrs.append((last.content, previewAttrs))
    }

    // MARK: Inline LaTeX $formula$

    static func styleInlineLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        // Tables render their own cell contents (including `$…$`) into a single
        // image via `formattedCellString` + `collapsedSource`. If we also tag
        // the source-text `$x^2$` with a `.latexImage` attribute, the renderer
        // draws that tiny inline image on the collapsed 1pt source line under
        // the table — visible as a stray dot. Skip inline LaTeX inside a
        // table; the table image already covers it.
        let scopedLatex = ctx.scoped(ctx.inlineLatexIndexed)
        guard !scopedLatex.isEmpty else { return attrs }
        // Containers that ENCLOSE an in-scope formula must overlap the scope, so
        // scope-slicing these is exact; built once, not per formula.
        let tableRanges = ctx.scoped(ctx.tableIndexed).map { $0.token.range }
        // Quote lines mute their text via foregroundColor, which the LaTeX *image* ignores — render it in mutedText instead so it matches the grey.
        let blockquoteRanges = MarkdownStyler.StylingContext.indexed(ctx.tokens, .blockquote).map { $0.token.range }
        // (fork: xVanTuring) …except in a callout, whose text keeps the body colour. One scan per quote block.
        var calloutLines: [Int: Bool] = [:]   // quote line start → its innermost level is a callout
        func inCallout(_ location: Int) -> Bool {
            guard ctx.configuration.blockquote.rendersCallouts else { return false }
            let lineStart = ctx.nsText.lineRange(for: NSRange(location: location, length: 0)).location
            if let known = calloutLines[lineStart] { return known }
            if let block = QuoteSyntax.blockRange(around: lineStart, in: ctx.nsText) {
                for q in CalloutScan.layout(of: block, in: ctx.nsText) {
                    calloutLines[q.line.range.location] = q.innermostCallout != nil
                }
            }
            return calloutLines[lineStart] ?? false
        }
        // Built once, not re-scanned per formula (latexFontSize was O(#latex × #tokens)).
        let headings = ctx.scoped(MarkdownStyler.StylingContext.indexed(ctx.tokens, .heading)).map { $0.token }
        // Each textWidth is a CoreText measurement; the "$" marker width is
        // loop-invariant (fonts constant) and firstChar/restText repeat massively (2
        // distinct formulas × 1,594 tokens). Hoisting + memoizing removes all per-formula
        // width measurement — ENG-8g2b self ~186ms→~152ms on the 346k note (Debug).
        let tinyDollarWidth = HeadingHelpers.textWidth("$", font: ctx.latexMarkerFont)
        var markerFontWidthCache: [String: CGFloat] = [:]  // all measured with latexMarkerFont
        func markerFontWidth(_ s: String) -> CGFloat {
            if let cached = markerFontWidthCache[s] { return cached }
            let w = HeadingHelpers.textWidth(s, font: ctx.latexMarkerFont)
            markerFontWidthCache[s] = w
            return w
        }
        for (idx, token) in scopedLatex {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if tableRanges.contains(where: { tableRange in
                token.range.location >= tableRange.location
                    && NSMaxRange(token.range) <= NSMaxRange(tableRange)
            }) { continue }

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            let isActive = ctx.activeTokenIndices.contains(idx)
            let latexContent = ctx.nsText.substring(with: token.contentRange)
            let latexFontSize = HeadingHelpers.latexFontSize(for: token, headings: headings, baseFont: ctx.baseFont)

            if isActive {
                for markerRange in token.markerRanges {
                    attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
            } else {
                var renderTheme = ctx.configuration.theme
                if blockquoteRanges.contains(where: { NSLocationInRange(token.range.location, $0) }),
                   !inCallout(token.range.location) {
                    renderTheme.latexLightModeText = renderTheme.mutedText
                    renderTheme.latexDarkModeText = renderTheme.mutedText
                }
                if let entry = ctx.services.latex.render(
                    latex: latexContent,
                    mode: .inline,
                    fontSize: latexFontSize,
                    theme: renderTheme
                ) {
                    let imageBounds = CGRect(x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)
                    let contentLength = token.contentRange.length

                    if contentLength > 0 {
                        let firstCharRange = NSRange(location: token.contentRange.location, length: 1)
                        let firstChar = ctx.nsText.substring(with: firstCharRange)
                        attrs.append((firstCharRange, [
                            .latexImage: entry.image,
                            .latexBounds: NSValue(rect: imageBounds),
                            .foregroundColor: NSColor.clear,
                            .font: ctx.latexMarkerFont,
                            .kern: entry.size.width - markerFontWidth(firstChar)
                        ]))

                        if contentLength > 1 {
                            let restRange = NSRange(location: token.contentRange.location + 1, length: contentLength - 1)
                            let restText = ctx.nsText.substring(with: restRange)
                            attrs.append((restRange, [
                                .foregroundColor: NSColor.clear,
                                .font: ctx.latexMarkerFont,
                                .kern: -markerFontWidth(restText)
                            ]))
                        }
                    }

                    // The formula image is drawn over the line, it is not a glyph, so by
                    // itself it lends the line no height: a fraction or a `\lim` subscript
                    // ran into the next line, and on the last line was cut off by the view.
                    // The two hidden `$` carry the image's extent instead — raised to its
                    // top and dropped to its bottom — so the line box grows to hold it.
                    let textScale = latexFontSize / ctx.baseFont.pointSize
                    let textAscent = ctx.baseFont.ascender * textScale
                    let textDescent = -ctx.baseFont.descender * textScale
                    let formulaDescent = entry.baselineOffset
                    let formulaAscent = entry.size.height - formulaDescent

                    let openMarker = token.markerRanges[0]
                    var openAttrs: [NSAttributedString.Key: Any] = [
                        .font: ctx.latexMarkerFont,
                        .foregroundColor: NSColor.clear,
                        .kern: -tinyDollarWidth
                    ]
                    if formulaAscent > textAscent {
                        openAttrs[.baselineOffset] = formulaAscent - ctx.latexMarkerFont.ascender
                    }
                    attrs.append((openMarker, openAttrs))
                    // Hidden by SIZE like the rest of the source, not only by a clear colour:
                    // NSTextView.selectedTextAttributes carries a `selectedTextColor` that
                    // repaints selected glyphs opaque, so a full-size `$` came back under the
                    // highlight, drawn over the next character. It used to stay full size to
                    // lend the line its text descent; dropping it by that descent does the same,
                    // so a line holding only the formula keeps the baseline of one with text.
                    let closeMarker = token.markerRanges[1]
                    attrs.append((closeMarker, [
                        .font: ctx.latexMarkerFont,
                        .foregroundColor: NSColor.clear,
                        .kern: -tinyDollarWidth,
                        .baselineOffset: -max(textDescent, formulaDescent)
                    ]))
                } else {
                    for markerRange in token.markerRanges {
                        attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                    }
                }
            }
        }
        return attrs
    }
}
