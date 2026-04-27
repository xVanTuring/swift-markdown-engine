//
//  NativeTextViewCoordinator.swift
//  Nodes
//
//  Created by Luca Chen on 18.02.26.
//

// Keeps the editor in sync while you type, updating formatting, selections,
// links, and other editing behavior in one place.
import AppKit
import SwiftUI

public final class NativeTextViewCoordinator: NSObject, NSTextViewDelegate {
    var nodeId: String?
    @Binding var text: String
    @Binding var isNodeActive: Bool
    var fontName: String
    var fontSize: CGFloat
    var configuration: MarkdownEditorConfiguration = .default {
        didSet { subscribeToBusNotifications(replacing: oldValue.services.bus) }
    }
    private var busObservers: [NSObjectProtocol] = []
    weak var textView: NSTextView?
    var layoutBridge: LayoutBridge?
    var layoutDelegate: MarkdownLayoutManagerDelegate?
    var onLinkClick: ((String) -> Void)?
    var onCaretRectChange: ((CGRect) -> Void)?
    var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?
    var didInitialFormatting: Bool = false
    var lastSyncedText: String
    var isProgrammaticEdit: Bool = false
    var isWritingToolsActive: Bool = false
    var wtStartNodeId: String?
    private weak var wtChildWindow: NSWindow?
    private var wtInitialChildOrigin: CGPoint?
    private var wtInitialSelectionRange: NSRange?
    enum WTMode { case unknown, proofread, rewrite }
    private var wtDetectedMode: WTMode = .unknown
    var lastAppliedInlineReplacementID: UUID?
    var activeTokenIndices: Set<Int> = []
    var previousActiveTokenIndices: Set<Int> = []
    var nodeLinkMetadata: [WikiLinkService.RangeKey: WikiLinkService.LinkMetadata] = [:]
    var previousBacktickCount: Int = 0

    private var pendingEditedRange: NSRange? = nil
    private var pendingPreEditActiveTokenIndices: Set<Int>? = nil
    private var previousCaretLocation: Int? = nil

    private var cachedCodeBlockTokens: [(index: Int, token: MarkdownToken)] = []
    private var cachedParsedText: String?
    private var cachedParsedDocument: ParsedDocument?
    // Skip spellcheck property setters when the state wouldn't change.
    private var cachedSpellingDisabled: Bool?

    struct ParsedDocument {
        let tokens: [MarkdownToken]
        let codeTokens: [MarkdownToken]
        let latexTokens: [MarkdownToken]
        let blockLatexTokens: [MarkdownToken]
        let nodeLinkTokens: [MarkdownToken]
        let imageEmbedTokens: [MarkdownToken]
    }

    private enum InlineTokenContext {
        case nodeLink(token: MarkdownToken)
        case imageEmbed(token: MarkdownToken)

        var token: MarkdownToken {
            switch self {
            case .nodeLink(let token), .imageEmbed(let token):
                return token
            }
        }

        var selectionKind: InlineSelectionKind {
            switch self {
            case .nodeLink:
                return .nodeLink
            case .imageEmbed:
                return .imageEmbed
            }
        }
    }

    var isImageEmbedActive: Bool = false
    var suppressFrameShrink: Bool = false

