//
//  NativeTextView+CalloutFold.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) A click on a foldable callout's header icon (chevron +
//  icon, `CalloutFoldTarget`) folds or unfolds it — view state only, the text
//  is not edited and the caret does not move.
//

import AppKit

extension NativeTextView {

    /// The fold target under `containerPoint`, searched in the line fragment there only.
    func calloutFoldHit(at containerPoint: CGPoint) -> (target: CalloutFoldTarget, range: NSRange)? {
        guard let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage,
              let fragment = tlm.textLayoutFragment(for: containerPoint),
              let storage = textStorage, storage.length > 0,
              let bridge = layoutBridge, let container = textContainer else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start != NSNotFound, end > start, end <= storage.length else { return nil }
        var hit: (CalloutFoldTarget, NSRange)?
        storage.enumerateAttribute(.calloutFoldTarget, in: NSRange(location: start, length: end - start)) { value, range, stop in
            guard let target = value as? CalloutFoldTarget else { return }
            let anchor = bridge.boundingRect(forCharacterRange: range, in: container)
            // The icon image is as wide as its `.latexBounds`, drawn from the anchor's origin.
            let image = (storage.attribute(.latexBounds, at: range.location, effectiveRange: nil) as? NSValue)?.rectValue ?? .zero
            let rect = CGRect(x: anchor.minX, y: anchor.minY,
                              width: max(anchor.width, image.width), height: max(anchor.height, image.height))
            if rect.insetBy(dx: -2, dy: -2).contains(containerPoint) {
                hit = (target, range)
                stop.pointee = true
            }
        }
        return hit
    }

    func isOverCalloutFold(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        return calloutFoldHit(at: CGPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)) != nil
    }

    /// Folds / unfolds when the click is on a fold target; true when it was.
    func toggleCalloutFoldIfHit(event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = calloutFoldHit(at: CGPoint(x: p.x - textContainerOrigin.x, y: p.y - textContainerOrigin.y)),
              let coordinator = delegate as? NativeTextViewCoordinator else { return false }
        coordinator.toggleCalloutFold(hit.target, at: hit.range.location, in: self)
        return true
    }
}
