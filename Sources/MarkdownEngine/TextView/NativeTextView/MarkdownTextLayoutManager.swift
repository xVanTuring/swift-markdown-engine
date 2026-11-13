//
//  MarkdownTextLayoutManager.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) The selection highlight leaves rendered blocks to draw
//  their own.
//
//  A rendered table / block formula is one line of text as far as TextKit
//  knows: an anchor character as wide as the block, on a line as tall as it
//  plus its spacing. Selected, the system highlight painted that whole line —
//  from the paragraph above to the one below, the full width of the text
//  column, past a rounded table's corners and short of a wide table's ends.
//  The highlight is drawn from the `.selection` segments this class hands out,
//  so segments that start inside a selected collapsed block are left out
//  (`selectionHighlightExclusions`, kept up to date by `NativeTextView`); the
//  block paints its own highlight behind its image, in its own shape
//  (`MarkdownTextLayoutFragment.drawLatexImages`, `WideTableOverlay`).
//

import AppKit

final class MarkdownTextLayoutManager: NSTextLayoutManager {
    /// Document ranges whose `.selection` segments are not reported: the
    /// collapsed rendered blocks inside the current (non-empty) selection.
    var selectionHighlightExclusions: [NSRange] = []

    override func enumerateTextSegments(
        in textRange: NSTextRange,
        type: NSTextLayoutManager.SegmentType,
        options: NSTextLayoutManager.SegmentOptions = [],
        using block: (NSTextRange?, CGRect, CGFloat, NSTextContainer) -> Bool
    ) {
        let exclusions = selectionHighlightExclusions
        guard type == .selection, !exclusions.isEmpty else {
            super.enumerateTextSegments(in: textRange, type: type, options: options, using: block)
            return
        }
        let origin = documentRange.location
        // The ranges are needed to tell the block's segments apart, whatever
        // the caller asked for.
        super.enumerateTextSegments(in: textRange, type: type, options: options.subtracting(.rangeNotRequired)) {
            range, frame, baseline, container in
            if let range {
                let start = offset(from: origin, to: range.location)
                if exclusions.contains(where: { NSLocationInRange(start, $0) }) { return true }
            }
            return block(range, frame, baseline, container)
        }
    }
}
