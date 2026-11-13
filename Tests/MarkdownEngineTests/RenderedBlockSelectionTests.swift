//
//  RenderedBlockSelectionTests.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) A text selection that reaches into a rendered table takes
//  the whole table — it never starts or ends mid-table (the collapsed source has
//  one block-wide anchor, so hit-testing used to land in its middle).
//  A real mouse drag goes through the same `setSelectedRanges` override; a
//  synthesized drag (posted events + mouseDown) was verified by hand but ends the
//  `swift test` process early, so it is not kept as a test.
//
//  Also: what a selected block looks like (the system highlight leaves it out,
//  `MarkdownTextLayoutManager`), the open cell's text left out of the table
//  image while its editor shows it, and the grips' cursor.
//
import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Rendered block selection", .serialized)
struct RenderedBlockSelectionTests {
    static let source = """
    Before the table.

    | Feature | Circuit switching | Message switching |
    |---|---|---|
    | Principle | Set up, transfer, release; the two ends hold a dedicated path end to end | Store and forward |
    | Delay | Least | Longer |

    After the table.
    """

    /// Unbreakable cells: wider than the view at any test width, so it gets a
    /// scrolling overlay.
    static let wideSource = """
    Before the table.

    | Feature | CircuitSwitchingCharacteristics | MessageSwitchingCharacteristics | PacketSwitchingCharacteristics |
    |---|---|---|---|
    | Principle | EstablishTransferRelease | StoreAndForwardWholeMessage | StoreAndForwardPackets |
    | Delay | Least | Most | Medium |

    After the table.
    """

    private final class Harness {
        let window: NSWindow
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator

        init(width: CGFloat, source: String = RenderedBlockSelectionTests.source) throws {
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: width, height: 500)
            let scrollView = ClampedScrollView(frame: frame)
            scrollView.hasVerticalScroller = false
            let textView = NativeTextView(frame: .zero)
            let container = try #require(textView.textContainer)
            let tlm = try #require(textView.textLayoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            let configuration = MarkdownEditorConfiguration.default
            let font = NSFont.systemFont(ofSize: 14)
            let coordinator = NativeTextViewCoordinator(
                text: .constant(source), fontName: font.fontName, fontSize: font.pointSize,
                isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
            coordinator.configuration = configuration
            let layoutDelegate = MarkdownLayoutManagerDelegate()
            coordinator.layoutDelegate = layoutDelegate
            tlm.delegate = layoutDelegate
            let bridge = LayoutBridge(tlm)
            coordinator.layoutBridge = bridge
            textView.configuration = configuration
            textView.baseFont = font
            textView.font = font
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = true
            textView.isVerticallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.layoutBridge = bridge
            textView.string = source
            textView.delegate = coordinator
            let host = NativeTextViewContainer(frame: frame)
            host.autoresizingMask = [.width]
            host.textView = textView
            textView.frame = NSRect(x: 0, y: 0, width: frame.width, height: 0)
            host.addSubview(textView)
            scrollView.documentView = host
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = scrollView
            window.orderFrontRegardless()
            coordinator.textView = textView
            coordinator.rebuildTextStorageAndStyle(textView, from: source, invalidateLayout: true)
            textView.recalcOverscroll(for: scrollView)
            Self.drain(0.05)
            textView.updateWideTableOverlays(immediately: true)
            Self.drain(0.05)
            self.window = window
            self.textView = textView
            self.coordinator = coordinator
        }

        func close() { window.orderOut(nil) }

        static func drain(_ t: TimeInterval) {
            let deadline = Date(timeIntervalSinceNow: t)
            while Date() < deadline {
                RunLoop.main.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
            }
        }

        var ns: NSString { textView.string as NSString }
        var tableStart: Int { ns.range(of: "| Feature").location }
        var tableEnd: Int { NSMaxRange(ns.range(of: "| Longer |")) }

