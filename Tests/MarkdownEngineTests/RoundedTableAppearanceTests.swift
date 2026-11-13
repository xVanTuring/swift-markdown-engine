//
//  RoundedTableAppearanceTests.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) `TableAppearance.rounded`: the rounded-panel table look.
//  Geometry, the cell editor's padding and the wide-table overlay's rounded
//  clip must follow the style; `.grid` (the default) is unchanged.
//
import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Rounded table appearance", .serialized)
struct RoundedTableAppearanceTests {
    static let source = """
    Intro.

    | Language | Platform | Notes |
    |---|---|---|
    | Swift | iOS / iPadOS / macOS / watchOS / visionOS | Safe, modern |
    | C | Everywhere | Small |

    Outro.
    """

    static let wideSource = """
    Intro.

    | Identifier | Description |
    |---|---|
    | PositionIdentifierThatCannotBreakAcrossLines | MarketViewIdentifierThatCannotBreakAcrossLines |

    Outro.
    """

    private final class Harness {
        let window: NSWindow
        let textView: NativeTextView
        let coordinator: NativeTextViewCoordinator

        let source: String

        init(width: CGFloat, appearance: TableAppearance, source: String = RoundedTableAppearanceTests.source) throws {
            self.source = source
            _ = NSApplication.shared
            let frame = NSRect(x: 0, y: 0, width: width, height: 400)
            let scrollView = ClampedScrollView(frame: frame)
            scrollView.hasVerticalScroller = false
            scrollView.wantsLayer = true
            let textView = NativeTextView(frame: .zero)
            let container = try #require(textView.textContainer)
            let tlm = try #require(textView.textLayoutManager)
            container.lineFragmentPadding = 0
            container.widthTracksTextView = true
            var configuration = MarkdownEditorConfiguration.default
            configuration.tableAppearance = appearance
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

        var tableStart: Int { (textView.string as NSString).range(of: "| Language").location }

        func tableImage() throws -> NSImage {
            let storage = try #require(textView.textStorage)
            var found: NSImage?
            storage.enumerateAttribute(.latexImage, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if let image = value as? NSImage, image.tableGeometry != nil { found = image; stop.pointee = true }
            }
            return try #require(found)
        }
    }

    @Test("The style reaches the rendered image and its geometry")
    func geometryFollowsStyle() throws {
        let grid = try Harness(width: 900, appearance: .grid)
        let gridImage = try grid.tableImage()
        grid.close()
        let rounded = try Harness(width: 900, appearance: .rounded)
        defer { rounded.close() }
        let image = try rounded.tableImage()
        let g = try #require(image.tableGeometry)
        let gg = try #require(gridImage.tableGeometry)
        #expect(g.style == .rounded)
        #expect(gg.style == .grid)
        #expect(image !== gridImage, "same source, different style → a different cached image")

        let m = TableAppearance.rounded.metrics
        // Outer space instead of a border on the outside; no gap after the last column / row.
        #expect(g.columnLeft[0] == m.outerHorizontal)
        #expect(g.rowTop[0] == m.outerTop)
        #expect(abs(g.imageSize.width - (g.columnLeft[g.columnCount] - g.borderWidth + m.outerHorizontal)) < 0.01)
        #expect(abs(g.imageSize.height - (g.rowTop[g.rowCount] - g.borderWidth + m.outerBottom)) < 0.01)
        // Grid layout is unchanged: border on every side.
        #expect(gg.columnLeft[0] == gg.borderWidth)
        #expect(abs(gg.imageSize.width - gg.columnLeft[gg.columnCount]) < 0.01)
        // The smaller header row is shorter than it is under .grid.
        let header = try #require(g.cellRect(row: 0, column: 0))
        let gridHeader = try #require(gg.cellRect(row: 0, column: 0))
        #expect(header.height <= gridHeader.height)
    }

    @Test("The cell editor copies the style's padding and header type")
    func cellEditorFollowsStyle() throws {
        let h = try Harness(width: 900, appearance: .rounded)
        defer { h.close() }
        h.window.makeFirstResponder(h.textView)
        let m = TableAppearance.rounded.metrics
        #expect(h.textView.beginTableCellEditing(tableStart: h.tableStart, row: 1, column: 1))
        let body = try #require(h.textView.tableEditSession?.editor)
        #expect(body.textContainerInset == NSSize(width: m.cellHorizontal, height: m.bodyVertical))
        let bodySize = try #require(body.font?.pointSize)
        #expect(h.textView.beginTableCellEditing(tableStart: h.tableStart, row: 0, column: 1))
        let header = try #require(h.textView.tableEditSession?.editor)
        #expect(header.textContainerInset == NSSize(width: m.cellHorizontal, height: m.headerVertical))
        #expect(try #require(header.font?.pointSize) < bodySize)
    }

    @Test("A wide rounded table scrolls inside a rounded clip of the table's height")
    func wideTableClipIsRounded() throws {
        let h = try Harness(width: 300, appearance: .rounded, source: Self.wideSource)
        defer { h.close() }
        let overlay = try #require(h.textView.wideTableOverlays.values.first)
        let image = try #require(overlay.currentImage)
        overlay.horizontalOffset = 40
        Harness.drain(0.05)
        let clip = overlay.contentView
        #expect(clip.layer?.cornerRadius == TableAppearance.rounded.metrics.cornerRadius)
        #expect(clip.layer?.masksToBounds == true)
        #expect(abs(clip.frame.height - image.size.height) < 0.5)
    }

    @Test("A wide grid table keeps a square clip")
    func wideGridTableClipIsSquare() throws {
        let h = try Harness(width: 300, appearance: .grid, source: Self.wideSource)
        defer { h.close() }
        let overlay = try #require(h.textView.wideTableOverlays.values.first)
        #expect((overlay.contentView.layer?.cornerRadius ?? 0) == 0)
    }
}