    // Recompute the preview anchor for the active inline token (used when scrolling).
    func refreshActiveLinkCaretRect() {
        guard isNodeActive || isImageEmbedActive, let tv = textView else { return }
        guard let rect = inlinePreviewRect(in: tv) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCaretRectChange?(rect)
        }
    }

    private func inlinePreviewRect(in tv: NSTextView) -> CGRect? {
        let nsText = tv.string as NSString
        let parsed = parsedDocument(for: tv.string)
        let selectionLocation = tv.selectedRange().location
        guard let inlineContext = inlineTokenContext(
            at: selectionLocation,
            parsed: parsed,
            codeTokens: parsed.codeTokens,
            text: nsText
        ) else {
            return tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)
        }

        let openingMarkerLength = inlineContext.selectionKind == .imageEmbed ? 3 : 2
        let displayRange = selectionDisplayRange(for: inlineContext.token, openingMarkerLength: openingMarkerLength)
        return tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
            ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)
    }

    init(text: Binding<String>,
         fontName: String,
         fontSize: CGFloat,
         isNodeActive: Binding<Bool>,
         onLinkClick: ((String) -> Void)?,
         onInlineSelectionChange: ((InlineSelectionState?) -> Void)?) {
        _text = text
        self.fontName = fontName
        self.fontSize = fontSize
        _isNodeActive = isNodeActive
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = nil
        self.onInlineSelectionChange = onInlineSelectionChange
        self.lastSyncedText = text.wrappedValue
        super.init()
        // The syntax-highlighter's appearance signal name comes from the
        // service implementation, not the bus, so we observe it as soon as
        // the coordinator exists. The other listeners are wired up via
        // ``subscribeToBusNotifications`` once configuration arrives.
        if let appearanceName = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppearanceChange(_:)),
                name: appearanceName,
                object: nil
            )
        }
    }

    /// Subscribe to whichever bus notification names the current configuration
    /// supplies. Removes any previous subscriptions first so that swapping
    /// configurations at runtime doesn't double-fire handlers.
    private func subscribeToBusNotifications(replacing previous: MarkdownEditorBus) {
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
        busObservers.removeAll(keepingCapacity: true)

        let bus = configuration.services.bus
        let center = NotificationCenter.default

        if let name = bus.applyBoldRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleBoldNotification(notification)
            })
        }
        if let name = bus.applyItalicRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleItalicNotification(notification)
            })
        }
        if let name = bus.applyHeadingRequest {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleHeadingNotification(notification)
            })
        }
        if let name = bus.findScrollToRange {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindScrollToRange(notification)
            })
        }
        if let name = bus.findClearHighlights {
            busObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handleFindClearHighlights(notification)
            })
        }
    }

    // MARK: - Find in Document Highlight
    private static let findHighlightKey = NSAttributedString.Key("NodesFindHighlight")

    @objc private func handleFindScrollToRange(_ notification: Notification) {
        guard let tv = textView,
              let info = notification.userInfo,
              let range = info["range"] as? NSRange,
              let currentIndex = info["currentIndex"] as? Int,
              let allRanges = info["allRanges"] as? [NSRange] else { return }

        let storage = tv.textStorage
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)

        // Clear previous highlights
        storage?.removeAttribute(.backgroundColor, range: fullRange)

        // Highlight all matches; the focused match gets a stronger color.
        let theme = configuration.theme
        let matchAlpha = configuration.markers.findMatchHighlightAlpha
        let highlightColor = theme.findMatchHighlight.withAlphaComponent(matchAlpha)
        let currentHighlightColor = theme.findCurrentMatchHighlight

        for (i, matchRange) in allRanges.enumerated() {
            guard matchRange.location + matchRange.length <= fullRange.length else { continue }
            let color = (i == currentIndex) ? currentHighlightColor : highlightColor
            storage?.addAttribute(.backgroundColor, value: color, range: matchRange)
        }

        // Scroll to current match
        if range.location + range.length <= fullRange.length {
            tv.scrollRangeToVisible(range)
        }
    }

    @objc private func handleFindClearHighlights(_ notification: Notification) {
        guard let tv = textView else { return }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        tv.textStorage?.removeAttribute(.backgroundColor, range: fullRange)
    }

    fileprivate func nodeLinkID(for range: NSRange) -> String? {
        nodeLinkMetadata[WikiLinkService.RangeKey(range)]?.id
    }

    fileprivate func storageRange(forDisplayRange range: NSRange) -> NSRange? {
        nodeLinkMetadata[WikiLinkService.RangeKey(range)]?.storageRange
    }

    fileprivate func storageRange(containingDisplayLocation location: Int) -> NSRange? {
        for (key, value) in nodeLinkMetadata {
            let displayRange = NSRange(location: key.location, length: key.length)
            if NSLocationInRange(location, displayRange) {
                return value.storageRange
            }
        }
        return nil
    }

    private func selectionDisplayRange(for token: MarkdownToken, openingMarkerLength: Int) -> NSRange {
        let leftRange = token.markerRanges.first
            ?? NSRange(location: token.range.location, length: min(openingMarkerLength, token.range.length))
        let rightRange = token.markerRanges.last
            ?? NSRange(
                location: max(token.range.location, NSMaxRange(token.range) - min(2, token.range.length)),
                length: min(2, token.range.length)
            )
        return NSRange(location: leftRange.location, length: rightRange.location + rightRange.length - leftRange.location)
    }

    private func imageEmbedToken(
        at selectionLocation: Int,
        parsed: ParsedDocument,
        in text: NSString
    ) -> (token: MarkdownToken, index: Int)? {
        for token in parsed.imageEmbedTokens {
            guard token.containsSelectionOrStandaloneParagraph(selectionLocation, in: text) else {
                continue
            }
            let index = parsed.tokens.firstIndex(where: {
                $0.range.location == token.range.location && $0.kind == .imageEmbed
            }) ?? 0
            return (token, index)
        }
        return nil
    }

    private func inlineTokenContext(
        at selectionLocation: Int,
        parsed: ParsedDocument,
        codeTokens: [MarkdownToken],
        text: NSString
    ) -> InlineTokenContext? {
        if let (token, _) = imageEmbedToken(at: selectionLocation, parsed: parsed, in: text),
           !MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: codeTokens) {
            return .imageEmbed(token: token)
        }

        for token in parsed.nodeLinkTokens {
            // Only match when the caret sits between the inner edges of `[[…]]` —
            let start = token.range.location + 2
            let end = NSMaxRange(token.range) - 2
            guard selectionLocation >= start && selectionLocation <= end else { continue }
            guard !MarkdownDetection.isInsideCodeBlock(range: token.range, codeTokens: codeTokens) else { break }
            return .nodeLink(token: token)
        }

        return nil
    }

    // MARK: - Notification Handling
    @objc private func handleBoldNotification(_ notification: Notification) {
        didMarkdownBold(nil)
    }

    @objc private func handleItalicNotification(_ notification: Notification) {
        didMarkdownItalic(nil)
    }

    @objc private func handleHeadingNotification(_ notification: Notification) {
        guard let level = notification.userInfo?["level"] as? Int else { return }
        let item = NSMenuItem()
        item.tag = level
        didMarkdownHeading(item)
    }

    @objc private func handleAppearanceChange(_ notification: Notification) {
        guard let tv = textView else { return }
        // Only react if the notification came from our own text view or from nil (system-wide)
        if let sender = notification.object as? NSTextView, sender !== tv {
            return
        }
        let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
        restyleTextView(tv, paragraphCandidates: [fullRange])
    }

    private func updateSelectionStates(_ tv: NSTextView) {
        let nsText = tv.string as NSString
        let selRange = tv.selectedRange()
        let bus = configuration.services.bus
        let center = NotificationCenter.default
        if let name = bus.selectionBoldDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isBold": isSelectionBold(in: nsText, range: selRange)]
            )
        }
        if let name = bus.selectionItalicDidChange {
            center.post(
                name: name, object: nil,
                userInfo: ["isItalic": isSelectionItalic(in: nsText, range: selRange)]
            )
        }
    }
    
    func restyleTextView(
        _ textView: NSTextView,
        paragraphCandidates: [NSRange],
        tokens: [MarkdownToken]? = nil
    ) {
        let (baseFont, paragraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )

        TextStylingService.restyle(
            textView: textView,
            layoutBridge: layoutBridge,
            paragraphCandidates: paragraphCandidates,
            baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            caretLocation: textView.selectedRange().location,
            activeTokenIndices: activeTokenIndices,
            nodeLinkIDProvider: { [weak self] range in
                self?.nodeLinkID(for: range)
            },
            precomputedTokens: tokens,
            configuration: configuration
        )
    }

    func parsedDocument(for text: String) -> ParsedDocument {
        if cachedParsedText == text, let cachedParsedDocument {
            return cachedParsedDocument
        }

        let tokens = MarkdownTokenizer.parseTokens(in: text)
        var codeTokens: [MarkdownToken] = []
        var latexTokens: [MarkdownToken] = []
        var blockLatexTokens: [MarkdownToken] = []
        var nodeLinkTokens: [MarkdownToken] = []
        var imageEmbedTokens: [MarkdownToken] = []

        codeTokens.reserveCapacity(tokens.count / 2)
        latexTokens.reserveCapacity(tokens.count / 4)
        blockLatexTokens.reserveCapacity(tokens.count / 4)
        nodeLinkTokens.reserveCapacity(tokens.count / 4)

        for token in tokens {
            switch token.kind {
            case .codeBlock, .inlineCode:
                codeTokens.append(token)
            case .inlineLatex:
                latexTokens.append(token)
            case .blockLatex:
                blockLatexTokens.append(token)
            case .nodeLink:
                nodeLinkTokens.append(token)
            case .imageEmbed:
                imageEmbedTokens.append(token)
            default:
                break
            }
        }

        let parsed = ParsedDocument(
            tokens: tokens,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            blockLatexTokens: blockLatexTokens,
            nodeLinkTokens: nodeLinkTokens,
            imageEmbedTokens: imageEmbedTokens
        )
        cachedParsedText = text
        cachedParsedDocument = parsed
        return parsed
    }


    private func paragraphRanges(
        in text: NSString,
        intersecting editedRange: NSRange
    ) -> [NSRange] {
        guard text.length > 0 else { return [] }
        guard editedRange.location != NSNotFound else { return [] }

        var start = editedRange.location
        let end = min(NSMaxRange(editedRange), text.length)
        if start >= text.length {
            start = max(0, text.length - 1)
        }
        if end <= start {
            return [text.paragraphRange(for: NSRange(location: start, length: 0))]
        }

        var ranges: [NSRange] = []
        var cursor = start
        while cursor < end {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(paragraph)
            let next = NSMaxRange(paragraph)
            if next <= cursor { break }
            cursor = next
        }
        return ranges
    }

    private func tokenRestyleParagraphs(
        in text: NSString,
        tokens: [MarkdownToken],
        currentActiveTokenIndices: Set<Int>,
        previousActiveTokenIndices: Set<Int>
    ) -> [NSRange] {
        var paragraphs: [NSRange] = []
        let indicesToStyle = currentActiveTokenIndices.union(previousActiveTokenIndices)

        for idx in indicesToStyle where idx >= 0 && idx < tokens.count {
            let token = tokens[idx]
            paragraphs.append(text.paragraphRange(for: token.range))

            if token.kind == .codeBlock || token.kind == .blockLatex {
                for markerRange in token.markerRanges {
                    paragraphs.append(text.paragraphRange(for: markerRange))
                }
            }
        }

        return paragraphs
    }
    
    func restyleParagraphs(_ paragraphs: [NSRange], in textView: NSTextView) {
        let parsed = parsedDocument(for: textView.string)
        let tokens = parsed.tokens
        let nsText = textView.string as NSString
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: tokens,
            in: nsText
        )
        restyleTextView(textView, paragraphCandidates: paragraphs, tokens: tokens)
    }

    func applyInlineReplacement(_ request: InlineReplacementRequest, to textView: NSTextView) {
        lastAppliedInlineReplacementID = request.id

        let currentText = textView.string as NSString
        let range = request.selection.displayRange
        guard range.location != NSNotFound,
              range.location + range.length <= currentText.length else {
            return
        }

        let replacementDisplay: String
        let linkID: String?
        if request.isImageEmbedMode {
            replacementDisplay = request.storageFragment
            linkID = nil
        } else {
            let replacementInfo = WikiLinkService.displayFragmentAndID(from: request.storageFragment)
            replacementDisplay = replacementInfo.display
            linkID = replacementInfo.id
        }

        let undoActionName = request.isImageEmbedMode ? "Insert Image Embed" : "Insert Link"
        textView.breakUndoCoalescing()

        isProgrammaticEdit = true
        defer { isProgrammaticEdit = false }

        guard textView.shouldChangeText(in: range, replacementString: replacementDisplay) else {
            return
        }

        textView.textStorage?.replaceCharacters(in: range, with: replacementDisplay)

        if let linkID, !linkID.isEmpty {
            let contentLength = max(0, (replacementDisplay as NSString).length - 4)
            if contentLength > 0 {
                let contentRange = NSRange(location: range.location + 2, length: contentLength)
                textView.textStorage?.addAttribute(.nodeLinkID, value: linkID, range: contentRange)
            }
        }

        textView.didChangeText()
        textView.undoManager?.setActionName(undoActionName)
        textView.breakUndoCoalescing()

        let caretRange = WikiLinkService.caretRangeAfterReplacing(
            displayRange: range,
            with: request.storageFragment
        )
        let documentLength = (textView.string as NSString).length
        let clampedCaret = NSRange(location: min(max(caretRange.location, 0), documentLength), length: 0)

        if let bottomTextView = textView as? NativeTextView {
            bottomTextView.suppressAutoRevealOnce = true
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clampedCaret)
    }


    // MARK: - NSTextViewDelegate

    /// Force base typingAttributes on every change so AppKit's auto-inheritance can't bleed a heading paragraphStyle into the trailing extra-line fragment's metrics.
    public func textView(
        _ textView: NSTextView,
        shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
        toAttributes newTypingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        let (baseFont, baseParagraphStyle) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: layoutBridge,
            configuration: configuration
        )
        var result = newTypingAttributes
        result[.paragraphStyle] = baseParagraphStyle
        result[.font] = baseFont
        result[.foregroundColor] = configuration.theme.bodyText
        return result
    }

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        let wtActive = isWritingToolsActive
        if wtActive, wtDetectedMode == .unknown {
            let firstEditLen = tv.textStorage?.editedRange.length ?? 0
            if let sel = wtInitialSelectionRange, sel.length > 0 {
                let threshold = max(10, Int(Double(sel.length) * 0.6))
                wtDetectedMode = firstEditLen >= threshold ? .rewrite : .proofread
            } else {
                wtDetectedMode = .rewrite
            }
        }
        if wtActive && wtDetectedMode == .proofread { return }

        if !wtActive {
            (tv as? NativeTextView)?.allowFrameShrink = true
        }

        let rawSelRange = tv.selectedRange()
        let fullLength = (tv.string as NSString).length
        guard !tv.hasMarkedText() else { return }
        let safeLocation = min(rawSelRange.location, fullLength)
        let safeSelRange = NSRange(location: safeLocation, length: 0)
        previousCaretLocation = safeSelRange.location
        if !wtActive {
            let storageState = WikiLinkService.makeStorageState(
                from: tv.string,
                existingMetadata: self.nodeLinkMetadata,
                textStorage: tv.textStorage
            )
            self.nodeLinkMetadata = storageState.metadata
            if storageState.storage != self.lastSyncedText {
                DispatchQueue.main.async {
                    self.lastSyncedText = storageState.storage
                    self.text = storageState.storage
                }
            }
        }

        let fullText = tv.string as NSString
        let paragraphRange = fullText.paragraphRange(for: safeSelRange)
        let documentLength = fullText.length
        let nextLocation = min(documentLength, NSMaxRange(paragraphRange))
        let previousParagraph = paragraphRange.location > 0
            ? fullText.paragraphRange(for: NSRange(location: max(0, paragraphRange.location - 1), length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let nextParagraph = nextLocation < documentLength
            ? fullText.paragraphRange(for: NSRange(location: nextLocation, length: 0))
            : NSRange(location: NSNotFound, length: 0)
        let editedRange = pendingEditedRange ?? tv.textStorage?.editedRange ?? safeSelRange
        pendingEditedRange = nil
        let wtEditedFallback: NSRange? = {
            guard wtActive, let sel = wtInitialSelectionRange else { return nil }
            let docLength = fullText.length
            let loc = min(sel.location, docLength)
            let len = min(sel.length, docLength - loc)
            return NSRange(location: loc, length: len)
        }()
        let safeEditedRange: NSRange = {
            if let wtRange = wtEditedFallback { return wtRange }
            return editedRange.location == NSNotFound ? safeSelRange : editedRange
        }()
        let editedParagraphs = paragraphRanges(in: fullText, intersecting: safeEditedRange)
        let paragraphCandidates: [NSRange] = [
            previousParagraph,
            paragraphRange,
            nextParagraph
        ] + editedParagraphs

        let backtickCount = tv.string.components(separatedBy: "```").count - 1
        let codeBlockStructureChanged = backtickCount != previousBacktickCount
        previousBacktickCount = backtickCount
        
        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let preEditActiveTokenIndices = pendingPreEditActiveTokenIndices ?? previousActiveTokenIndices
        pendingPreEditActiveTokenIndices = nil

        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: safeSelRange,
            tokens: tokens,
            in: fullText
        )
        filterImageEmbedActiveTokens(parsed: parsed, text: fullText, selectionLocation: safeSelRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: safeSelRange.location,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )
        
        var effectiveParagraphCandidates = paragraphCandidates
        if codeBlockStructureChanged {
            effectiveParagraphCandidates = [NSRange(location: 0, length: fullText.length)]
        }
        // Always restyle paragraphs containing latex/imageEmbed tokens to avoid stale raw text.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { fullText.paragraphRange(for: $0.range) }
        effectiveParagraphCandidates.append(contentsOf: latexParagraphs)
        effectiveParagraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: fullText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: preEditActiveTokenIndices
        ))
        
        restyleTextView(tv, paragraphCandidates: effectiveParagraphCandidates, tokens: tokens)
        updateCodeBlockSelection(textView: tv, tokens: tokens)
        if wtActive {
            previousActiveTokenIndices = activeTokenIndices
            return
        }
        if let bottomTextView = tv as? NativeTextView,
           let scrollView = tv.enclosingScrollView {
            bottomTextView.recalcOverscroll(for: scrollView)
            (scrollView as? ClampedScrollView)?.clampToInsets()
            bottomTextView.allowFrameShrink = false
            bottomTextView.pendingContentShrink = true
            DispatchQueue.main.async { [weak bottomTextView, weak scrollView] in
                guard let tv = bottomTextView, let sv = scrollView, tv.pendingContentShrink else { return }
                tv.allowFrameShrink = true
                tv.pendingContentShrink = false
                tv.recalcOverscroll(for: sv)
                (sv as? ClampedScrollView)?.clampToInsets()
                tv.allowFrameShrink = false
            }
        }
        previousActiveTokenIndices = activeTokenIndices
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        if isWritingToolsActive { return }
        let selRange = tv.selectedRange()
        let currentEventType = NSApp.currentEvent?.type
        // Mouse-/Wake-Fokus auf Link: kein Preview, erst Navigation. Gilt für alle Nicht-Key-Events.
        if currentEventType != .keyDown,
           selRange.location < (tv.string as NSString).length,
           tv.textStorage?.attribute(.link, at: selRange.location, effectiveRange: nil) != nil {
            isImageEmbedActive = false
            isNodeActive = false
            onInlineSelectionChange?(nil)
            return
        }
        updateSelectionStates(tv)
        let selLoc = selRange.location

        let parsed = parsedDocument(for: tv.string)
        let tokens = parsed.tokens
        let codeTokens = parsed.codeTokens
        let latexTokens = parsed.latexTokens
        let blockLatexTokens = parsed.blockLatexTokens
        let nsText = tv.string as NSString

        let prevActive = activeTokenIndices
        activeTokenIndices = MarkdownDetection.computeActiveTokenIndices(selectionRange: selRange, tokens: tokens, in: nsText)
        filterImageEmbedActiveTokens(parsed: parsed, text: nsText, selectionLocation: selRange.location)
        updateAutocorrectSettings(
            tv,
            caretLocation: selLoc,
            codeTokens: codeTokens,
            latexTokens: latexTokens,
            allTokens: tokens
        )
        let caretLoc = selRange.location
        let paragraphRange = nsText.paragraphRange(for: NSRange(location: caretLoc, length: 0))

        var paragraphCandidates: [NSRange] = [paragraphRange]
        if paragraphRange.length == 0 && caretLoc > 0 {
            paragraphCandidates.append(nsText.paragraphRange(for: NSRange(location: max(0, caretLoc - 1), length: 0)))
        }
        if let prevLoc = previousCaretLocation, prevLoc != caretLoc {
            let safePrev = min(prevLoc, nsText.length)
            let prevPara = nsText.paragraphRange(for: NSRange(location: safePrev, length: 0))
            paragraphCandidates.append(prevPara)
        }
        // Also restyle paragraphs containing latex/imageEmbed tokens to refresh rendering.
        let latexParagraphs = (latexTokens + blockLatexTokens + parsed.imageEmbedTokens).map { nsText.paragraphRange(for: $0.range) }
        paragraphCandidates.append(contentsOf: latexParagraphs)
        paragraphCandidates.append(contentsOf: tokenRestyleParagraphs(
            in: nsText,
            tokens: tokens,
            currentActiveTokenIndices: activeTokenIndices,
            previousActiveTokenIndices: previousActiveTokenIndices
        ))

        let shouldSkipSelectionRestyle = pendingEditedRange != nil
        let tokensChanged = activeTokenIndices != prevActive
        if shouldSkipSelectionRestyle {
            // textDidChange performs the pending restyle for this edit cycle.
        } else if tokensChanged {
            restyleTextView(tv, paragraphCandidates: paragraphCandidates, tokens: tokens)
        }

        // Auto-select content when clicking (mouse) into a rendered (previously inactive) latex or image embed
        if selRange.length == 0,
           let eventType = currentEventType,
           eventType == .leftMouseUp || eventType == .leftMouseDown {
            let newlyActive = activeTokenIndices.subtracting(previousActiveTokenIndices)
            for idx in newlyActive {
                let token = tokens[idx]
                guard token.kind == .inlineLatex
                    || token.kind == .blockLatex
                    || token.kind == .imageEmbed else {
                    continue
                }
                let selectRange = token.contentRange
                if selectRange.length > 0 {
                    tv.setSelectedRange(selectRange)
                    break
                }
            }
        }

        let nsString = tv.string as NSString
        let selLocation = tv.selectedRange().location
        let inlineContext = inlineTokenContext(
            at: selLocation,
            parsed: parsed,
            codeTokens: codeTokens,
            text: nsText
        )
        let isInsideImageEmbed = {
            guard case .imageEmbed = inlineContext else { return false }
            return true
        }()
        // Preview must only trigger inside the `![[…]]` content area
        let isInsideImageEmbedContent: Bool = {
            guard case .imageEmbed(let token) = inlineContext else { return false }
            let start = token.range.location + 3
            let end = NSMaxRange(token.range) - 2
            return selLocation >= start && selLocation <= end
        }()

        let isTyping = currentEventType == .keyDown
        let imageEmbedShowsInlinePreview = isInsideImageEmbedContent && isTyping
        var inlineSelectionState: InlineSelectionState? = nil
        if let inlineContext {
            let openingMarkerLength = inlineContext.selectionKind == .imageEmbed ? 3 : 2
            let displayRange = selectionDisplayRange(for: inlineContext.token, openingMarkerLength: openingMarkerLength)
            let placeholder = nsString.substring(with: displayRange)
            let storageRange = inlineContext.selectionKind == .nodeLink
                ? storageRange(containingDisplayLocation: selLocation) ?? storageRange(forDisplayRange: displayRange)
                : nil
            let previewRect = tv.viewRect(forCharacterRange: displayRange, using: layoutBridge)
                ?? tv.viewRect(forCharacterRange: tv.selectedRange(), using: layoutBridge)

            let shouldShowInlinePreview =
                inlineContext.selectionKind == .nodeLink
                || (inlineContext.selectionKind == .imageEmbed && imageEmbedShowsInlinePreview)
            if shouldShowInlinePreview, let previewRect {
                let selection = NodeLinkSelection(
                    displayRange: displayRange,
                    storageRange: storageRange,
                    placeholder: placeholder
                )
                inlineSelectionState = InlineSelectionState(kind: inlineContext.selectionKind, selection: selection)
                DispatchQueue.main.async {
                    self.onCaretRectChange?(previewRect)
                }
            }
        }

        DispatchQueue.main.async {
            self.isNodeActive = inlineSelectionState?.kind == .nodeLink
            self.isImageEmbedActive = isInsideImageEmbed
            self.onInlineSelectionChange?(inlineSelectionState)
        }

        self.previousActiveTokenIndices = self.activeTokenIndices
        self.previousCaretLocation = caretLoc

        // Track code blocks for button overlay (reuse tokens)
        updateCodeBlockSelection(textView: tv, tokens: tokens)
    }
    
    func updateCodeBlockSelection(textView: NSTextView, tokens: [MarkdownToken]? = nil) {
        guard let textContainer = textView.textContainer else {
            onCodeBlockSelectionChange?([])
            return
        }

        if let tokens = tokens {
            cachedCodeBlockTokens = tokens.enumerated()
                .filter { $0.element.kind == .codeBlock }
                .map { (index: $0.offset, token: $0.element) }
        } else if cachedCodeBlockTokens.isEmpty {
            onCodeBlockSelectionChange?([])
            return
        }
        
        let nsText = textView.string as NSString
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        
        let selections: [CodeBlockSelection] = cachedCodeBlockTokens.compactMap { originalIndex, token in
            guard !activeTokenIndices.contains(originalIndex) else { return nil }
            guard var boundingRect = textView.viewRect(forCharacterRange: token.range, using: layoutBridge) else { return nil }

            boundingRect.origin.x = textView.textContainerOrigin.x - scrollOffset.x
            boundingRect.size.width = textContainer.containerSize.width

            return CodeBlockSelection(
                id: originalIndex,
                rect: boundingRect,
                language: MarkdownTokenizer.extractLanguage(from: token, in: textView.string),
                code: nsText.substring(with: token.contentRange)
            )
        }

        onCodeBlockSelectionChange?(selections)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isProgrammaticEdit { return true }
        if isWritingToolsActive { return true }
        pendingEditedRange = NSRange(location: affectedCharRange.location, length: replacementString?.utf16.count ?? 0)
        let currentLen = (textView.string as NSString).length
        let maxR = affectedCharRange.location + affectedCharRange.length
        if affectedCharRange.location > currentLen || maxR > currentLen {
            pendingPreEditActiveTokenIndices = nil
            return false
        }
        if textView.undoManager?.isUndoing == true || textView.undoManager?.isRedoing == true {
            pendingPreEditActiveTokenIndices = nil
            return true
        }
        let parsed = parsedDocument(for: textView.string)
        pendingPreEditActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(),
            tokens: parsed.tokens,
            in: textView.string as NSString
        )

        // Block LaTeX auto-wrap: insert newlines to keep $$ on its own line
        if MarkdownInputHandler.handleBlockLatexAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            blockLatexTokens: parsed.blockLatexTokens
        ) {
            return false
        }

        if MarkdownInputHandler.handleImageEmbedAutoWrap(
            textView: textView,
            affectedCharRange: affectedCharRange,
            replacementString: replacementString,
            imageEmbedTokens: parsed.imageEmbedTokens
        ) {
            return false
        }

        return MarkdownInputHandler.handleListInsertion(textView: textView, affectedCharRange: affectedCharRange, replacementString: replacementString)
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return handleBacktab(textView)
        }
        return false
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let target = WikiLinkService.resolveIdentifier(link: link, textView: textView, at: charIndex) else {
            return false
        }
        // Direkt deaktivieren, bevor der Navigation-Callback läuft.
        self.isNodeActive = false
        DispatchQueue.main.async {
            self.onLinkClick?(target)
        }
        return true
    }

    // MARK: - Image Embed Activation

    private func filterImageEmbedActiveTokens(parsed: ParsedDocument, text: NSString, selectionLocation: Int) {
        let activeImageEmbedIndex = imageEmbedToken(
            at: selectionLocation,
            parsed: parsed,
            in: text
        )?.index

        for (idx, token) in parsed.tokens.enumerated() where token.kind == .imageEmbed {
            if idx != activeImageEmbedIndex {
                activeTokenIndices.remove(idx)
            } else {
                activeTokenIndices.insert(idx)
            }
        }
    }

    func resetImageEmbedState() {
        isImageEmbedActive = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        busObservers.forEach(NotificationCenter.default.removeObserver(_:))
    }

    // MARK: - Helper
    private func handleBacktab(_ textView: NSTextView) -> Bool {
        let nsText = textView.string as NSString
        let caretLoc = textView.selectedRange().location
        let lineRange = nsText.lineRange(for: NSRange(location: caretLoc, length: 0))
        let line = nsText.substring(with: lineRange)

        let pattern = #"^([\t ]*)((\d+)\.|-|•)\s"#
        let regex = try? NSRegularExpression(pattern: pattern)
        if let regex = regex,
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) {
            let wsRangeLocal = match.range(at: 1)
            let wsString = (line as NSString).substring(with: wsRangeLocal)
            let wsDocStart = lineRange.location + wsRangeLocal.location
            let depth = MarkdownLists.indentLevel(from: wsString)
            if depth <= 1 {
                return true
            }

            if wsRangeLocal.length > 0 {
                if wsString.hasPrefix("\t") {
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: 1), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
                    return true
                } else {
                    var removeCount = 0
                    for ch in wsString {
                        if ch == " " && removeCount < 2 { removeCount += 1 } else { break }
                    }
                    if removeCount == 0 { removeCount = min(2, wsRangeLocal.length) }
                    MarkdownLists.performEdit(textView, replace: NSRange(location: wsDocStart, length: removeCount), with: "")
                    textView.setSelectedRange(NSRange(location: max(0, caretLoc - removeCount), length: 0))
                    return true
                }
            } else {
                return true
            }
        }

        if line.hasPrefix("\t") {
            MarkdownLists.performEdit(textView, replace: NSRange(location: lineRange.location, length: 1), with: "")
            textView.setSelectedRange(NSRange(location: max(0, caretLoc - 1), length: 0))
            return true
        }
        return false
    }

    func updateAutocorrectSettings(
        _ textView: NSTextView,
        caretLocation: Int,
        codeTokens: [MarkdownToken]? = nil,
        latexTokens: [MarkdownToken]? = nil,
        allTokens: [MarkdownToken]? = nil
    ) {
        // Prefer precomputed tokens to avoid the expensive textView.string bridge on long docs.
        let inCode: Bool
        if let codeTokens = codeTokens {
            inCode = MarkdownDetection.isInsideCodeBlock(location: caretLocation, codeTokens: codeTokens)
        } else {
            inCode = MarkdownDetection.isInsideCodeBlock(location: caretLocation, in: textView.string)
        }
        let inLatex: Bool
        if let latexTokens = latexTokens {
            inLatex = MarkdownDetection.isInsideLatex(location: caretLocation, latexTokens: latexTokens)
        } else {
            inLatex = MarkdownDetection.isInsideLatex(location: caretLocation, in: textView.string)
        }
        let inSpellcheckSuppressedToken: Bool
        if let allTokens = allTokens {
            inSpellcheckSuppressedToken = allTokens.contains { token in
                (token.kind == .nodeLink || token.kind == .link)
                    && NSLocationInRange(caretLocation, token.range)
            }
        } else {
            inSpellcheckSuppressedToken = isInsideSpellcheckSuppressedToken(location: caretLocation, in: textView.string)
        }
        let shouldDisableSpelling = inCode || inLatex || inSpellcheckSuppressedToken

        if cachedSpellingDisabled == shouldDisableSpelling {
            return
        }
        cachedSpellingDisabled = shouldDisableSpelling

        textView.isAutomaticSpellingCorrectionEnabled = !shouldDisableSpelling
        textView.isContinuousSpellCheckingEnabled = !shouldDisableSpelling
        textView.isGrammarCheckingEnabled = !shouldDisableSpelling
        textView.isAutomaticQuoteSubstitutionEnabled = !shouldDisableSpelling
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    func isInsideCode(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return MarkdownDetection.isInsideCodeBlock(range: range, codeTokens: parsed.codeTokens)
    }

    func isInsideLatex(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        if MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.latexTokens) {
            return true
        }
        return MarkdownDetection.isInsideLatex(location: location, latexTokens: parsed.blockLatexTokens)
    }

    func isInsideSpellcheckSuppressedToken(location: Int, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .nodeLink || token.kind == .link else {
                return false
            }
            return NSLocationInRange(location, token.range)
        }
    }

    func isInsideSpellcheckSuppressedToken(range: NSRange, in text: String) -> Bool {
        let parsed = parsedDocument(for: text)
        return parsed.tokens.contains { token in
            guard token.kind == .nodeLink || token.kind == .link else {
                return false
            }
            return NSIntersectionRange(token.range, range).length > 0
        }
    }

}

