//
//  WideTableOverlay.swift
//  MarkdownEngine
//
//  NSScrollView subview of NativeTextView hosting a wide-table image with
//  native horizontal scrolling. Sidesteps TextKit 2's fragment surface
//  cache that defeats in-fragment custom scrolling.
//

import AppKit

// MARK: - Faint scroller

/// Legacy scroller with a fainter knob.
final class SubtleScroller: NSScroller {
    override func drawKnobSlot(in slot: NSRect, highlight: Bool) {
        // Transparent track — only the knob is drawn.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let thickness: CGFloat = 5
        let pill = knob.insetBy(dx: 2, dy: max(0, (knob.height - thickness) / 2))
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setFill()   // ← faintness; tweak here
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    }
}

// MARK: - Overlay view

final class WideTableOverlay: NSScrollView {

    /// Hash of table source; key for offset persistence + reconcile lookup.
    let sourceID: Int

    /// Document index of the table anchor; click on image moves caret here.
    var anchorTextLocation: Int

    /// Weak parent ref for offset persistence + caret forwarding.
    weak var ownerTextView: NativeTextView?

    /// Table's left-edge offset (breakout: text-column left); scrollable space.
    var leftContentInset: CGFloat = 0 {
        didSet {
            guard abs(contentInsets.left - leftContentInset) > 0.5 else { return }
            contentInsets = NSEdgeInsets(top: 0, left: leftContentInset, bottom: 0, right: 0)
            updatePanelMask()
        }
    }

    private let tableImageView: WideTableImageView

    /// The view holding the table image, for placing a cell editor over it.
    var tableImageViewForEditing: NSView { tableImageView }

    /// The image the overlay is showing right now.
    var currentImage: NSImage? { tableImageView.image }

