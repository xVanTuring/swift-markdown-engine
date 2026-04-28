//
//  NativeTextView.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.02.26.
//

// Handles image paste, task-checkbox clicks, spelling overrides,
// caret-indicator fixes, bottom overscroll for comfortable typing, and a
// drag-select autoscroll boost so downward selection.
//
// Bottom-overscroll math lives in `BottomOverscrollPolicy.swift`.
// Pasteboard image inspection lives in `PasteboardImageReader.swift`.
import AppKit
import UniformTypeIdentifiers

final class NativeTextView: NSTextView {
    private var baseContentHeight: CGFloat = 0
    /// Real content height including overscroll, but excluding the
    /// `max(..., scrollViewHeight)` inflation used for click-below-text.
    var scrollableContentHeight: CGFloat {
        max(ceil(baseContentHeight + activeBottomOverscroll), 0)
    }
    private var activeBottomOverscroll: CGFloat = 0
    private var isApplyingManagedFrameSize = false
    var configuration: MarkdownEditorConfiguration = .default {
        didSet {
            overscrollPercent = configuration.overscroll.percent
            maxOverscrollPoints = configuration.overscroll.maxPoints
            minOverscrollPoints = configuration.overscroll.minPoints
        }
    }
    var overscrollPercent: CGFloat = MarkdownEditorConfiguration.default.overscroll.percent
    var maxOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.maxPoints
    var minOverscrollPoints: CGFloat = MarkdownEditorConfiguration.default.overscroll.minPoints

    var suppressAutoRevealOnce: Bool = false
    var onPasteImage: ((NSPasteboard) -> String?)?
    weak var layoutBridge: LayoutBridge?
    var baseFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var allowFrameShrink: Bool = false
    var pendingContentShrink: Bool = false
    /// Set on node switch — forces shrink on every recalc until the frame has
    /// actually settled at the new content height. Cannot be stolen by frame
    /// ping-pong like `allowFrameShrink` (which is one-shot).
    var forceShrinkUntilSettled: Bool = false
    private var caretIndicatorObservation: NSKeyValueObservation?
    private weak var observedCaretIndicator: NSView?
    private var isApplyingCaretShift: Bool = false



