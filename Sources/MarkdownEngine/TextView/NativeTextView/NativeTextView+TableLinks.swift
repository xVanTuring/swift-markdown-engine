//
//  NativeTextView+TableLinks.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) Links inside table cells. A table is one rendered image,
//  so its links are not text the view can click: a press is mapped to a cell
//  and then to the link text drawn there (`TableGeometry.link(at:)`), and the
//  link is followed the way one in body text is — a `[[…]]` through
//  `onLinkClick`, a URL through NSWorkspace. A press anywhere else in the cell
//  still opens it for editing, and so does an Option-click on a link (a cell
//  that is nothing but a link can be edited that way, or with the keyboard).
//  A link the resolver gave a hover text (`[[Book#page=12]]`, shown as `p.12`)
//  shows it as a tooltip, as in body text.
//

import AppKit

// MARK: - Hover texts

/// (fork: xVanTuring) The hover texts over one table image's links, as tooltip
/// rects of the view that shows the image. Registered for the whole table at
/// once, not for the link under the pointer: AppKit starts a tooltip when the
/// pointer ENTERS its rect, so the rects have to be there before it reaches a link.
final class TableLinkToolTips: NSObject, NSViewToolTipOwner {
    private var texts: [NSView.ToolTipTag: String] = [:]
    /// The layout and the place the registered rects were computed for.
    private weak var geometry: TableGeometry?
    private var origin: CGPoint?
    /// What is registered, in the view's coordinates.
    private(set) var registered: [(rect: CGRect, text: String)] = []

    /// Registers `geometry`'s hover texts in `view`, the image placed with its
    /// top-left corner at `origin` in a flipped view (its bottom-left corner in
    /// an unflipped one). The same layout at the same place is left alone.
    func show(_ geometry: TableGeometry, at origin: CGPoint, in view: NSView) {
        if self.geometry === geometry, self.origin == origin { return }
        clear(in: view)
        self.geometry = geometry
        self.origin = origin
        for run in geometry.linkRuns() {
            guard let text = run.toolTip, !text.isEmpty else { continue }
            var rect = run.rect.offsetBy(dx: origin.x, dy: origin.y)
            if !view.isFlipped {
                rect.origin.y = origin.y + geometry.imageSize.height - run.rect.maxY
            }
            texts[view.addToolTip(rect, owner: self, userData: nil)] = text
            registered.append((rect, text))
        }
    }

    func clear(in view: NSView) {
        guard origin != nil else { return }
        for tag in texts.keys { view.removeToolTip(tag) }
        texts = [:]
        registered = []
        geometry = nil
        origin = nil
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        texts[tag] ?? ""
    }
}

extension NativeTextView {

    // MARK: Lookup