private extension NSTextView {
    func viewRect(forCharacterRange range: NSRange, using bridge: LayoutBridge?) -> CGRect? {
        guard range.location != NSNotFound,
              let bridge = bridge,
              let textContainer = textContainer else { return nil }
        var boundingRect = bridge.boundingRect(forCharacterRange: range, in: textContainer)
        let containerOrigin = textContainerOrigin
        boundingRect.origin.x += containerOrigin.x
        boundingRect.origin.y += containerOrigin.y
        if let scrollView = enclosingScrollView {
            let contentOffset = scrollView.contentView.bounds.origin
            boundingRect.origin.x -= contentOffset.x
            boundingRect.origin.y -= contentOffset.y
        }
        return boundingRect
    }
}

// MARK: - Writing Tools (NSTextViewDelegate methods, macOS 15.0+)
extension NativeTextViewCoordinator {
    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        let sel = textView.selectedRange()
        isWritingToolsActive = true
        wtStartNodeId = nodeId
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = sel.length > 0 ? sel : nil
        wtDetectedMode = .unknown
        scheduleChildWindowFix(textView: textView, attemptsRemaining: 20)
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        guard isWritingToolsActive else { return }
        isWritingToolsActive = false
        wtChildWindow = nil
        wtInitialChildOrigin = nil