    override func paste(_ sender: Any?) {
        guard isEditable else {
            super.paste(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        if let imageEmbed = onPasteImage?(pasteboard), !imageEmbed.isEmpty {
            let sel = selectedRange()
            let nsText = string as NSString

            // Ensure the image embed lands on its own line
            var prefix = ""
            var suffix = ""
            if sel.location > 0 {
                let charBefore = nsText.character(at: sel.location - 1)
                if charBefore != 0x0A { // \n
                    prefix = "\n"
                }
            }
            let afterLocation = sel.location + sel.length
            if afterLocation < nsText.length {
                let charAfter = nsText.character(at: afterLocation)
                if charAfter != 0x0A { // \n
                    suffix = "\n"
                }
            }

            insertText(prefix + imageEmbed + suffix, replacementRange: sel)
            return
        }
        pasteAsPlainText(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            if PasteboardImageReader.canPasteImage(from: NSPasteboard.general) {
                return true
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    private var dragStartMouseScreenLoc: NSPoint?
    override func mouseDown(with event: NSEvent) {
        if let toggled = toggleTaskCheckboxIfHit(event: event), toggled {
            return
        }
        dragStartMouseScreenLoc = NSEvent.mouseLocation
        let boostTimer = Timer(timeInterval: 1.0 / configuration.dragSelection.ticksPerSecond, repeats: true) { [weak self] _ in
            self?.performDragBoostTick()
        }
        RunLoop.current.add(boostTimer, forMode: .common)
        defer {
            boostTimer.invalidate()
            dragStartMouseScreenLoc = nil
        }

        super.mouseDown(with: event)
    }


    override func scrollRangeToVisible(_ range: NSRange) {
        if suppressAutoRevealOnce {
            suppressAutoRevealOnce = false
            return
        }
        super.scrollRangeToVisible(range)
    }

    /// Force TextKit 2 to lay out all fragments within the current visible rect.
    func ensureVisibleLayout() {
        guard let tlm = textLayoutManager else { return }
        let visTop = visibleRect.minY
        let visBot = visibleRect.maxY
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let fr = fragment.layoutFragmentFrame
            if fr.maxY < visTop { return true }   // before viewport, keep walking
            if fr.minY > visBot { return false }  // past viewport, stop
            return true
        }
    }

    private func performDragBoostTick() {
        guard let window = self.window,
              let scrollView = enclosingScrollView,
              let start = dragStartMouseScreenLoc else { return }

        let mouseScreen = NSEvent.mouseLocation
        let dragPolicy = configuration.dragSelection
        // Require real drag movement so a static click at the window edge doesn't scroll.
        guard max(abs(mouseScreen.x - start.x), abs(mouseScreen.y - start.y)) > dragPolicy.movementThreshold else { return }

        let mouseInWin = window.convertPoint(fromScreen: mouseScreen)
        let direction: CGFloat
        if mouseInWin.y <= dragPolicy.edgeTriggerDistance {
            direction = 1.0
        } else if mouseInWin.y >= window.frame.height - dragPolicy.edgeTriggerDistance {
            direction = -1.0
        } else {
            return
        }

        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: origin.y + dragPolicy.scrollStepPerTick * direction))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        (scrollView as? ClampedScrollView)?.clampToInsets()
    }

    private func toggleTaskCheckboxIfHit(event: NSEvent) -> Bool? {
        guard let textContainer = textContainer,
              let bridge = layoutBridge,
              let storage = textStorage else { return nil }
        let localPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: localPoint.x - textContainerOrigin.x,
            y: localPoint.y - textContainerOrigin.y
        )
        var fraction: CGFloat = 0
        let index = bridge.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index != NSNotFound, index < storage.length else { return nil }

        var effectiveRange = NSRange(location: 0, length: 0)
        guard let isChecked = storage.attribute(.taskCheckbox, at: index, effectiveRange: &effectiveRange) as? Bool,
              effectiveRange.length > 0 else { return nil }

        let nsText = storage.string as NSString
        let checkboxText = nsText.substring(with: effectiveRange)
        guard checkboxText.range(of: #"\[[ xX]\]"#, options: .regularExpression) != nil else { return nil }

        let replacement = isChecked ? "[ ]" : "[x]"
        if shouldChangeText(in: effectiveRange, replacementString: replacement) {
            storage.replaceCharacters(in: effectiveRange, with: replacement)
            storage.addAttribute(.taskCheckbox, value: !isChecked, range: effectiveRange)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: effectiveRange)
            didChangeText()
            bridge.invalidateDisplay(forCharacterRange: effectiveRange)
            if let coord = delegate as? NativeTextViewCoordinator {
                let paragraph = (storage.string as NSString).paragraphRange(for: effectiveRange)
                coord.restyleParagraphs([paragraph], in: self)
            }
        }
        return true
    }

    override func setSpellingState(_ value: Int, range charRange: NSRange) {
        let coordinator = delegate as? NativeTextViewCoordinator
        if value != 0 {
            if self.string.contains("`") {
                let inCode = coordinator?.isInsideCode(range: charRange, in: self.string)
                    ?? MarkdownDetection.isInsideCodeBlock(range: charRange, in: self.string)
                if inCode {
                    return
                }
            }
            if self.string.contains("$") {
                let inLatex = coordinator?.isInsideLatex(location: charRange.location, in: self.string)
                    ?? MarkdownDetection.isInsideLatex(location: charRange.location, in: self.string)
                if inLatex {
                    return
                }
            }
            let inSpellcheckSuppressedToken = coordinator?.isInsideSpellcheckSuppressedToken(range: charRange, in: self.string) ?? false
            if inSpellcheckSuppressedToken {
                return
            }
        }
        super.setSpellingState(value, range: charRange)
    }

    func recalcOverscroll(
        for scrollView: NSScrollView,
        fallbackBaseHeight: CGFloat? = nil,
        targetWidth: CGFloat? = nil,
        forceLayout: Bool = false
    ) {
        scrollView.contentInsets.bottom = 0

        let lineHeight = layoutBridgeDefaultLineHeight(for: self.baseFont, using: layoutBridge)
        // Always force full document layout: TextKit 2's viewport-only layout
        // makes usageBoundsForTextContainer oscillate between full-doc and
        // viewport-only values, which causes frame ping-pong on every keystroke.
        let proposedBaseHeight = measuredBaseContentHeight(
            fallback: fallbackBaseHeight ?? max(frame.size.height - activeBottomOverscroll, 0),
            minimumHeight: lineHeight,
            forceLayout: true
        )
        let resolvedBaseHeight = resolvedBaseContentHeight(for: proposedBaseHeight)
        let visibleHeight = scrollView.contentView.bounds.height
        let policy = BottomOverscrollPolicy(
            overscrollPercent: overscrollPercent,
            minOverscrollPoints: minOverscrollPoints,
            maxOverscrollPoints: maxOverscrollPoints,
            activationStartFraction: configuration.overscroll.activationStartFraction,
            activationRangeFraction: configuration.overscroll.activationRangeFraction
        )
        let resolvedOverscroll = policy.activeOverscroll(
            baseContentHeight: resolvedBaseHeight,
            visibleHeight: visibleHeight,
            lineHeight: lineHeight
        )

        let baseHeightChanged = abs(resolvedBaseHeight - baseContentHeight) > 0.5
        let overscrollChanged = abs(resolvedOverscroll - activeBottomOverscroll) > 0.5
        guard baseHeightChanged || overscrollChanged else { return }
        baseContentHeight = resolvedBaseHeight
        activeBottomOverscroll = resolvedOverscroll
        applyManagedFrameSize(width: targetWidth ?? frame.size.width)
    }


    override func setFrameSize(_ newSize: NSSize) {
        if isApplyingManagedFrameSize {
            super.setFrameSize(newSize)
            return
        }

        guard let scrollView = enclosingScrollView else {
            baseContentHeight = max(newSize.height, 0)
            super.setFrameSize(newSize)
            return
        }

        // After textDidChange, usageBoundsForTextContainer is stale so the
        // explicit recalcOverscroll can't detect the shrink.
        let hadPending = pendingContentShrink
        if pendingContentShrink {
            allowFrameShrink = true
            pendingContentShrink = false
        }

        let widthChanged = abs(newSize.width - frame.size.width) > 0.5
        if widthChanged {
            isApplyingManagedFrameSize = true
            super.setFrameSize(NSSize(width: newSize.width, height: frame.size.height))
            isApplyingManagedFrameSize = false
        }

        let oldBase = baseContentHeight
        recalcOverscroll(
            for: scrollView,
            fallbackBaseHeight: newSize.height,
            targetWidth: newSize.width,
            forceLayout: widthChanged
        )

        if hadPending {
            if oldBase == baseContentHeight {
                // Data was stale — restore flag for async fallback
                pendingContentShrink = true
            }
            allowFrameShrink = false
        }
    }
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        applyBlockImageCaretPolicy()
        DispatchQueue.main.async { [weak self] in self?.fixPhantomTrailingCaret() }
    }