    /// The narrow (non-scrolling) table image under `point` (view
    /// coordinates): its layout, the point in its top-down coordinates, and
    /// its anchor character. Wide tables live in an overlay, see
    /// `wideTableLinkHit(atWindowPoint:)`. Runs on every mouse move over the
    /// document, so it stays within the line under the pointer.
    func narrowTableHit(at point: NSPoint)
        -> (geometry: TableGeometry, imagePoint: CGPoint, origin: CGPoint, anchor: Int)? {
        guard let storage = textStorage, storage.length > 0,
              let tlm = textLayoutManager,
              let tcs = tlm.textContentManager as? NSTextContentStorage else { return nil }
        let containerPoint = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        // The image is drawn in the line of its anchor character, which is as
        // tall as the image: the fragment under the point holds the anchor.
        guard let fragment = tlm.textLayoutFragment(for: containerPoint) else { return nil }
        let start = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.location)
        let end = tcs.offset(from: tcs.documentRange.location, to: fragment.rangeInElement.endLocation)
        guard start != NSNotFound, end > start,
              let rendered = renderedTable(in: NSRange(location: start, length: end - start)),
              storage.attribute(.scrollableBlockSourceID, at: rendered.anchor.location, effectiveRange: nil) == nil,
              let origin = narrowTableImageOrigin(image: rendered.image, anchor: rendered.anchor) else { return nil }
        let imagePoint = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x <= rendered.image.size.width, imagePoint.y <= rendered.image.size.height else { return nil }
        return (rendered.geometry, imagePoint, origin, rendered.anchor.location)
    }

    /// Keeps the hover texts of the narrow table under the pointer registered
    /// (and only those). Called on every mouse move over the view.
    func updateTableLinkToolTips(atWindowPoint windowPoint: NSPoint) {
        if let hit = narrowTableHit(at: convert(windowPoint, from: nil)) {
            tableLinkToolTips.show(hit.geometry, at: hit.origin, in: self)
        } else {
            tableLinkToolTips.clear(in: self)
        }
    }

    /// The link under a point in a wide table's overlay (window coordinates).
    /// The overlay's horizontal scroller is not part of the table.
    func wideTableLinkHit(atWindowPoint windowPoint: NSPoint) -> TableCellLink? {
        for (_, overlay) in wideTableOverlays where overlay.superview != nil && !overlay.isHidden {
            guard overlay.bounds.contains(overlay.convert(windowPoint, from: nil)) else { continue }
            if let scroller = overlay.horizontalScroller, !scroller.isHidden,
               scroller.bounds.contains(scroller.convert(windowPoint, from: nil)) { return nil }
            guard let geometry = overlay.currentImage?.tableGeometry else { return nil }
            let imageView = overlay.tableImageViewForEditing
            let local = imageView.convert(windowPoint, from: nil)
            // The overlay's image view is not flipped; the geometry is top-down.
            return geometry.link(at: CGPoint(x: local.x, y: imageView.bounds.height - local.y))
        }
        return nil
    }

    /// The link in a table cell under a point in window coordinates, narrow or wide.
    func tableLink(atWindowPoint windowPoint: NSPoint) -> TableCellLink? {
        if let link = wideTableLinkHit(atWindowPoint: windowPoint) { return link }
        guard let hit = narrowTableHit(at: convert(windowPoint, from: nil)) else { return nil }
        return hit.geometry.link(at: hit.imagePoint)
    }

    /// The pointer is over a link in a table cell (pointing-hand cursor).
    func isOverTableLink(_ event: NSEvent) -> Bool {
        tableLink(atWindowPoint: event.locationInWindow) != nil
    }

    /// A press that follows a link: a single click with no modifier. Option
    /// (and the others) leave the press to the cell under it.
    static func isPlainTableLinkClick(_ event: NSEvent) -> Bool {
        event.clickCount == 1
            && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }

    // MARK: Following

    /// A press on a link in a narrow table's cell. Returns false when the
    /// press is not on one (the caller goes on to open the cell).
    func followTableLinkIfHit(event: NSEvent) -> Bool {
        guard Self.isPlainTableLinkClick(event) else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = narrowTableHit(at: point),
              let link = hit.geometry.link(at: hit.imagePoint),
              let cell = hit.geometry.cell(at: hit.imagePoint),
              let token = tableToken(containing: hit.anchor) else { return false }
        let geometry = hit.geometry
        let origin = hit.origin
        followTableLinkPress(link, tableStart: token.range.location, anchor: cell) { [weak self] event in
            guard let self else { return nil }
            let p = self.convert(event.locationInWindow, from: nil)
            return geometry.nearestCell(to: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
        }
        return true
    }

    /// Runs a press that began on `link` until the button comes up, and
    /// follows the link if it comes up over the same link — a press dragged
    /// off it does nothing, as with a button. In an editable table a drag into
    /// another cell selects cells, as from anywhere else in a cell.
    func followTableLinkPress(
        _ link: TableCellLink,
        tableStart: Int,
        anchor: (row: Int, column: Int),
        nearestCell: @escaping (NSEvent) -> (row: Int, column: Int)?
    ) {
        guard let window else { return }
        var release: NSPoint?
        if canSelectTableCells {
            if trackTableCellSelection(tableStart: tableStart, anchor: anchor, cellAt: nearestCell) { return }
            // The tracker dequeued the release, which makes it the current event.
            if let up = NSApp.currentEvent, up.type == .leftMouseUp { release = up.locationInWindow }
        } else {
            while let event = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture, inMode: .eventTracking, dequeue: true
            ) {
                if event.type == .leftMouseUp { release = event.locationInWindow; break }
            }
        }
        finishTableLinkPress(link, releasedAt: release ?? window.mouseLocationOutsideOfEventStream)
    }

    /// The end of a press that began on `link`: follows it when the button
    /// came up over the same link (window coordinates). Returns whether it did.
    @discardableResult
    func finishTableLinkPress(_ link: TableCellLink, releasedAt windowPoint: NSPoint) -> Bool {
        guard tableLink(atWindowPoint: windowPoint) == link else { return false }
        openTableLink(link)
        return true
    }

    /// Follows a table cell's link as a click on the same link in body text
    /// would (`NativeTextViewCoordinator.textView(_:clickedOnLink:at:)`).
    func openTableLink(_ link: TableCellLink) {
        // A cell open in the editor is written back first: following the link
        // may take the document away.
        if tableEditSession != nil { endTableCellEditing(restoreFocus: true) }
        switch link {
        case .wiki(let target):
            guard let coordinator = delegate as? NativeTextViewCoordinator else { return }
            coordinator.isWikiLinkActive = false
            DispatchQueue.main.async {
                coordinator.onLinkClick?(target)
            }
        case .url(let url):
            NSWorkspace.shared.open(url)
        }
    }
}