        /// A point over the middle of the rendered table (view coordinates).
        func pointInsideTable() throws -> NSPoint {
            let storage = try #require(textView.textStorage)
            let block = try #require(
                (storage.attribute(.renderedBlockRange, at: tableStart, effectiveRange: nil) as? NSValue)?.rangeValue)
            #expect(block.location <= tableStart)
            let tlm = try #require(textView.textLayoutManager)
            let start = try #require(tlm.location(tlm.documentRange.location, offsetBy: tableStart))
            var rect = NSRect.zero
            tlm.enumerateTextSegments(in: NSTextRange(location: start), type: .standard, options: []) { _, frame, _, _ in
                rect = frame; return false
            }
            let origin = textView.textContainerOrigin
            return NSPoint(x: textView.bounds.width * 0.6, y: origin.y + rect.minY + 30)
        }
    }

    @Test("A selection ending inside a table takes the whole table", arguments: [1400.0, 420.0])
    func partialSelectionSnapsToWholeTable(width: Double) throws {
        let h = try Harness(width: width)
        defer { h.close() }
        let after = h.ns.range(of: "After").location
        // Dragging up from below: the hit-test lands mid-table.
        let mid = h.textView.characterIndexForInsertion(at: try h.pointInsideTable())
        #expect(mid > h.tableStart, "hit-test lands inside the collapsed table source")
        h.textView.setSelectedRange(NSRange(location: mid, length: after + 5 - mid))
        #expect(h.textView.selectedRange().location <= h.tableStart)
        #expect(NSMaxRange(h.textView.selectedRange()) == after + 5)

        // Dragging down from above into the table.
        h.textView.setSelectedRange(NSRange(location: 3, length: mid - 3))
        #expect(h.textView.selectedRange().location == 3)
        #expect(NSMaxRange(h.textView.selectedRange()) >= h.tableEnd)
    }

    @Test("A caret placed in a table is left alone")
    func caretIsNotSnapped() throws {
        let h = try Harness(width: 900)
        defer { h.close() }
        let inside = h.tableStart + 5
        h.textView.setSelectedRange(NSRange(location: inside, length: 0))
        #expect(h.textView.selectedRange() == NSRange(location: inside, length: 0))
    }

    @Test("Selections in ordinary text are unchanged")
    func plainTextIsNotSnapped() throws {
        let h = try Harness(width: 900)
        defer { h.close() }
        let range = NSRange(location: 2, length: 6)
        h.textView.setSelectedRange(range)
        #expect(h.textView.selectedRange() == range)
    }

    // MARK: What a selected block looks like

    @Test("Every editor gets the layout manager that shapes the selection highlight")
    func editorUsesMarkdownLayoutManager() throws {
        let h = try Harness(width: 900)
        defer { h.close() }
        #expect(h.textView.textLayoutManager is MarkdownTextLayoutManager)
        #expect(h.textView.textContainer?.widthTracksTextView == true)
        #expect(h.textView.textStorage?.string == RenderedBlockSelectionTests.source)
    }

    @Test("The system highlight leaves a selected table out", arguments: [false, true])
    func highlightSkipsSelectedTable(wide: Bool) throws {
        let h = try Harness(width: 700, source: wide ? Self.wideSource : Self.source)
        defer { h.close() }
        let tlm = try #require(h.textView.textLayoutManager as? MarkdownTextLayoutManager)
        let storage = try #require(h.textView.textStorage)
        let block = try #require(
            (storage.attribute(.renderedBlockRange, at: h.tableStart, effectiveRange: nil) as? NSValue)?.rangeValue)
        let after = h.ns.range(of: "After").location
        h.textView.setSelectedRange(NSRange(location: 3, length: after + 5 - 3))

        // The block and the blank lines around it are left to the block.
        let excluded = try #require(tlm.selectionHighlightExclusions.first)
        #expect(tlm.selectionHighlightExclusions.count == 1)
        #expect(excluded.location == block.location - 1)
        #expect(NSMaxRange(excluded) >= NSMaxRange(block))
        #expect(h.ns.substring(with: NSRange(location: excluded.location - 1, length: 2)) == "\n\n")

        let origin = tlm.documentRange.location
        let selection = h.textView.selectedRange()
        let start = try #require(tlm.location(origin, offsetBy: selection.location))
        let end = try #require(tlm.location(origin, offsetBy: NSMaxRange(selection)))
        var starts: [Int] = []
        tlm.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)),
                                  type: .selection, options: [.rangeNotRequired]) { range, _, _, _ in
            if let range { starts.append(tlm.offset(from: origin, to: range.location)) }
            return true
        }
        #expect(!starts.contains { NSLocationInRange($0, excluded) }, "no system highlight over the table")
        #expect(starts.contains { $0 < excluded.location }, "the text before keeps its highlight")
        #expect(starts.contains { $0 >= NSMaxRange(excluded) }, "the text after keeps its highlight")
        // Other segment types are untouched.
        var standard = 0
        tlm.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)),
                                  type: .standard, options: []) { range, _, _, _ in
            if let range, NSLocationInRange(tlm.offset(from: origin, to: range.location), block) { standard += 1 }
            return true
        }
        #expect(standard > 0)

        if wide {
            let overlay = try #require(h.textView.wideTableOverlays.values.first)
            #expect(overlay.selectionHighlight != nil, "a wide table paints its own highlight")
        }

        // A caret: the system highlight is whole again, the overlay plain.
        h.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(tlm.selectionHighlightExclusions.isEmpty)
        if wide { #expect(h.textView.wideTableOverlays.values.first?.selectionHighlight == nil) }
    }

    @Test("A selection that only touches text leaves the highlight alone")
    func textOnlySelectionHasNoExclusions() throws {
        let h = try Harness(width: 900)
        defer { h.close() }
        h.textView.setSelectedRange(NSRange(location: 0, length: 6))
        let tlm = try #require(h.textView.textLayoutManager as? MarkdownTextLayoutManager)
        #expect(tlm.selectionHighlightExclusions.isEmpty)
    }

    // MARK: The open cell

    @Test("The open cell's text is left out of the table image", arguments: [false, true])
    func openCellIsLeftOutOfTheImage(wide: Bool) throws {
        let h = try Harness(width: 700, source: wide ? Self.wideSource : Self.source)
        defer { h.close() }
        func shown() throws -> NSImage {
            let token = try #require(h.textView.tableToken(containing: h.tableStart))
            let image = try #require(h.textView.renderedTable(in: token.range)?.image)
            if wide {
                // The overlay shows that very image (a new one each time the open cell changes).
                let overlay = try #require(h.textView.wideTableOverlays.values.first)
                #expect(overlay.currentImage === image)
            }
            return image
        }
        let before = try shown()
        #expect(before.tableGeometry?.hiddenCell == nil)

        #expect(h.textView.beginTableCellEditing(tableStart: h.tableStart, row: 1, column: 1))
        let session = try #require(h.textView.tableEditSession)
        #expect(!session.editor.drawsBackground, "the editor shows the table under it")
        let open = try shown()
        #expect(open !== before, "a new image, so every view showing the table draws it")
        let hidden = try #require(open.tableGeometry?.hiddenCell)
        #expect(hidden.row == 1 && hidden.column == 1)
        // The cell really is blank in it.
        let cell = try #require(open.tableGeometry?.cellRect(row: 1, column: 1))
        #expect(try Self.pixels(of: open, in: cell) != Self.pixels(of: before, in: cell))

        // Tab: the next cell is the one left out, the previous one is back.
        h.textView.moveTableCellEditor(.next)
        let moved = try shown()
        let movedHidden = try #require(moved.tableGeometry?.hiddenCell)
        #expect(movedHidden.row == 1 && movedHidden.column == 2)
        #expect(try Self.pixels(of: moved, in: cell) == Self.pixels(of: before, in: cell))

        // Typing: each write of the cell re-renders the table — still without the cell.
        let editor = try #require(h.textView.tableEditSession?.editor)
        editor.insertText("x", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        h.textView.syncTableCellToDocument()
        let typed = try shown()
        #expect(typed.tableGeometry?.hiddenCell?.row == 1 && typed.tableGeometry?.hiddenCell?.column == 2)

        h.textView.endTableCellEditing()
        #expect(try shown().tableGeometry?.hiddenCell == nil, "closing the editor shows the cell again")
    }

    private static func pixels(of image: NSImage, in rect: CGRect) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        // Top-down cell rect → bitmap rows (also top-down).
        var out = Data()
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                out.append(UInt8(c.alphaComponent * 255))
            }
        }
        return out
    }

    // MARK: Grips

    @Test("A grip shows the open hand, and takes the mouse a little around its pill")
    func gripCursor() throws {
        let h = try Harness(width: 900)
        defer { h.close() }
        h.textView.showTableGrips(tableStart: h.tableStart, row: 1, column: 1)
        let grip = try #require(h.textView.tableGripState?.columnGrip)
        #expect(grip.superview != nil && !grip.isHidden)
        let pad = TableGripView.hitPadding
        #expect(abs(grip.bounds.width - (TableGripView.longSide + 2 * pad)) < 0.5)
        #expect(abs(grip.pillRect.width - TableGripView.longSide) < 0.5)

        // Just outside the drawn pill, still over the grip.
        let edge = grip.convert(NSPoint(x: grip.pillRect.minX - pad / 2, y: grip.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: edge, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        #expect(h.textView.isOverTableGrip(event))
        NSCursor.iBeam.set()
        h.textView.mouseMoved(with: event)
        #expect(NSCursor.current === NSCursor.openHand, "the text view no longer puts the I-beam over a grip")
        #expect(h.textView.tableGripState != nil, "the grips stay while the pointer is on one")

        // Over ordinary text: not a grip.
        let text = h.textView.convert(NSPoint(x: 5, y: h.textView.textContainerOrigin.y + 5), to: nil)
        let textEvent = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: text, modifierFlags: [], timestamp: 0,
            windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        #expect(!h.textView.isOverTableGrip(textEvent))
    }
}