    private func applyBlockImageCaretPolicy() {
        let indicators = subviews.filter { type(of: $0) == NSTextInsertionIndicator.self }
        guard !indicators.isEmpty else { return }

        var hide = false
        var resize = false
        if let ts = textStorage {
            let sel = selectedRange()
            if sel.length != 0 || sel.location > ts.length {
                hide = true
            } else if sel.location < ts.length {
                let paraRange = (ts.string as NSString).paragraphRange(
                    for: NSRange(location: sel.location, length: 0)
                )
                ts.enumerateAttribute(.latexIsBlock, in: paraRange, options: []) { value, range, stop in
                    guard value as? Bool == true else { return }
                    if ts.attribute(.latexBlockOffsetY, at: range.location, effectiveRange: nil) != nil {
                        resize = true
                    } else {
                        hide = true
                        stop.pointee = true
                    }
                }
            }
        }

        for sub in indicators {
            if !hide && resize { resizeIndicatorToLayoutCaret(sub) }
            if sub.isHidden != hide { sub.isHidden = hide }
        }
    }

    // After collapsed→visible, the indicator frame stays at image height;
    // snap it to the layout manager's actual caret rect.
    private func resizeIndicatorToLayoutCaret(_ indicator: NSView) {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let docLoc = tcs.location(tcs.documentRange.location, offsetBy: selectedRange().location) else { return }
        var layoutRect: CGRect?
        tlm.enumerateTextSegments(in: NSTextRange(location: docLoc), type: .standard, options: [.rangeNotRequired]) { _, f, _, _ in
            layoutRect = f; return false
        }
        guard let r = layoutRect, r.height > 0,
              indicator.frame.height > r.height + 1 else { return }
        isApplyingCaretShift = true
        indicator.frame = CGRect(x: indicator.frame.origin.x, y: r.origin.y,
                                 width: indicator.frame.width, height: r.height)
        isApplyingCaretShift = false
    }