    init(sourceID: Int, image: NSImage, ownerTextView: NativeTextView, anchorLocation: Int) {
        self.sourceID = sourceID
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.tableImageView = WideTableImageView(frame: CGRect(origin: .zero, size: image.size))
        tableImageView.image = image
        tableImageView.imageScaling = .scaleNone
        tableImageView.imageAlignment = .alignTopLeft

        super.init(frame: .zero)

        hasHorizontalScroller = true
        hasVerticalScroller = false
        // Auto-hide: only show the scroller when the table actually overflows.
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // Legacy scroller, fainter knob (see SubtleScroller).
        scrollerStyle = .legacy
        let subtleScroller = SubtleScroller()
        subtleScroller.scrollerStyle = .legacy
        horizontalScroller = subtleScroller
        horizontalScrollElasticity = .allowed
        verticalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        horizontalScroller?.controlSize = .small
        automaticallyAdjustsContentInsets = false

        documentView = tableImageView
        tableImageView.ownerOverlay = self

        // The cell editor sits over the table image, so it follows every scroll.
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidScroll),
            name: NSView.boundsDidChangeNotification, object: contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didLiveScrollNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollOffsetDidChange),
            name: NSScrollView.didEndLiveScrollNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Clamp vertical scroll to 0 on every layout — kills sub-pixel wobble.
    override func tile() {
        super.tile()
        let origin = contentView.bounds.origin
        if origin.y != 0 {
            contentView.scroll(to: NSPoint(x: origin.x, y: 0))
            reflectScrolledClipView(contentView)
        }
        updatePanelMask()
    }

    /// `.rounded` tables (fork): the visible part of the table keeps the
    /// panel's rounded corners while the table scrolls inside it — without
    /// this the cut-off edge would be square. The clip view is trimmed to the
    /// table's height (the scroller strip below it is a few points taller than
    /// the scroller) and rounds its own corners. Not applied in reading-width
    /// breakout, where the table starts at a scrollable inset.
    func updatePanelMask() {
        let radius = tableImageView.image?.tableGeometry?.style.metrics.cornerRadius ?? 0
        guard radius > 0, leftContentInset < 0.5, let image = tableImageView.image else {
            if let layer = contentView.layer, layer.cornerRadius != 0 {
                layer.cornerRadius = 0
                layer.masksToBounds = false
            }
            return
        }
        var clip = contentView.frame
        let height = min(image.size.height, bounds.height)
        if abs(clip.height - height) > 0.25 {
            if !isFlipped { clip.origin.y = clip.maxY - height }
            clip.size.height = height
            contentView.frame = clip
        }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }
        if layer.cornerRadius != radius {
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
        }
        if !layer.masksToBounds { layer.masksToBounds = true }
    }

    /// Who a trackpad gesture scrolls: the table, or the document around it.
    enum ScrollTarget { case table, document }

    /// The current gesture's target; nil until it has moved.
    private(set) var gestureTarget: ScrollTarget?
    /// The gesture's events from before it moved (touch down, a still `began`),
    /// held until its first movement says where they go.
    private var eventsBeforeMovement: [NSEvent] = []

    /// A horizontal gesture scrolls the table, anything else the document.
    ///
    /// A trackpad gesture is decided once, by its first movement, and every
    /// event of it goes the same way: touch down, the fingers lifting and the
    /// momentum after. A scroll view drops momentum unless it saw the whole
    /// gesture, so routing event by event (the lift and touch down carry no
    /// delta, and went to the document) left a flicked table stopping dead
    /// the moment the fingers lifted. A mouse wheel has no gesture: each notch
    /// goes by its own axis.
    override func scrollWheel(with event: NSEvent) {
        guard !event.phase.isEmpty || !event.momentumPhase.isEmpty else {
            deliver(event, to: Self.target(of: event))
            return
        }
        if event.phase.contains(.mayBegin) {
            gestureTarget = nil
            eventsBeforeMovement = [event]
            return
        }
        if event.phase.contains(.began) {
            gestureTarget = nil
        }
        if gestureTarget == nil {
            let moved = event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0
            let ends = !event.phase.isDisjoint(with: [.ended, .cancelled]) || !event.momentumPhase.isEmpty
            guard moved || ends else {
                eventsBeforeMovement.append(event)
                return
            }
            // A touch that never moved goes to the document, which owns the page.
            let target = moved ? Self.target(of: event) : .document
            gestureTarget = target
            let held = eventsBeforeMovement
            eventsBeforeMovement = []
            held.forEach { deliver($0, to: target) }
        }
        deliver(event, to: gestureTarget ?? .document)
    }

    private static func target(of event: NSEvent) -> ScrollTarget {
        abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? .table : .document
    }

    private func deliver(_ event: NSEvent, to target: ScrollTarget) {
        switch target {
        case .table: super.scrollWheel(with: event)
        case .document: nextResponder?.scrollWheel(with: event)
        }
    }


    /// Swap the rendered image after a restyle regenerated it.
    func updateImage(_ image: NSImage) {
        if tableImageView.image !== image {
            tableImageView.image = image
            tableImageView.frame = CGRect(origin: .zero, size: image.size)
            updatePanelMask()
        }
    }

    var horizontalOffset: CGFloat {
        get { contentView.bounds.origin.x }
        set {
            contentView.scroll(to: NSPoint(x: max(0, newValue), y: 0))
            reflectScrolledClipView(contentView)
        }
    }

    @objc private func contentDidScroll() {
        guard let owner = ownerTextView, owner.tableEditSession != nil else { return }
        owner.layoutTableCellEditor()
    }

    @objc private func scrollOffsetDidChange() {
        ownerTextView?.tableHorizontalScrollOffsets[sourceID] = horizontalOffset
    }
}

// MARK: - Document view inside the overlay

/// Forwards mouseDown to caret-into-table (so clicking switches to edit mode).
final class WideTableImageView: NSImageView {

