//
//  NativeTextViewWrapper.swift
//  Nodes
//
//  Created by Luca Chen on 18.02.26.
//

// Brings the editor into SwiftUI and wires up the text view with the
// right setup, styling, and callbacks.
import SwiftUI
import AppKit

public struct NodeLinkSelection: Sendable {
    public let displayRange: NSRange
    public let storageRange: NSRange?
    public let placeholder: String

    public init(displayRange: NSRange, storageRange: NSRange?, placeholder: String) {
        self.displayRange = displayRange
        self.storageRange = storageRange
        self.placeholder = placeholder
    }
}

public enum InlineSelectionKind: Sendable {
    case nodeLink
    case imageEmbed
}

public struct InlineSelectionState: Sendable {
    public let kind: InlineSelectionKind
    public let selection: NodeLinkSelection

    public init(kind: InlineSelectionKind, selection: NodeLinkSelection) {
        self.kind = kind
        self.selection = selection
    }
}

public struct InlineReplacementRequest: Sendable {
    public let id: UUID
    public let nodeId: String
    public let selection: NodeLinkSelection
    public let storageFragment: String
    public let isImageEmbedMode: Bool

    public init(
        id: UUID = UUID(),
        nodeId: String,
        selection: NodeLinkSelection,
        storageFragment: String,
        isImageEmbedMode: Bool
    ) {
        self.id = id
        self.nodeId = nodeId
        self.selection = selection
        self.storageFragment = storageFragment
        self.isImageEmbedMode = isImageEmbedMode
    }
}


public struct NativeTextViewWrapper: NSViewRepresentable {
    public typealias Coordinator = NativeTextViewCoordinator
    public typealias NSViewType = NSScrollView

    @Binding public var text: String
    @Binding public var isNodeActive: Bool
    @Binding public var pendingInlineReplacement: InlineReplacementRequest?
    /// The full editor configuration (theme + services + style toggles). Engine
    /// embedders construct this themselves and pass it in; the wrapper does
    /// not read UserDefaults or know about app-specific colors/services.
    public var configuration: MarkdownEditorConfiguration
    public var fontName: String
    public var fontSize: CGFloat
    public var nodeId: String
    public var isEditable: Bool
    public var onPasteImage: ((NSPasteboard) -> String?)?

