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
        super.setSelectedRanges(snapped, affinity: affinity, stillSelecting: stillSelectingFlag)
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
