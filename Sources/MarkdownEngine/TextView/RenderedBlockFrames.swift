//
//  RenderedBlockFrames.swift
//  MarkdownEngine
//
//  Where the engine currently draws block images (rendered `$$…$$`, standalone images, fenced blocks drawn by a
//  `FencedBlockRenderer`), so an embedder can lay a live view over one — a plot the reader can rotate, say.
//

import AppKit

/// A block image the engine draws, in the text view's own (flipped) coordinates.
public struct RenderedBlockFrame: Sendable, Equatable {
    /// The source run the image hangs on (for a fenced block: its first content character).
    public let anchor: NSRange
    public let frame: CGRect
}

public extension NSTextView {

    /// The block images drawn in the paragraphs touching `range` (whole document by default), top to bottom.
    /// Forces layout of that stretch. Only images whose source is currently collapsed appear — a block whose
    /// source is being edited is not in the list.
    func renderedBlockFrames(in range: NSRange? = nil) -> [RenderedBlockFrame] {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager as? NSTextContentStorage else { return [] }
        let total = (string as NSString).length
        let target = range.map { NSIntersectionRange($0, NSRange(location: 0, length: total)) }
            ?? NSRange(location: 0, length: total)
        guard let start = content.location(content.documentRange.location, offsetBy: target.location) else { return [] }

        var found: [RenderedBlockFrame] = []
        let origin = textContainerOrigin
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            guard let fragment = fragment as? MarkdownTextLayoutFragment else { return true }
            let first = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if first > NSMaxRange(target) { return false }
            let frame = fragment.layoutFragmentFrame
            for item in fragment.blockImageFrames(at: .zero) {
                found.append(RenderedBlockFrame(
                    anchor: item.range,
                    frame: item.rect.offsetBy(dx: origin.x + frame.origin.x, dy: origin.y + frame.origin.y)))
            }
            return true
        }
        return found
    }
}
