//
//  MarkdownStyler.swift
//  Nodes
//
//  Created by Luca Chen on 18.02.26.
//

// Applies the Markdown look (bold, links, code, headings, etc.) based on
// the current text and cursor position.
import AppKit
import Foundation

// MARK: - Private Regexes used only by styling
private extension MarkdownStyler {
    static let linkDataDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    static let incompleteLinkRegexes: [NSRegularExpression] = [
        "\\[\\]",
        "\\[\\[\\]\\]",
        "\\[[^\\]\\r\\n]*$",
        "\\[[^\\]\\r\\n]+\\](?!\\()",
        "\\[[^\\]\\r\\n]+\\]\\([^)\\r\\n]*$",
        "\\[[^\\]\\r\\n]+\\]\\(\\)"
    ].map { try! NSRegularExpression(pattern: $0) }
    static let taskListRegex: NSRegularExpression = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-•]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
        options: [.anchorsMatchLines]
    )
}

// MARK: - Styling Context
private extension MarkdownStyler {
    struct StylingContext {
        let text: String
        let nsText: NSString
        let fullRange: NSRange
        // When non-nil, scan-based sub-methods only scan these ranges.
        let scopedRanges: [NSRange]?
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let activeTokenIndices: Set<Int>
        let baseFont: NSFont
        let baseDescriptor: NSFontDescriptor
        let fontName: String
        let caretLocation: Int
        let layoutBridge: LayoutBridge?
        let baseDefaultLineHeight: CGFloat
        let baseParagraphSpacing: CGFloat
        let codeFont: NSFont
        let codeBackgroundColor: NSColor
        let codeParagraphStyle: NSParagraphStyle
        let hiddenMarkerFont: NSFont
        let inlineMarkerFont: NSFont
        let latexMarkerFont: NSFont
        let configuration: MarkdownEditorConfiguration

        var services: MarkdownEditorServices { configuration.services }
    }
}

typealias StyledRange = (range: NSRange, attributes: [NSAttributedString.Key: Any])

// MARK: - Public API
enum MarkdownStyler {

    static func styleAttributes(
        text: String,
        fontName: String,
        fontSize: CGFloat,
        layoutBridge: LayoutBridge? = nil,
        caretLocation: Int,
        activeTokenIndices: Set<Int>,
        nodeLinkIDProvider: (NSRange) -> String? = { _ in nil },
        precomputedTokens: [MarkdownToken]? = nil,
        scopedRanges: [NSRange]? = nil,
        configuration: MarkdownEditorConfiguration = .default
    ) -> [StyledRange] {
        let tokens = precomputedTokens ?? MarkdownTokenizer.parseTokens(in: text)
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let codeTokens = tokens.filter { $0.kind == .codeBlock || $0.kind == .inlineCode }
        let baseFont = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let baseDefaultLineHeight = ceil(
            layoutBridge?.defaultLineHeight(for: baseFont)
            ?? (baseFont.ascender - baseFont.descender + baseFont.leading)
        )
        let baseParagraphSpacing = ceil(baseDefaultLineHeight * configuration.paragraph.spacingFactor)

        let codeFontSize = round(fontSize * configuration.codeBlock.fontSizeScale)
        let codeFont = configuration.services.syntaxHighlighter.codeFont(size: codeFontSize)
        let codeBackgroundColor = configuration.services.syntaxHighlighter.backgroundColor()
        let codeLineHeight: CGFloat = layoutBridge?.defaultLineHeight(for: codeFont)
            ?? (codeFont.ascender - codeFont.descender + codeFont.leading)
        let codeParagraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byCharWrapping
            style.lineSpacing = 0
            let codeBlockSpacing = configuration.codeBlock.paragraphSpacing
            let codeBlockIndent = configuration.codeBlock.horizontalIndent
            style.paragraphSpacingBefore = codeBlockSpacing
            style.paragraphSpacing = codeBlockSpacing
            style.headIndent = codeBlockIndent
            style.firstLineHeadIndent = codeBlockIndent
            style.tailIndent = -codeBlockIndent
            style.minimumLineHeight = ceil(codeLineHeight)
            style.maximumLineHeight = ceil(codeLineHeight)
            return style
        }()

