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

    private final class Harness {
        let window: NSWindow
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator

        init(width: CGFloat) throws {
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
                text: .constant(RenderedBlockSelectionTests.source), fontName: font.fontName, fontSize: font.pointSize,
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
            textView.string = RenderedBlockSelectionTests.source
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
            coordinator.rebuildTextStorageAndStyle(textView, from: RenderedBlockSelectionTests.source, invalidateLayout: true)
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
}