    public var onLinkClick: ((String) -> Void)?
    public var onCaretRectChange: ((CGRect) -> Void)?
    public var onInlineSelectionChange: ((InlineSelectionState?) -> Void)?
    public var onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)?

    public init(
        text: Binding<String>,
        isNodeActive: Binding<Bool>,
        pendingInlineReplacement: Binding<InlineReplacementRequest?>,
        configuration: MarkdownEditorConfiguration,
        fontName: String,
        fontSize: CGFloat = 16,
        nodeId: String,
        isEditable: Bool = true,
        onPasteImage: ((NSPasteboard) -> String?)? = nil,
        onLinkClick: ((String) -> Void)? = nil,
        onCaretRectChange: ((CGRect) -> Void)? = nil,
        onInlineSelectionChange: ((InlineSelectionState?) -> Void)? = nil,
        onCodeBlockSelectionChange: (([CodeBlockSelection]) -> Void)? = nil
    ) {
        self._text = text
        self._isNodeActive = isNodeActive
        self._pendingInlineReplacement = pendingInlineReplacement
        self.configuration = configuration
        self.fontName = fontName
        self.fontSize = fontSize
        self.nodeId = nodeId
        self.isEditable = isEditable
        self.onPasteImage = onPasteImage
        self.onLinkClick = onLinkClick
        self.onCaretRectChange = onCaretRectChange
        self.onInlineSelectionChange = onInlineSelectionChange
        self.onCodeBlockSelectionChange = onCodeBlockSelectionChange
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClampedScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 55.4, left: 0, bottom: 0, right: 0)

        // Let NSTextView auto-initialize its own TextKit 2 stack via init(frame:).
        let textView = NativeTextView(frame: .zero)

        // Configure the auto-created text container.
        guard let textContainer = textView.textContainer,
              let textLayoutManager = textView.textLayoutManager else {
            fatalError("NSTextView did not create a TextKit 2 stack on this OS version")
        }
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        let layoutDelegate = MarkdownLayoutManagerDelegate()
        context.coordinator.layoutDelegate = layoutDelegate
        textLayoutManager.delegate = layoutDelegate
        textView.configuration = configuration
        textView.overscrollPercent = configuration.overscroll.percent
        textView.maxOverscrollPoints = configuration.overscroll.maxPoints
        textView.minOverscrollPoints = configuration.overscroll.minPoints
        context.coordinator.configuration = configuration
        textView.insertionPointColor = configuration.theme.bodyText
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.isRichText = true
        let initialState = WikiLinkService.makeDisplayState(from: text)
        textView.string = initialState.display
        textView.delegate = context.coordinator
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.postsFrameChangedNotifications = true
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.baseFont = font
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onPasteImage = onPasteImage
        if #available(macOS 15.1, *) {
            textView.writingToolsBehavior = .complete
        }
        // Create TextKit 2 layout bridge
        let bridge = LayoutBridge(textLayoutManager)    
        context.coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        scrollView.documentView = textView

        // Force full-document layout at init so paragraph heights are known
        // upfront; otherwise TextKit 2 viewport layout causes scroll drift.
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.clampToInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)

        context.coordinator.textView = textView
        context.coordinator.nodeLinkMetadata = initialState.metadata
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange

        textView.recalcOverscroll(for: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            // Only react when the viewport itself resizes (window resize).
            // Without this guard, TextKit-induced textView frame changes echo
            // back here and re-trigger recalcOverscroll, causing a 149pt
            // height oscillation after clicks.
            guard abs(textView.frame.height - scrollView.contentView.bounds.height) > 1 else { return }
            textView.recalcOverscroll(for: scrollView)
            scrollView.clampToInsets()
        }
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: nil) { _ in
            (textView as? NativeTextView)?.ensureVisibleLayout()
            if context.coordinator.isWritingToolsActive {
                context.coordinator.fixWritingToolsChildWindowIfNeeded(textView: textView)
            }
            scrollView.clampToInsets()
            context.coordinator.refreshActiveLinkCaretRect()
            context.coordinator.updateCodeBlockSelection(textView: textView)
        }
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let isNodeSwitch = context.coordinator.nodeId != nodeId
        let wtActive: Bool = {
            if #available(macOS 15.0, *), textView.isWritingToolsActive { return true }
            return context.coordinator.isWritingToolsActive
        }()

        if wtActive && isNodeSwitch {
            // User switched files while Writing Tools was active — discard the
            // WT session so it doesn't overwrite the wrong node.
            // Keep wtStartNodeId so textViewWritingToolsDidEnd can detect the
            // node mismatch and discard the results.
            context.coordinator.isWritingToolsActive = false
        } else if wtActive {
            // WT active on the same node — don't interfere with the session.
            return
        }

        if let bottomTextView = nsView.documentView as? NativeTextView {
            bottomTextView.onPasteImage = onPasteImage
        }
        // Refresh services/theme when the embedder hands us a new configuration
        // (e.g. when the available wiki-link targets change). Cheap pointer-/
        // value-based comparison; full equality isn't required because the
        // embedder is the source of truth.
        if context.coordinator.configuration.services.images.fingerprint()
            != configuration.services.images.fingerprint() {
            context.coordinator.configuration.services = configuration.services
            (nsView.documentView as? NativeTextView)?.configuration.services = configuration.services
        }
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        textView.insertionPointColor = isEditable ? context.coordinator.configuration.theme.bodyText : .clear
        let fontChanged = (context.coordinator.fontName != fontName) || (context.coordinator.fontSize != fontSize)
        if let pendingInlineReplacement {
            if pendingInlineReplacement.nodeId == nodeId,
               context.coordinator.lastAppliedInlineReplacementID != pendingInlineReplacement.id {
                context.coordinator.applyInlineReplacement(pendingInlineReplacement, to: textView)
            }
            DispatchQueue.main.async {
                if self.pendingInlineReplacement?.id == pendingInlineReplacement.id {
                    self.pendingInlineReplacement = nil
                }
            }
            return
        }
        if context.coordinator.lastSyncedText == text && !fontChanged {
            return
        }
        if fontChanged {
            context.coordinator.didInitialFormatting = false
            (textView as? NativeTextView)?.allowFrameShrink = true
        }
        if isNodeSwitch {
            context.coordinator.nodeId = nodeId
            textView.undoManager?.removeAllActions()
            context.coordinator.didInitialFormatting = false
            context.coordinator.resetImageEmbedState()
            // Persistent shrink: survives frame ping-pong from NSTextView's
            // viewport-based intermediate setFrameSize calls. Cleared in
            // resolvedBaseContentHeight once the frame has settled.
            (textView as? NativeTextView)?.forceShrinkUntilSettled = true
            (textView as? NativeTextView)?.allowFrameShrink = true
            // Reset scroll to top of content so the previous file's scrollY
            // doesn't leak into a (potentially shorter) new file.
            nsView.contentView.scroll(to: NSPoint(x: 0, y: -nsView.contentInsets.top))
            nsView.reflectScrolledClipView(nsView.contentView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        if let tv = nsView.documentView as? NativeTextView {
            tv.baseFont = font
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }

        let displayState = WikiLinkService.makeDisplayState(from: text)
        let displayText = displayState.display
        context.coordinator.nodeLinkMetadata = displayState.metadata
        // Suppress frame shrink during text replacement when images are present (but NOT on node switch).
        if !isNodeSwitch {
            context.coordinator.suppressFrameShrink = true
        }
        if textView.string != displayText {
            textView.string = displayText
        }
        context.coordinator.lastSyncedText = text
        let nsDisplay = displayText as NSString
        let fullRange = NSRange(location: 0, length: nsDisplay.length)

        let activeConfiguration = context.coordinator.configuration
        let (baseFont, paragraph) = TextStylingService.makeBaseFontAndStyle(
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: context.coordinator.layoutBridge,
            configuration: activeConfiguration
        )

        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: activeConfiguration.theme.bodyText,
            .paragraphStyle: paragraph
        ]
        textView.textStorage?.beginEditing()
        textView.textStorage?.removeAttribute(.link, range: fullRange)
        textView.textStorage?.setAttributes(baseAttrs, range: fullRange)

        let currentCaretLocation = textView.selectedRange().location
        // Reuse the coordinator's tokenize cache.
        let tokens = context.coordinator.parsedDocument(for: displayText).tokens
        let updatedActiveTokenIndices = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: textView.selectedRange(), tokens: tokens, in: nsDisplay
        )
        context.coordinator.activeTokenIndices = updatedActiveTokenIndices

        let ranges = MarkdownStyler.styleAttributes(
            text: displayText,
            fontName: fontName,
            fontSize: fontSize,
            layoutBridge: context.coordinator.layoutBridge,
            caretLocation: currentCaretLocation,
            activeTokenIndices: updatedActiveTokenIndices,
            precomputedTokens: tokens,
            configuration: activeConfiguration
        )
        for (range, attrs) in ranges {
            for (key, value) in attrs {
                textView.textStorage?.addAttribute(key, value: value, range: range)
            }
        }
        textView.textStorage?.endEditing()
        // Reset typingAttributes to body before the layout pass so the phantom end-of-document line doesn't inherit the previous file's heading metrics.
        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: activeConfiguration.theme
        )
        // Force full layout so paragraph heights stay stable after attribute changes.
        if let tlm = textView.textLayoutManager {
            if isNodeSwitch {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            tlm.ensureLayout(for: tlm.documentRange)
        }
        if let tv = nsView.documentView as? NativeTextView {
            tv.recalcOverscroll(for: nsView)
            (nsView as? ClampedScrollView)?.clampToInsets()
        }
        if !isNodeSwitch {
            DispatchQueue.main.async {
                context.coordinator.suppressFrameShrink = false
            }
        }
        DispatchQueue.main.async {
            if let tv = nsView.documentView as? NativeTextView {
                context.coordinator.updateCodeBlockSelection(textView: tv)
            }
        }

        textView.typingAttributes = TextStylingService.makeBaseTypingAttributes(
            font: baseFont,
            paragraphStyle: paragraph,
            theme: activeConfiguration.theme
        )

        context.coordinator.fontName = fontName
        context.coordinator.fontSize = fontSize
        context.coordinator.onCaretRectChange = onCaretRectChange
        context.coordinator.onInlineSelectionChange = onInlineSelectionChange
        context.coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = NativeTextViewCoordinator(
            text: $text,
            fontName: fontName,
            fontSize: fontSize,
            isNodeActive: $isNodeActive,
            onLinkClick: onLinkClick,
            onInlineSelectionChange: onInlineSelectionChange
        )
        coordinator.nodeId = nodeId
        coordinator.configuration = configuration
        coordinator.onCodeBlockSelectionChange = onCodeBlockSelectionChange
        return coordinator
    }
}