        let hiddenMarkerSize = configuration.markers.hiddenMarkerFontSize
        let ctx = StylingContext(
            text: text,
            nsText: nsText,
            fullRange: fullRange,
            scopedRanges: scopedRanges,
            tokens: tokens,
            codeTokens: codeTokens,
            activeTokenIndices: activeTokenIndices,
            baseFont: baseFont,
            baseDescriptor: baseFont.fontDescriptor,
            fontName: fontName,
            caretLocation: caretLocation,
            layoutBridge: layoutBridge,
            baseDefaultLineHeight: baseDefaultLineHeight,
            baseParagraphSpacing: baseParagraphSpacing,
            codeFont: codeFont,
            codeBackgroundColor: codeBackgroundColor,
            codeParagraphStyle: codeParagraphStyle,
            hiddenMarkerFont: codeFont,
            inlineMarkerFont: NSFont.systemFont(ofSize: hiddenMarkerSize),
            latexMarkerFont: NSFont(name: fontName, size: hiddenMarkerSize)
                ?? NSFont.systemFont(ofSize: hiddenMarkerSize),
            configuration: configuration
        )

        var result: [StyledRange] = []
        let listsEnabled = configuration.lists.helpersEnabled
        result += MarkdownLists.paragraphAttributes(
            for: text,
            baseFont: baseFont,
            nsText: nsText,
            fullRange: fullRange,
            listsEnabled: listsEnabled,
            defaultLineHeight: baseDefaultLineHeight,
            defaultParagraphSpacing: baseParagraphSpacing,
            configuration: configuration
        )
        result += styleHeadings(ctx)
        result += styleEmphasis(ctx)
        result += styleAutoLinks(ctx)
        result += styleNodeLinks(ctx, nodeLinkIDProvider: nodeLinkIDProvider)
        result += styleImageEmbeds(ctx)
        result += styleMarkdownLinks(ctx)
        result += styleCodeBlocks(ctx)
        result += styleInlineCode(ctx)
        result += styleBlockLatex(ctx)
        result += styleInlineLatex(ctx)
        result += styleHorizontalRules(ctx)
        result += styleIncompleteLinkBrackets(ctx)
        result += styleTaskCheckboxes(ctx)
        result += shrinkInactiveMarkers(ctx)
        return result
    }
}

// MARK: - Sub-Methods
private extension MarkdownStyler {

    // MARK: Headings

