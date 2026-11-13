//
//  NativeTextView+RenderedBlockSelection.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) A text selection never ends inside a rendered block.
//
//  A rendered table / block formula hides its source: every character is
//  collapsed to zero width except one anchor whose advance is the whole block
//  (see `MarkdownStyler.emitCollapsedAttrs`). Hit-testing a drag that ends over
//  the block lands before or after that one wide anchor — whichever half the
//  pointer is in — so the selection started mid-block and the highlight covered
//  the right half of the table plus the rows below it, an arbitrary rectangle
//  that matches nothing on screen (worst over a wide table, whose overlay is
//  transparent). The same happened dragging down into a table from above.
//
//  Fix: a non-empty selection that reaches into such a block takes the whole
//  block — the table is either selected as a unit or not at all. A caret
//  (empty selection) is left alone: clicking into a table still places the caret
//  / starts cell editing as before. Blocks shown with their source visible
//  (`.visibleSource`) are ordinary text and are not snapped.
//
//  A block inside the selection is not painted by the system highlight (which
//  would cover its whole line, gaps and all): `MarkdownTextLayoutManager`
//  leaves it out and the block draws a highlight of its own shape behind its
//  image (`MarkdownTextLayoutFragment.drawLatexImages`, `WideTableOverlay`).
//

import AppKit

extension NativeTextView {

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let snapped = ranges.map { value -> NSValue in
            let range = value.rangeValue
            guard range.length > 0, let full = expandedOverRenderedBlocks(range) else { return value }
            return NSValue(range: full)
        }
        // Before super: the highlight is computed while the selection is set.
        let blocks = collapsedRenderedBlocks(inside: snapped.map(\.rangeValue))
        (textLayoutManager as? MarkdownTextLayoutManager)?.selectionHighlightExclusions =
            blocks.map(withAdjacentBlankLines)
        super.setSelectedRanges(snapped, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateWideTableSelectionHighlights(selectedBlocks: blocks)
    }

    /// The collapsed rendered blocks wholly inside the non-empty `ranges`.
    func collapsedRenderedBlocks(inside ranges: [NSRange]) -> [NSRange] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var blocks: [NSRange] = []
        for range in ranges where range.length > 0 && NSMaxRange(range) <= storage.length {
            storage.enumerateAttribute(.renderedBlockRange, in: range, options: []) { value, run, _ in
                guard let block = (value as? NSValue)?.rangeValue,
                      block.location >= range.location, NSMaxRange(block) <= NSMaxRange(range),
                      blocks.last != block,
                      collapsedRenderedBlock(containing: block.location, in: storage) == block else { return }
                blocks.append(block)
            }
        }
        return blocks
    }

    /// `block` plus the empty lines right above and below it. They are the
    /// space around the block: highlighted, they showed as full-width bars
    /// above and below its own highlight. The newline ending the text line
    /// above is not one of them — that line keeps its highlight to the edge.
    func withAdjacentBlankLines(_ block: NSRange) -> NSRange {
        guard let storage = textStorage else { return block }
        let text = storage.string as NSString
        let newline = unichar(10)
        var start = block.location
        while start >= 2, text.character(at: start - 1) == newline, text.character(at: start - 2) == newline {
            start -= 1
        }
        if start == 1, text.character(at: 0) == newline { start = 0 }
        var end = NSMaxRange(block)
        while end < text.length, text.character(at: end) == newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether `range` (a block's anchor run) lies in a non-empty selection.
    func isInNonEmptySelection(_ range: NSRange) -> Bool {
        selectedRanges.contains { value in
            let s = value.rangeValue
            return s.length > 0 && NSIntersectionRange(s, range).length > 0
        }
    }

    /// The colour the system paints a selection in, for this view right now.
    var selectionHighlightColor: NSColor {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        return focused ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor
    }

    /// A wide table draws in its own overlay, above the text: tint the
    /// overlay's panel when its table is in the selection.
    func updateWideTableSelectionHighlights(selectedBlocks: [NSRange]? = nil) {
        guard !wideTableOverlays.isEmpty else { return }
        let blocks = selectedBlocks ?? collapsedRenderedBlocks(inside: selectedRanges.map(\.rangeValue))
        let color = selectionHighlightColor
        for overlay in wideTableOverlays.values {
            let at = overlay.anchorTextLocation
            let selected = blocks.contains { NSLocationInRange(at, $0) }
            overlay.setSelectionHighlight(selected ? color : nil)
        }
    }

    /// `range` grown to cover every collapsed rendered block it only partly
    /// covers; nil when nothing changes.
    func expandedOverRenderedBlocks(_ range: NSRange) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var start = range.location
        var end = NSMaxRange(range)
        // An endpoint strictly inside a block pulls the range out to the block's
        // edge. Only the two endpoints matter: blocks between them are already
        // wholly selected.
        if let block = collapsedRenderedBlock(containing: start, in: storage),
           block.location < start {
            start = block.location
        }
        if end > 0, let block = collapsedRenderedBlock(containing: end - 1, in: storage),
           NSMaxRange(block) > end {
            end = NSMaxRange(block)
        }
        guard start != range.location || end != NSMaxRange(range) else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The rendered-block range around `index` when that block currently shows
    /// its rendering in place of its source (a collapsed anchor with an image).
    private func collapsedRenderedBlock(containing index: Int, in storage: NSTextStorage) -> NSRange? {
        guard index >= 0, index < storage.length,
              let block = (storage.attribute(.renderedBlockRange, at: index, effectiveRange: nil) as? NSValue)?
                .rangeValue,
              block.length > 0, NSMaxRange(block) <= storage.length else { return nil }
        var collapsed = false
        storage.enumerateAttribute(.latexImage, in: block, options: []) { value, run, stop in
            guard value != nil,
                  (storage.attribute(.latexIsBlock, at: run.location, effectiveRange: nil) as? Bool) == true,
                  let color = storage.attribute(.foregroundColor, at: run.location, effectiveRange: nil) as? NSColor,
                  color.alphaComponent == 0 else { return }
            collapsed = true
            stop.pointee = true
        }
        return collapsed ? block : nil
    }
}