    weak var ownerOverlay: WideTableOverlay?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    /// Shows the row / column grips of the cell under the pointer.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let overlay = ownerOverlay, let textView = overlay.ownerTextView,
              textView.showsTableGrips,
              let geometry = image?.tableGeometry,
              let token = textView.tableToken(containing: overlay.anchorTextLocation) else { return }
        let local = convert(event.locationInWindow, from: nil)
        if let cell = geometry.cell(at: CGPoint(x: local.x, y: bounds.height - local.y)) {
            textView.showTableGrips(tableStart: token.range.location, row: cell.row, column: cell.column)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let overlay = ownerOverlay,
              let textView = overlay.ownerTextView else {
            super.mouseDown(with: event)
            return
        }
        let location = overlay.anchorTextLocation
        let docLen = (textView.string as NSString).length
        guard location >= 0, location <= docLen else {
            super.mouseDown(with: event)
            return
        }
        if textView.canEditTablesInPlace,
           let image = image, let geometry = image.tableGeometry,
           let token = textView.tableToken(containing: location) {
            // This view is not flipped; the geometry is top-down.
            let local = convert(event.locationInWindow, from: nil)
            let imagePoint = CGPoint(x: local.x, y: bounds.height - local.y)
            if let cell = geometry.cell(at: imagePoint) {
                if textView.canSelectTableCells {
                    let dragged = textView.trackTableCellSelection(
                        tableStart: token.range.location, anchor: cell
                    ) { [weak self] drag in
                        guard let self else { return nil }
                        let p = self.convert(drag.locationInWindow, from: nil)
                        return geometry.nearestCell(to: CGPoint(x: p.x, y: self.bounds.height - p.y))
                    }
                    if dragged { return }
                }
                if textView.beginTableCellEditing(tableStart: token.range.location, row: cell.row, column: cell.column) {
                    return
                }
            }
        }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    /// Right-click opens the cell under the pointer and shows its row / column menu.
    override func rightMouseDown(with event: NSEvent) {
        guard let overlay = ownerOverlay, let textView = overlay.ownerTextView,
              textView.canEditTablesInPlace,
              let geometry = image?.tableGeometry,
              let token = textView.tableToken(containing: overlay.anchorTextLocation) else {
            super.rightMouseDown(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        let imagePoint = CGPoint(x: local.x, y: bounds.height - local.y)
        guard let cell = geometry.cell(at: imagePoint),
              textView.beginTableCellEditing(tableStart: token.range.location, row: cell.row, column: cell.column),
              let editor = textView.tableEditSession?.editor,
              let menu = editor.menu(for: event) else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: editor)
    }
}

// MARK: - NativeTextView reconcile extension

extension NativeTextView {

    /// Coalesce overlay updates to one per runloop tick (resize fires bursts).
    /// The first run is synchronous to avoid a load flash.
    /// Width-change restyles can reconcile immediately so the visible overlay
    /// never trails the storage attributes by one resize turn.
    func updateWideTableOverlays(
        immediately: Bool = false,
        layoutAlreadySettled: Bool = false,
        knownWideTableAnchorRanges: [NSRange]? = nil
    ) {
        if immediately || wideTableOverlays.isEmpty {
            pendingWideTableOverlayUpdate = false
            performWideTableOverlayUpdate(
                layoutAlreadySettled: layoutAlreadySettled,
                knownWideTableAnchorRanges: knownWideTableAnchorRanges
            )
            return
        }
        if pendingWideTableOverlayUpdate { return }
        pendingWideTableOverlayUpdate = true
        RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
            guard let self else { return }
            guard self.pendingWideTableOverlayUpdate else { return }
            self.pendingWideTableOverlayUpdate = false
            self.performWideTableOverlayUpdate()
        }
    }

    /// Cheap per-frame overlay reposition on width change (no layout) — keeps tables glued to the text during resize.
    func repositionWideTableOverlaysForWidthChange(insetDelta: CGFloat) {
        guard configuration.readingWidth != nil, !wideTableOverlays.isEmpty else { return }
        // Overlays live in the full-width reading-column container; span its visible width.
        let hostBounds = (superview ?? self).bounds
        for (_, overlay) in wideTableOverlays {
            var f = overlay.frame
            f.origin.x = hostBounds.minX
            f.size.width = hostBounds.width
            overlay.frame = f
            overlay.leftContentInset = max(0, overlay.leftContentInset + insetDelta)
        }
    }

    /// Walk storage; create / position / destroy overlays to match attrs.
    func performWideTableOverlayUpdate(
        layoutAlreadySettled: Bool = false,
        knownWideTableAnchorRanges: [NSRange]? = nil
    ) {
        guard let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager else {
            removeAllWideTableOverlays()
            return
        }

        let containerWidth = container.size.width
        guard containerWidth.isFinite, containerWidth > 0 else { return }
        // Breakout: tables span full width, flush with the text column's left.
        let breakout = configuration.readingWidth != nil
        // Breakout host: the full-width reading-column container, else the text view itself.
        let host: NSView = breakout ? (superview ?? self) : self
        let hostBounds = host.bounds

        let anchorRanges: [NSRange]
        if let knownWideTableAnchorRanges {
            anchorRanges = knownWideTableAnchorRanges
        } else {
            // Ordinary edits do not carry table results, so discover anchors
            // once. Width restyles pass their exact new anchor set and avoid
            // this full-storage walk entirely.
            let scanStarted = DispatchTime.now().uptimeNanoseconds
            var discovered: [NSRange] = []
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(
                .scrollableBlockSourceID,
                in: fullRange,
                options: []
            ) { value, attrRange, _ in
                if value is Int { discovered.append(attrRange) }
            }
            anchorRanges = discovered
            let scanMs = Double(
                DispatchTime.now().uptimeNanoseconds - scanStarted
            ) / 1_000_000
            if scanMs > 0.3 {
                PerfTrace.stamp(
                    "wideTableOverlay.anchorScan",
                    scanMs,
                    "wide=\(anchorRanges.isEmpty ? 0 : 1) docLen=\(storage.length)"
                )
            }
        }
        guard !anchorRanges.isEmpty else {
            removeAllWideTableOverlays()
            return
        }

        var seenSourceIDs: Set<Int> = []

        // Settle layout before measuring — stale fragments would yield wrong anchor Ys.
        let overlayT0 = DispatchTime.now().uptimeNanoseconds
        var didEnsureLayout = !layoutAlreadySettled
        if !layoutAlreadySettled {
            tlm.ensureLayout(for: tlm.documentRange)
        }
        PerfTrace.stamp("wideTableOverlay.ensureLayout(fullDoc)",
                        Double(DispatchTime.now().uptimeNanoseconds - overlayT0) / 1_000_000,
                        "settled=\(layoutAlreadySettled ? 1 : 0) docLen=\(storage.length)")

        for attrRange in anchorRanges {
            guard attrRange.location != NSNotFound,
                  attrRange.location >= 0,
                  attrRange.length > 0,
                  attrRange.length <= storage.length,
                  attrRange.location <= storage.length - attrRange.length,
                  let sourceID = storage.attribute(
                    .scrollableBlockSourceID,
                    at: attrRange.location,
                    effectiveRange: nil
                  ) as? Int,
                  let image = storage.attribute(
                    .latexImage,
                    at: attrRange.location,
                    effectiveRange: nil
                  ) as? NSImage else { continue }
            seenSourceIDs.insert(sourceID)

            var anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            if anchorRect.isEmpty, !didEnsureLayout {
                // The caller vouched that layout was settled, but TextKit had
                // invalidated it (a width change mid-drag): there is no text
                // segment to measure, and skipping the table here would leave
                // its overlay at the previous width's position — over other text.
                tlm.ensureLayout(for: tlm.documentRange)
                didEnsureLayout = true
                anchorRect = bridge.boundingRect(forCharacterRange: attrRange, in: container)
            }
            guard !anchorRect.isEmpty else { continue }

            let totalHeight = (storage.attribute(.scrollableBlockTotalHeight, at: attrRange.location, effectiveRange: nil) as? CGFloat) ?? image.size.height
            // In breakout the overlay lives in the container and spans its visible width,
            // so the column's left edge is measured from the container's visible left.
            let anchorTopLeft = NSPoint(x: textContainerOrigin.x + anchorRect.minX,
                                        y: textContainerOrigin.y + anchorRect.minY)
            let anchorInHost = convert(anchorTopLeft, to: host)
            let columnLeft = breakout ? anchorInHost.x - hostBounds.minX : anchorTopLeft.x
            let overlayFrame: NSRect = breakout
                ? NSRect(x: hostBounds.minX, y: anchorInHost.y, width: hostBounds.width, height: totalHeight)
                : NSRect(x: columnLeft, y: anchorTopLeft.y, width: containerWidth, height: totalHeight)
            // Breakout: table starts at the text column's left edge; the left margin is scrollable space.
            let leftContentInset: CGFloat = breakout ? max(0, columnLeft) : 0

            if let existing = wideTableOverlays[sourceID] {
                if !existing.frame.equalTo(overlayFrame) {
                    // Invalidate both old + new region so the vacated area redraws.
                    host.setNeedsDisplay(existing.frame)
                    existing.frame = overlayFrame
                    host.setNeedsDisplay(overlayFrame)
                }
                existing.leftContentInset = leftContentInset
                existing.updateImage(image)
                existing.anchorTextLocation = attrRange.location
            } else {
                let overlay = WideTableOverlay(
                    sourceID: sourceID, image: image,
                    ownerTextView: self, anchorLocation: attrRange.location
                )
                overlay.frame = overlayFrame
                overlay.leftContentInset = leftContentInset
                host.addSubview(overlay)
                wideTableOverlays[sourceID] = overlay
                let savedOffset = tableHorizontalScrollOffsets[sourceID] ?? 0
                if savedOffset > 0 { overlay.horizontalOffset = savedOffset }
            }
        }

        for (sourceID, overlay) in wideTableOverlays where !seenSourceIDs.contains(sourceID) {
            host.setNeedsDisplay(overlay.frame)
            overlay.removeFromSuperview()
            wideTableOverlays.removeValue(forKey: sourceID)
        }
    }

    /// Drop all overlays synchronously (file switch path).
    func removeAllWideTableOverlays() {
        for (_, overlay) in wideTableOverlays { overlay.removeFromSuperview() }
        wideTableOverlays.removeAll()
    }
}