    static func styleHeadings(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let headingTokens = ctx.tokens.filter { $0.kind == .heading }
        for token in headingTokens {
            let level = token.markerRanges.first?.length ?? 1
            let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
            let fontSize = ctx.baseFont.pointSize * multiplier
            let headingBase = NSFont(name: ctx.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
            let headingFont = NSFontManager.shared.convert(headingBase, toHaveTrait: .boldFontMask)

            let paraRange = ctx.nsText.paragraphRange(for: token.range)
            let headingLineHeight = ceil(layoutBridgeDefaultLineHeight(for: headingFont, using: ctx.layoutBridge)) + 1
            let headingPara = NSMutableParagraphStyle()
            headingPara.minimumLineHeight = headingLineHeight
            headingPara.maximumLineHeight = headingLineHeight
            let beforeEm = ctx.configuration.headings.topSpacingEm(for: level)
            headingPara.paragraphSpacingBefore = headingFont.pointSize * beforeEm
            headingPara.paragraphSpacing = ctx.baseParagraphSpacing
            attrs.append((paraRange, [.paragraphStyle: headingPara]))

            for markerRange in token.markerRanges {
                attrs.append((markerRange, [
                    .font: headingFont,
                    .foregroundColor: ctx.configuration.theme.headingMarker
                ]))
            }
            attrs.append((token.contentRange, [.font: headingFont]))
        }
        return attrs
    }

    // MARK: Bold / Italic / Bold+Italic

    static func styleEmphasis(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []

        // Bold+Italic
        for token in ctx.tokens where token.kind == .boldItalic {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let biDescriptor = ctx.baseDescriptor.withSymbolicTraits([.bold, .italic])
            let biFont = NSFont(descriptor: biDescriptor, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: [.boldFontMask, .italicFontMask])
            attrs.append((token.contentRange, [.font: biFont]))
        }

        // Bold
        for token in ctx.tokens where token.kind == .bold {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let boldDesc = ctx.baseDescriptor.withSymbolicTraits(.bold)
            let boldFont = NSFont(descriptor: boldDesc, size: ctx.baseFont.pointSize)
                ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .boldFontMask)
            attrs.append((token.contentRange, [.font: boldFont]))
        }

        // Italic
        for token in ctx.tokens where token.kind == .italic {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            if let headingToken = ctx.tokens.first(where: { $0.kind == .heading && NSLocationInRange(token.contentRange.location, $0.contentRange) }) {
                let level = headingToken.markerRanges.first?.length ?? 1
                let multiplier = ctx.configuration.headings.fontMultiplier(for: level)
                let headingBase = NSFont(name: ctx.fontName, size: ctx.baseFont.pointSize * multiplier)
                    ?? NSFont.systemFont(ofSize: ctx.baseFont.pointSize * multiplier)
                let biDescriptor = headingBase.fontDescriptor.withSymbolicTraits([.bold, .italic])
                let fontIt = NSFont(descriptor: biDescriptor, size: headingBase.pointSize)
                    ?? NSFontManager.shared.convert(headingBase, toHaveTrait: [.boldFontMask, .italicFontMask])
                attrs.append((token.contentRange, [.font: fontIt]))
            } else {
                let italicDesc = ctx.baseDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: ctx.baseFont.pointSize)
                    ?? NSFontManager.shared.convert(ctx.baseFont, toHaveTrait: .italicFontMask)
                attrs.append((token.contentRange, [.font: italicFont]))
            }
        }