        // If the user switched files while WT was active, updateNSView already
        // reset the WT state and loaded the new node — discard these results.
        if wtStartNodeId != nil && wtStartNodeId != nodeId {
            wtStartNodeId = nil
            return
        }
        wtStartNodeId = nil

        // Still on the same node — sync the rewritten text to the binding.
        // Defer to next runloop to avoid modifying @Binding during a view update
        // (textViewWritingToolsDidEnd can fire synchronously from updateNSView).
        let storageState = WikiLinkService.makeStorageState(
            from: textView.string,
            existingMetadata: nodeLinkMetadata,
            textStorage: textView.textStorage
        )
        nodeLinkMetadata = storageState.metadata
        let storage = storageState.storage
        DispatchQueue.main.async { [self] in
            lastSyncedText = storage
            text = storage
        }
    }

    // MARK: - Child window (Done/Original panel) position fix

    private func scheduleChildWindowFix(textView: NSTextView, attemptsRemaining: Int) {
        guard attemptsRemaining > 0, isWritingToolsActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isWritingToolsActive else { return }
            self.captureChildWindowIfNeeded(textView: textView)
            if self.wtChildWindow == nil {
                self.scheduleChildWindowFix(textView: textView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func captureChildWindowIfNeeded(textView: NSTextView) {
        guard wtChildWindow == nil,
              let mainWindow = textView.window,
              let childWin = mainWindow.childWindows?.first(where: { $0.isVisible }) else { return }
        wtChildWindow = childWin
        wtInitialChildOrigin = childWin.frame.origin
    }

    func fixWritingToolsChildWindowIfNeeded(textView: NSTextView) {
        guard let childWin = wtChildWindow,
              let correctOrigin = wtInitialChildOrigin else { return }

        let frame = childWin.frame
        let needsFix = abs(frame.origin.x - correctOrigin.x) > 0.5 || abs(frame.origin.y - correctOrigin.y) > 0.5
        if needsFix {
            var fixed = frame
            fixed.origin = correctOrigin
            childWin.setFrame(fixed, display: false)
        }
    }
}