    private func fixPhantomTrailingCaret() {
        if let indicator = subviews.first(where: { type(of: $0) == NSTextInsertionIndicator.self }),
           observedCaretIndicator !== indicator {
            caretIndicatorObservation?.invalidate()
            observedCaretIndicator = indicator
            caretIndicatorObservation = indicator.observe(\.frame, options: [.new]) { [weak self] _, _ in
                guard let self, !self.isApplyingCaretShift else { return }
                self.applyBlockImageCaretPolicy()
                self.fixPhantomTrailingCaret()
            }
        }
        guard let ts = textStorage, let indicator = observedCaretIndicator,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
        let sel = selectedRange()
        let ns = ts.string as NSString
        guard sel.length == 0, sel.location == ns.length, ns.length > 0,
              ns.character(at: ns.length - 1) == 0x0A,
              ns.length < 2 || ns.character(at: ns.length - 2) == 0x0A,
              let docLoc = tcs.location(tcs.documentRange.location, offsetBy: sel.location) else { return }

        var targetY: CGFloat = 0
        tlm.enumerateTextSegments(in: NSTextRange(location: docLoc), type: .standard) { _, f, _, _ in
            targetY = f.origin.y; return false
        }
        // self.font can return a stale small-point font here; read spacing from the paragraph style.
        let style = (ts.attribute(.paragraphStyle, at: sel.location - 1, effectiveRange: nil)
                     ?? typingAttributes[.paragraphStyle]) as? NSParagraphStyle
        let desiredY = targetY + (style?.paragraphSpacing ?? 0)
        guard abs(indicator.frame.origin.y - desiredY) >= 0.5 else { return }

        isApplyingCaretShift = true
        indicator.frame.origin.y = desiredY
        isApplyingCaretShift = false
    }

    deinit { caretIndicatorObservation?.invalidate() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Forward appearance changes to the embedder-supplied syntax highlighter
        // via the notification name it registered. The engine doesn't know any
        // app-specific notification names; this hook is opt-in per highlighter.
        if let name = configuration.services.syntaxHighlighter.appearanceDidChangeNotification {
            NotificationCenter.default.post(name: name, object: self)
        }
    }

    private func measuredBaseContentHeight(
        fallback: CGFloat,
        minimumHeight: CGFloat,
        forceLayout: Bool
    ) -> CGFloat {
        let minimumContentHeight = ceil(max(minimumHeight, 0) + (textContainerInset.height * 2))
        let normalizedFallback = max(ceil(fallback), minimumContentHeight)
        guard let textLayoutManager else { return normalizedFallback }

        if forceLayout {
            textLayoutManager.enumerateTextLayoutFragments(
                from: textLayoutManager.documentRange.endLocation,
                options: [.reverse, .ensuresLayout]
            ) { _ in
                return false  // stop after the last fragment
            }
        }

        let usageBounds = textLayoutManager.usageBoundsForTextContainer
        let measuredHeight = ceil(max(usageBounds.height, usageBounds.maxY) + (textContainerInset.height * 2))
        // Shrink failsafe: when AppKit hands us an authoritative `setFrameSize`
        // height (via `fallback`) that is smaller than TextKit 2's still-stale
        // `usageBoundsForTextContainer` cache, trust AppKit. Zero extra cost.
        if allowFrameShrink, normalizedFallback < measuredHeight {
            return max(normalizedFallback, minimumContentHeight)
        }
        return max(measuredHeight, minimumContentHeight)
    }

    private func resolvedBaseContentHeight(for proposedHeight: CGFloat) -> CGFloat {
        let normalizedHeight = max(ceil(proposedHeight), 0)
        guard baseContentHeight > 0 else { return normalizedHeight }
        guard normalizedHeight < baseContentHeight - 0.5 else {
            // Grow / equal: keep the settle-shrink flag set so we still catch
            return normalizedHeight
        }
        // forceShrinkUntilSettled overrides everything (file-switch / app-start).
        if forceShrinkUntilSettled {
            forceShrinkUntilSettled = false
            return normalizedHeight
        }
        if let coord = delegate as? NativeTextViewCoordinator, coord.suppressFrameShrink {
            return baseContentHeight
        }
        if allowFrameShrink {
            allowFrameShrink = false
            return normalizedHeight
        }
        return baseContentHeight
    }

    private func applyManagedFrameSize(width: CGFloat) {
        let contentHeight = max(ceil(baseContentHeight + activeBottomOverscroll), 0)
        let scrollViewHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let targetSize = NSSize(
            width: max(width, 0),
            height: max(contentHeight, scrollViewHeight)
        )
        guard abs(targetSize.width - frame.size.width) > 0.5 || abs(targetSize.height - frame.size.height) > 0.5 else {
            return
        }
        isApplyingManagedFrameSize = true
        super.setFrameSize(targetSize)
        isApplyingManagedFrameSize = false
    }
}