        return attrs
    }

    // MARK: Auto-detected plain URLs

    static func styleAutoLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        guard let detector = MarkdownStyler.linkDataDetector else { return attrs }

        // Scope to edited paragraphs when provided; avoids full-doc URL scan per keystroke.
        let rangesToScan: [NSRange]
        if let scoped = ctx.scopedRanges, !scoped.isEmpty {
            rangesToScan = scoped.compactMap { range in
                let clipped = NSIntersectionRange(range, ctx.fullRange)
                return clipped.length > 0 ? clipped : nil
            }
        } else {
            rangesToScan = [ctx.fullRange]
        }

        for range in rangesToScan {
            detector.enumerateMatches(in: ctx.text, options: [], range: range) { match, _, _ in
                guard let match = match, let url = match.url else { return }
                if MarkdownDetection.isInsideCodeBlock(range: match.range, codeTokens: ctx.codeTokens) { return }
                attrs.append((match.range, [.link: url]))
            }
        }
        return attrs
    }

    // MARK: Node Links [[Name]]

    static func styleNodeLinks(_ ctx: StylingContext, nodeLinkIDProvider: (NSRange) -> String?) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (index, token) in ctx.tokens.enumerated() where token.kind == .nodeLink {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))
            let nodeName = ctx.nsText.substring(with: token.contentRange)
            let linkID = nodeLinkIDProvider(token.range)
            var contentAttributes: [NSAttributedString.Key: Any] = [:]
            if let linkID {
                contentAttributes[.nodeLinkID] = linkID
            }
            let isActive = ctx.activeTokenIndices.contains(index)
            // Check if the linked node actually exists, using whichever resolver
            // the embedder supplied via configuration.services.
            let nodeExists: Bool = {
                if let resolution = ctx.services.wikiLinks.resolve(displayName: nodeName, range: token.contentRange) {
                    return resolution.exists
                }
                return false
            }()
            if !isActive {
                if nodeExists {
                    contentAttributes[.link] = linkID ?? nodeName
                } else {
                    contentAttributes[.foregroundColor] = ctx.configuration.theme.disabledText
                }
            }
            if !contentAttributes.isEmpty {
                attrs.append((token.contentRange, contentAttributes))
            }
            for markerRange in token.markerRanges {
                attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
            }
        }
        return attrs
    }

    static func appendSecondaryMarkers(
        for token: MarkdownToken,
        to attrs: inout [StyledRange],
        theme: MarkdownEditorTheme
    ) {
        token.markerRanges.forEach {
            attrs.append(($0, [.foregroundColor: theme.mutedText]))
        }
    }

    private enum RenderedStandaloneBlockMode {
        case collapsedSource(markerTexts: [String])
        case visibleSource(imageGap: CGFloat)
    }

    private static func appendRenderedStandaloneBlock(
        for token: MarkdownToken,
        rawContent: String,
        image: NSImage,
        imageBounds: CGRect,
        paragraphSpacingBefore: CGFloat,
        paragraphSpacing: CGFloat,
        alignment: NSTextAlignment,
        mode: RenderedStandaloneBlockMode,
        ctx: StylingContext,
        attrs: inout [StyledRange]
    ) -> Bool {
        guard let paraRange = token.standaloneParagraphRange(in: ctx.nsText) else { return false }

        let para = NSMutableParagraphStyle()
        let baseLineHeight = layoutBridgeDefaultLineHeight(for: ctx.baseFont, using: ctx.layoutBridge)
        para.paragraphSpacingBefore = max(para.paragraphSpacingBefore, paragraphSpacingBefore)
        para.alignment = alignment

        switch mode {
        case .collapsedSource(let markerTexts):
            let neededHeight = max(para.minimumLineHeight, imageBounds.height, baseLineHeight)
            para.minimumLineHeight = neededHeight
            para.maximumLineHeight = max(para.maximumLineHeight, neededHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, paragraphSpacing)

            let collapsedPara = NSMutableParagraphStyle()
            collapsedPara.maximumLineHeight = 1
            collapsedPara.paragraphSpacing = 0
            collapsedPara.paragraphSpacingBefore = 0

            let leadingWhitespaceUnits = rawContent.utf16.prefix { codeUnit in
                guard let scalar = UnicodeScalar(UInt32(codeUnit)) else { return false }
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
            }.count
            let contentEnd = NSMaxRange(token.contentRange)
            let anchorLocation = min(token.contentRange.location + leadingWhitespaceUnits, contentEnd - 1)

            var paragraphAttributes: [StyledRange] = []
            ctx.nsText.enumerateSubstrings(in: paraRange, options: .byParagraphs) { _, _, enclosingRange, _ in
                if NSLocationInRange(anchorLocation, enclosingRange) {
                    paragraphAttributes.append((enclosingRange, [.paragraphStyle: para]))
                } else {
                    paragraphAttributes.append((enclosingRange, [.paragraphStyle: collapsedPara]))
                }
            }
            attrs.append(contentsOf: paragraphAttributes)

            if leadingWhitespaceUnits > 0 {
                let leadingRange = NSRange(location: token.contentRange.location, length: leadingWhitespaceUnits)
                let leadingText = ctx.nsText.substring(with: leadingRange)
                attrs.append((leadingRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(leadingText, font: ctx.latexMarkerFont)
                ]))
            }

            let anchorRange = NSRange(location: anchorLocation, length: 1)
            let anchorChar = ctx.nsText.substring(with: anchorRange)
            attrs.append((anchorRange, [
                .latexImage: image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .foregroundColor: NSColor.clear,
                .font: ctx.latexMarkerFont,
                .kern: imageBounds.width - HeadingHelpers.textWidth(anchorChar, font: ctx.latexMarkerFont)
            ]))

            let trailingStart = anchorLocation + 1
            let trailingLength = contentEnd - trailingStart
            if trailingLength > 0 {
                let trailingRange = NSRange(location: trailingStart, length: trailingLength)
                let trailingText = ctx.nsText.substring(with: trailingRange)
                attrs.append((trailingRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(trailingText, font: ctx.latexMarkerFont)
                ]))
            }

            for (index, markerRange) in token.markerRanges.enumerated() {
                let markerText = markerTexts.indices.contains(index)
                    ? markerTexts[index]
                    : ctx.nsText.substring(with: markerRange)
                attrs.append((markerRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(markerText, font: ctx.latexMarkerFont)
                ]))
            }

            // Hide whitespace between paragraph start and token start
            // (e.g. a space before "![[") so it doesn't affect line layout.
            let preTokenLength = token.range.location - paraRange.location
            if preTokenLength > 0 {
                let preTokenRange = NSRange(location: paraRange.location, length: preTokenLength)
                let preTokenText = ctx.nsText.substring(with: preTokenRange)
                attrs.append((preTokenRange, [
                    .foregroundColor: NSColor.clear,
                    .font: ctx.latexMarkerFont,
                    .kern: -HeadingHelpers.textWidth(preTokenText, font: ctx.latexMarkerFont)
                ]))
            }

        case .visibleSource(let imageGap):
            para.minimumLineHeight = max(para.minimumLineHeight, baseLineHeight)
            para.maximumLineHeight = max(para.maximumLineHeight, baseLineHeight)
            para.paragraphSpacing = max(para.paragraphSpacing, imageBounds.height + imageGap + paragraphSpacing)

            attrs.append((paraRange, [.paragraphStyle: para]))
            attrs.append((token.range, [
                .latexImage: image,
                .latexBounds: NSValue(rect: imageBounds),
                .latexIsBlock: true,
                .latexBlockOffsetY: baseLineHeight + imageGap
            ]))
            appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
        }

        return true
    }

    // MARK: Image Embeds ![[Name]]

    static func styleImageEmbeds(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .imageEmbed {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawContent = ctx.nsText.substring(with: token.contentRange)
            guard let reference = ImageEmbedReference(content: rawContent) else {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                continue
            }

            if let image = EmbeddedImageCache.shared.image(for: reference, services: ctx.services) {
                let imageEmbedConfig = ctx.configuration.imageEmbed
                // Determine max width from text container
                let maxWidth: CGFloat = {
                    if let tc = ctx.layoutBridge?.firstTextContainer {
                        let w = tc.containerSize.width - tc.lineFragmentPadding * 2
                        if w > 0 && w < imageEmbedConfig.unreasonableMaxWidth { return w }
                    }
                    return imageEmbedConfig.fallbackMaxWidth
                }()

                let minWidth = imageEmbedConfig.minimumWidth
                let imageSize = image.size
                let targetWidth: CGFloat
                if let rw = reference.requestedWidth, rw > 0 {
                    targetWidth = min(max(rw, minWidth), maxWidth)
                } else {
                    targetWidth = min(imageSize.width, maxWidth)
                }
                let scale = targetWidth / imageSize.width
                let displayWidth = imageSize.width * scale
                let displayHeight = imageSize.height * scale
                let imageBounds = CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight)
                let rendered: Bool
                if isActive {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .visibleSource(imageGap: imageEmbedConfig.imageGap),
                        ctx: ctx,
                        attrs: &attrs
                    )
                } else {
                    rendered = appendRenderedStandaloneBlock(
                        for: token,
                        rawContent: rawContent,
                        image: image,
                        imageBounds: imageBounds,
                        paragraphSpacingBefore: imageEmbedConfig.paragraphSpacing,
                        paragraphSpacing: imageEmbedConfig.paragraphSpacing,
                        alignment: .left,
                        mode: .collapsedSource(markerTexts: ["![[", "]]"]),
                        ctx: ctx,
                        attrs: &attrs
                    )
                }
                if !rendered {
                    appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
                }
            } else {
                // Image not found — show syntax with marker coloring (like broken link)
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            }
        }
        return attrs
    }

    // MARK: Markdown Links [Text](URL)

    static func styleMarkdownLinks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .link {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))
            let fullMatch = ctx.nsText.substring(with: token.range)
            if let urlStart = fullMatch.firstIndex(of: "("), let urlEnd = fullMatch.lastIndex(of: ")") {
                let rawUrl = String(fullMatch[fullMatch.index(after: urlStart)..<urlEnd])
                var urlCandidate = rawUrl
                if !urlCandidate.contains("://") {
                    urlCandidate = "https://\(urlCandidate)"
                }
                let isActive = ctx.activeTokenIndices.contains(idx)
                if let url = URL(string: urlCandidate) {
                    if isActive {
                        attrs.append((token.contentRange, [
                            .foregroundColor: ctx.configuration.theme.link.withAlphaComponent(ctx.configuration.link.activeLinkAlpha)
                        ]))
                    } else {
                        attrs.append((token.contentRange, [
                            .link: url,
                            .underlineStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: ctx.configuration.theme.link
                        ]))
                    }
                }
                for m in token.markerRanges {
                    attrs.append((m, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
            }
        }
        return attrs
    }

    // MARK: Fenced Code Blocks

    static func styleCodeBlocks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .codeBlock {
            let codeContent = ctx.nsText.substring(with: token.contentRange)
            let isActive = ctx.activeTokenIndices.contains(idx)
            let language = MarkdownTokenizer.extractLanguage(from: token, in: ctx.text)
            attrs.append((token.range, [
                .font: ctx.codeFont,
                .backgroundColor: ctx.codeBackgroundColor,
                .paragraphStyle: ctx.codeParagraphStyle
            ]))

            if !codeContent.isEmpty,
               let highlighted = ctx.services.syntaxHighlighter.highlight(code: codeContent, language: language) {
                highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { highlightAttrs, range, _ in
                    guard let foregroundColor = highlightAttrs[.foregroundColor] else { return }
                    let absoluteRange = NSRange(location: token.contentRange.location + range.location, length: range.length)
                    attrs.append((absoluteRange, [.foregroundColor: foregroundColor]))
                }
            }
            let markerAttributes: [NSAttributedString.Key: Any] = isActive
                ? [.foregroundColor: ctx.configuration.theme.mutedText, .font: ctx.codeFont]
                : [.foregroundColor: NSColor.clear, .font: ctx.hiddenMarkerFont]
            token.markerRanges.forEach { attrs.append(($0, markerAttributes)) }
        }
        return attrs
    }

    // MARK: Inline Code

    static func styleInlineCode(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for token in ctx.tokens where token.kind == .inlineCode {
            attrs.append((token.contentRange, [
                .font: ctx.codeFont,
                .backgroundColor: ctx.codeBackgroundColor
            ]))
            let inlineMarkerAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: ctx.configuration.theme.mutedText.withAlphaComponent(ctx.configuration.markers.inlineCodeMarkerAlpha),
                .font: ctx.inlineMarkerFont
            ]
            token.markerRanges.forEach { attrs.append(($0, inlineMarkerAttributes)) }
        }
        return attrs
    }

    // MARK: Block LaTeX $$...$$

    static func styleBlockLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let blockLatexTokens = ctx.tokens.enumerated().filter { $0.element.kind == .blockLatex }
        for (idx, token) in blockLatexTokens {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }
            let isActive = ctx.activeTokenIndices.contains(idx)
            let rawLatexContent = ctx.nsText.substring(with: token.contentRange)
            let latexContent = rawLatexContent.trimmingCharacters(in: .whitespacesAndNewlines)

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            guard token.standaloneParagraphRange(in: ctx.nsText) != nil else { continue }

            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)

            if isActive {
                appendSecondaryMarkers(for: token, to: &attrs, theme: ctx.configuration.theme)
            } else if !latexContent.isEmpty,
                      let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: ctx.configuration.theme) {
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

    // MARK: Inline LaTeX $formula$

    static func styleInlineLatex(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .inlineLatex {
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) { continue }

            attrs.append((token.range, [NSAttributedString.Key.spellingState: 0]))

            let isActive = ctx.activeTokenIndices.contains(idx)
            let latexContent = ctx.nsText.substring(with: token.contentRange)
            let latexFontSize = HeadingHelpers.latexFontSize(for: token, tokens: ctx.tokens, baseFont: ctx.baseFont)

            if isActive {
                for markerRange in token.markerRanges {
                    attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                }
            } else {
                if let entry = ctx.services.latex.render(latex: latexContent, fontSize: latexFontSize, theme: ctx.configuration.theme) {
                    let imageBounds = CGRect(x: 0, y: entry.baselineOffset, width: entry.size.width, height: entry.size.height)
                    let contentLength = token.contentRange.length
                    let tinyDollarWidth = HeadingHelpers.textWidth("$", font: ctx.latexMarkerFont)
                    let baseDollarWidth = HeadingHelpers.textWidth("$", font: ctx.baseFont)

                    if contentLength > 0 {
                        let firstCharRange = NSRange(location: token.contentRange.location, length: 1)
                        let firstChar = ctx.nsText.substring(with: firstCharRange)
                        attrs.append((firstCharRange, [
                            .latexImage: entry.image,
                            .latexBounds: NSValue(rect: imageBounds),
                            .foregroundColor: NSColor.clear,
                            .font: ctx.latexMarkerFont,
                            .kern: entry.size.width - HeadingHelpers.textWidth(firstChar, font: ctx.latexMarkerFont)
                        ]))

                        if contentLength > 1 {
                            let restRange = NSRange(location: token.contentRange.location + 1, length: contentLength - 1)
                            let restText = ctx.nsText.substring(with: restRange)
                            attrs.append((restRange, [
                                .foregroundColor: NSColor.clear,
                                .font: ctx.latexMarkerFont,
                                .kern: -HeadingHelpers.textWidth(restText, font: ctx.latexMarkerFont)
                            ]))
                        }
                    }

                    let openMarker = token.markerRanges[0]
                    attrs.append((openMarker, [
                        .font: ctx.latexMarkerFont,
                        .foregroundColor: NSColor.clear,
                        .kern: -tinyDollarWidth
                    ]))
                    let closeMarker = token.markerRanges[1]
                    attrs.append((closeMarker, [
                        .foregroundColor: NSColor.clear,
                        .kern: -baseDollarWidth
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

    // MARK: Horizontal Rules ---

    static func styleHorizontalRules(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let hrPattern = "^[ \\t]*-{3,}[ \\t]*$"
        if let hrRegex = try? NSRegularExpression(pattern: hrPattern, options: [.anchorsMatchLines]) {
            for hrMatch in hrRegex.matches(in: ctx.text, range: ctx.fullRange) {
                attrs.append((hrMatch.range, [.foregroundColor: NSColor.clear]))
                attrs.append((hrMatch.range, [
                    .strikethroughStyle: NSUnderlineStyle.thick.rawValue,
                    .strikethroughColor: ctx.configuration.theme.strikethroughColor
                ]))
                let rulePara = NSMutableParagraphStyle()
                attrs.append((hrMatch.range, [.paragraphStyle: rulePara]))
            }
        }
        return attrs
    }

    // MARK: Incomplete Link Brackets

    static func styleIncompleteLinkBrackets(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for regex in MarkdownStyler.incompleteLinkRegexes {
            for match in regex.matches(in: ctx.text, options: [], range: ctx.fullRange) {
                let matchRange = match.range
                if MarkdownDetection.isInsideCodeBlock(range: matchRange, codeTokens: ctx.codeTokens) { continue }
                let substring = ctx.nsText.substring(with: matchRange)
                for (i, char) in substring.enumerated() {
                    let location = matchRange.location + i
                    if char == "[" || char == "]" || char == "(" || char == ")" {
                        let markerRange = NSRange(location: location, length: 1)
                        attrs.append((markerRange, [.foregroundColor: ctx.configuration.theme.mutedText]))
                    } else {
                        let contentRange = NSRange(location: location, length: 1)
                        attrs.append((contentRange, [.foregroundColor: ctx.configuration.theme.incompleteLink.withAlphaComponent(ctx.configuration.link.incompleteLinkAlpha)]))
                    }
                }
            }
        }
        return attrs
    }

    // MARK: Task List Checkboxes

    static func styleTaskCheckboxes(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        let taskMatches = MarkdownStyler.taskListRegex.matches(in: ctx.text, options: [], range: ctx.fullRange)
        for match in taskMatches {
            let markerRange = match.range(at: 2)
            let spacerRange = match.range(at: 3)
            let checkboxRange = match.range(at: 4)
            if checkboxRange.location == NSNotFound { continue }
            if MarkdownDetection.isInsideCodeBlock(range: checkboxRange, codeTokens: ctx.codeTokens) { continue }
            let checkboxText = ctx.nsText.substring(with: checkboxRange)
            let isChecked = checkboxText.range(of: "[x]", options: [.caseInsensitive]) != nil
            if markerRange.location != NSNotFound {
                let syntaxStart = markerRange.location
                let syntaxEnd = checkboxRange.location + checkboxRange.length
                let syntaxRange = NSRange(location: syntaxStart, length: max(0, syntaxEnd - syntaxStart))
                var isActiveSyntax = NSLocationInRange(ctx.caretLocation, syntaxRange)
                if !isActiveSyntax && ctx.caretLocation == syntaxEnd {
                    let lastIndex = syntaxEnd - 1
                    if lastIndex >= syntaxStart && lastIndex < ctx.nsText.length {
                        let lastChar = ctx.nsText.substring(with: NSRange(location: lastIndex, length: 1))
                        if lastChar != "\n" { isActiveSyntax = true }
                    }
                }
                if isChecked {
                    let lineRange = ctx.nsText.lineRange(for: checkboxRange)
                    var lineEnd = lineRange.location + lineRange.length
                    if lineEnd > lineRange.location {
                        let lastCharRange = NSRange(location: lineEnd - 1, length: 1)
                        if ctx.nsText.substring(with: lastCharRange) == "\n" {
                            lineEnd -= 1
                        }
                    }
                    var contentStart = checkboxRange.location + checkboxRange.length
                    while contentStart < lineEnd {
                        let charRange = NSRange(location: contentStart, length: 1)
                        let char = ctx.nsText.substring(with: charRange)
                        if char == " " || char == "\t" {
                            contentStart += 1
                            continue
                        }
                        break
                    }
                    if contentStart < lineEnd {
                        attrs.append((NSRange(location: contentStart, length: lineEnd - contentStart), [
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: ctx.configuration.theme.strikethroughColor
                        ]))
                    }
                }
                if isActiveSyntax { continue }
                let afterCheckboxIndex = checkboxRange.location + checkboxRange.length
                if afterCheckboxIndex < ctx.nsText.length {
                    let spaceRange = NSRange(location: afterCheckboxIndex, length: 1)
                    let spaceChar = ctx.nsText.substring(with: spaceRange)
                    if spaceChar == " " && !isChecked {
                        let extraSpacing = HeadingHelpers.checkboxExtraSpacing(
                            font: ctx.baseFont,
                            configuration: ctx.configuration.checkbox
                        )
                        attrs.append((spaceRange, [.kern: extraSpacing]))
                    }
                }
            }
            if markerRange.location != NSNotFound {
                attrs.append((markerRange, [.foregroundColor: NSColor.clear]))
            }
            if spacerRange.location != NSNotFound {
                attrs.append((spacerRange, [.foregroundColor: NSColor.clear]))
            }
            attrs.append((checkboxRange, [
                .taskCheckbox: isChecked,
                .foregroundColor: NSColor.clear
            ]))
        }
        return attrs
    }

    // MARK: Shrink / Hide Inactive Markers

    static func shrinkInactiveMarkers(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (i, token) in ctx.tokens.enumerated() where !ctx.activeTokenIndices.contains(i) {
            if token.kind == .codeBlock || token.kind == .inlineCode || token.kind == .inlineLatex || token.kind == .imageEmbed {
                continue
            }
            if MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: ctx.codeTokens) {
                continue
            }
            let smallSize = ctx.configuration.markers.hiddenMarkerFontSize
            let smallFont = NSFont(name: ctx.fontName, size: smallSize) ?? NSFont.systemFont(ofSize: smallSize)
            if token.kind == .link && token.markerRanges.count >= 4 {
                let openParen = token.markerRanges[2]
                let closeParen = token.markerRanges[3]
                let hideRange = NSRange(
                    location: openParen.location,
                    length: (closeParen.location + closeParen.length) - openParen.location
                )
                attrs.append((hideRange, [
                    .font: smallFont,
                    .foregroundColor: NSColor.clear
                ]))
            }
            for m in token.markerRanges {
                attrs.append((m, [
                    .font: smallFont,
                    .kern: -smallFont.pointSize
                ]))
            }
        }
        return attrs
    }
}
