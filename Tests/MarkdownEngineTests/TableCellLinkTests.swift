//
//  TableCellLinkTests.swift
//  MarkdownEngineTests
//
//  (fork: xVanTuring) Links inside table cells: drawn as links (not as their
//  source), and a click on one is mapped back to it through the table image's
//  geometry — at the very place the image draws it.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Knows a fixed set of names; its fingerprint is whatever the test says.
private struct FixedResolver: WikiLinkResolver {
    var known: [String: WikiLinkResolution]
    var version: Int = 0
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { known[displayName] }
    func fingerprint() -> AnyHashable { version }
}

@MainActor
@Suite("Table cell links")
struct TableCellLinkTests {

    private static let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    private func theme() -> MarkdownEditorTheme {
        var theme = MarkdownEditorConfiguration.default.theme
        theme.link = Self.red
        return theme
    }

    private func cell(_ raw: String, wikiLinks: (any WikiLinkResolver)? = nil) -> NSAttributedString {
        _ = NSApplication.shared
        return MarkdownStyler.formattedCellString(
            raw, baseFont: NSFont.systemFont(ofSize: 14), header: false,
            theme: theme(), codeBackgroundColor: .clear,
            latex: MarkdownEditorConfiguration.default.services.latex,
            wikiLinks: wikiLinks
        )
    }

    private func link(_ s: NSAttributedString, at index: Int) -> TableCellLink? {
        s.attribute(.tableCellLink, at: index, effectiveRange: nil) as? TableCellLink
    }

    // MARK: Formatting

    @Test func markdownLinkShowsItsTextAsALink() {
        let s = cell("见 [第 42 题](unireader://open?ws=%2FUsers%2Fa%20b&doc=1) 后")
        #expect(s.string == "见 第 42 题 后")
        let at = (s.string as NSString).range(of: "第").location
        #expect(link(s, at: at) == .url(URL(string: "unireader://open?ws=%2FUsers%2Fa%20b&doc=1")!))
        #expect(s.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor == Self.red)
        #expect(s.attribute(.underlineStyle, at: at, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        #expect(link(s, at: 0) == nil)
        #expect(link(s, at: s.length - 1) == nil)
    }

    @Test func linkWithoutSchemeIsAWebAddress() {
        #expect(link(cell("[x](example.com)"), at: 0) == .url(URL(string: "https://example.com")!))
    }

    @Test func emphasisInsideLinkTextStays() {
        let s = cell("[**粗**](https://a.com)")
        #expect(s.string == "粗")
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(link(s, at: 0) == .url(URL(string: "https://a.com")!))
    }

    @Test func wikiLinkWithoutResolverShowsItsName() {
        let s = cell("[[笔记甲]]【2009】")
        #expect(s.string == "笔记甲【2009】")
        #expect(link(s, at: 0) == .wiki("笔记甲"))
        #expect(link(s, at: 3) == nil)
    }

    @Test func wikiLinkShowsTheResolversShortText() {
        let name = "2027计算机网络_高清带书签版#page=262"
        let resolver = FixedResolver(known: [name: WikiLinkResolution(id: "pdf:1#261", exists: true, displayText: "p.262")])
        let s = cell("[[\(name)]]【2009】", wikiLinks: resolver)
        #expect(s.string == "p.262【2009】")
        #expect(link(s, at: 0) == .wiki(name))
        #expect(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Self.red)
    }

    @Test func wikiLinkCarriesTheResolversHoverText() {
        let name = "书#page=12"
        let resolver = FixedResolver(known: [
            name: WikiLinkResolution(id: "pdf:1#11", exists: true, displayText: "p.12", toolTip: "书 · 第 12 页"),
        ])
        let s = cell("[[\(name)]] 和 [[\(name)]]", wikiLinks: resolver)
        #expect(s.attribute(.tableCellToolTip, at: 0, effectiveRange: nil) as? String == "书 · 第 12 页")
        #expect(s.attribute(.tableCellToolTip, at: 5, effectiveRange: nil) == nil)   // the text between
        #expect(cell("[[\(name)]]").attribute(.tableCellToolTip, at: 0, effectiveRange: nil) == nil)
    }

    @Test func unknownWikiLinkIsGreyedAndNotClickable() {
        let s = cell("[[没有这篇]]", wikiLinks: FixedResolver(known: [:]))
        #expect(s.string == "没有这篇")
        #expect(link(s, at: 0) == nil)
        #expect(s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == MarkdownEditorConfiguration.default.theme.disabledText)
    }

    // MARK: Hit testing matches the drawing

    /// Renders `source`, rasterizes it at 1×, and returns the pixels drawn in
    /// the link colour (image top-down coordinates).
    private func linkPixels(of image: NSImage) throws -> [CGPoint] {
        let width = Int(image.size.width.rounded(.up)), height = Int(image.size.height.rounded(.up))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(origin: .zero, size: image.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        var points: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
                if c.redComponent > 0.6, c.greenComponent < 0.35, c.blueComponent < 0.35 {
                    points.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                }
            }
        }
        return points
    }

    private func render(_ source: String, width: CGFloat, style: TableAppearance,
                        hiddenCell: (row: Int, column: Int)? = nil) throws -> NSImage {
        _ = NSApplication.shared
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        return MarkdownStyler.renderTable(
            parsed, baseFont: NSFont.systemFont(ofSize: 15), theme: theme(),
            codeBackgroundColor: .clear, latex: MarkdownEditorConfiguration.default.services.latex,
            appearance: NSAppearance(named: .aqua)!, availableWidth: width,
            style: style, hiddenCell: hiddenCell
        )
    }

    /// A wrapped link in a centred column, both looks: every pixel drawn in the
    /// link colour lies on the link's laid-out rects, every rect has some, and
    /// the middle of each rect hits the link — the hit-test layout is the
    /// drawing's layout.
    @Test(arguments: [TableAppearance.grid, .rounded])
    func hitRectsMatchTheDrawnLink(style: TableAppearance) throws {
        let source = """
        | 题 | 说明 |
        |:---:|---|
        | 前面一些说明 [链接文字比较长需要折行显示](https://example.com/a) 后面还有 | 第二列 |
        """
        let image = try render(source, width: 260, style: style)
        let geometry = try #require(image.tableGeometry)
        #expect(geometry.linkCells.count == 1)
        let cellText = try #require(geometry.linkCells.first)
        let rects = cellText.linkRects()
        #expect(rects.count >= 2)   // the link wraps

        let pixels = try linkPixels(of: image)
        #expect(pixels.count > 50)
        let stray = pixels.filter { p in !rects.contains { $0.insetBy(dx: -2, dy: -2).contains(p) } }
        #expect(stray.isEmpty, "link pixels outside the hit rects: \(stray.prefix(5)) rects: \(rects)")
        for rect in rects {
            #expect(pixels.contains { rect.contains($0) }, "no link drawn in \(rect)")
            #expect(geometry.link(at: CGPoint(x: rect.midX, y: rect.midY)) == .url(URL(string: "https://example.com/a")!))
        }
        // The text before the link, the header and the other column are not the link.
        let first = try #require(rects.min { $0.minY < $1.minY || ($0.minY == $1.minY && $0.minX < $1.minX) })
        #expect(geometry.link(at: CGPoint(x: first.minX - 6, y: first.midY)) == nil)
        let header = try #require(geometry.cellRect(row: 0, column: 0))
        #expect(geometry.link(at: CGPoint(x: header.midX, y: header.midY)) == nil)
        let other = try #require(geometry.cellRect(row: 1, column: 1))
        #expect(geometry.link(at: CGPoint(x: other.midX, y: other.midY)) == nil)
    }

    @Test func cellOpenInTheEditorHasNoLinks() throws {
        let source = "| a |\n|---|\n| [x](https://a.com) |"
        let image = try render(source, width: 400, style: .rounded, hiddenCell: (1, 0))
        let geometry = try #require(image.tableGeometry)
        let rect = try #require(geometry.linkCells.first?.linkRects().first)
        #expect(geometry.link(at: CGPoint(x: rect.midX, y: rect.midY)) == nil)
    }

    // MARK: Hover texts

    private func toolTipTable() throws -> NSImage {
        _ = NSApplication.shared
        let source = "| 题 | 出处 |\n|---|---|\n| [#1](https://a.com) | [[书#page=12]]、[[书#page=30]] |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let resolver = FixedResolver(known: [
            "书#page=12": WikiLinkResolution(id: "a", exists: true, displayText: "p.12", toolTip: "书 · 第 12 页"),
            "书#page=30": WikiLinkResolution(id: "b", exists: true, displayText: "p.30", toolTip: "书 · 第 30 页"),
        ])
        return MarkdownStyler.renderTable(
            parsed, baseFont: NSFont.systemFont(ofSize: 15), theme: theme(),
            codeBackgroundColor: .clear, latex: MarkdownEditorConfiguration.default.services.latex,
            appearance: NSAppearance(named: .aqua)!, availableWidth: 600, style: .rounded, wikiLinks: resolver)
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// One rect per link that has a hover text, where its text is drawn —
    /// shifted by the image's place in a flipped view, mirrored in an unflipped one.
    @Test func hoverTextsAreRegisteredOverTheirLinks() throws {
        let image = try toolTipTable()
        let geometry = try #require(image.tableGeometry)
        let runs = geometry.linkRuns().filter { $0.toolTip != nil }
        #expect(runs.map(\.toolTip) == ["书 · 第 12 页", "书 · 第 30 页"])

        let flipped = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let tips = TableLinkToolTips()
        tips.show(geometry, at: CGPoint(x: 10, y: 20), in: flipped)
        #expect(tips.registered.map(\.text) == ["书 · 第 12 页", "书 · 第 30 页"])
        #expect(tips.registered.map(\.rect) == runs.map { $0.rect.offsetBy(dx: 10, dy: 20) })
        tips.show(geometry, at: CGPoint(x: 10, y: 20), in: flipped)   // same place: left alone
        #expect(tips.registered.count == 2)
        tips.clear(in: flipped)
        #expect(tips.registered.isEmpty)

        let unflipped = NSView(frame: NSRect(origin: .zero, size: image.size))
        tips.show(geometry, at: .zero, in: unflipped)
        let first = try #require(tips.registered.first?.rect)
        #expect(first.minY == image.size.height - runs[0].rect.maxY)
        #expect(first.minX == runs[0].rect.minX)
    }

    @Test func tableWithoutLinksKeepsNoCellText() throws {
        let image = try render("| a | b |\n|---|---|\n| **1** | `2` |", width: 400, style: .rounded)
        #expect(image.tableGeometry?.linkCells.isEmpty == true)
    }

    // MARK: Cache key

    /// A `[[…]]` is drawn as the resolver says, so a change to the resolver
    /// (a note created, renamed) renders the table again.
    @Test func resolverChangeRendersAWikiTableAgain() throws {
        _ = NSApplication.shared
        let name = "新笔记-\(UUID().uuidString)"   // a source no other test has cached
        let source = "| a |\n|---|\n| [[\(name)]] |"
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        func image(_ resolver: FixedResolver) -> (NSImage, Bool) {
            var configuration = MarkdownEditorConfiguration.default
            configuration.services.wikiLinks = resolver
            let font = NSFont.systemFont(ofSize: 15)
            let ctx = MarkdownStyler.StylingContext(
                nsText: source as NSString, tokens: [], codeTokens: [], activeTokenIndices: [],
                baseFont: font, layoutBridge: nil, baseDefaultLineHeight: 18,
                codeBackgroundColor: .windowBackgroundColor, latexMarkerFont: font,
                configuration: configuration, wikiLinkIDProvider: { _ in nil })
            let result = MarkdownStyler.tableImage(
                for: source, parsed: parsed, ctx: ctx,
                appearance: NSAppearance(named: .aqua)!, availableWidth: 400)
            return (result.image, result.rendered)
        }
        let broken = image(FixedResolver(known: [:], version: 1))
        #expect(broken.1)
        #expect(broken.0.tableGeometry?.linkCells.isEmpty == true)
        #expect(image(FixedResolver(known: [:], version: 1)).1 == false)   // same state: cached
        let fixed = image(FixedResolver(known: [name: WikiLinkResolution(id: "n", exists: true)], version: 2))
        #expect(fixed.1)
        #expect(fixed.0.tableGeometry?.linkCells.count == 1)
    }

    // MARK: In the editor

    private func makeEditor(_ storage: String, onLinkClick: ((String) -> Void)? = nil)
        -> (NativeTextView, NativeTextViewCoordinator, NSWindow) {
        _ = NSApplication.shared
        var configuration = MarkdownEditorConfiguration.default
        configuration.editsTablesInPlace = true
        configuration.services.wikiLinks = FixedResolver(known: [
            "笔记甲": WikiLinkResolution(id: "a", exists: true),
            "书#page=12": WikiLinkResolution(id: "b", exists: true, displayText: "p.12", toolTip: "书 · 第 12 页"),
        ])
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.isEditable = true
        textView.configuration = configuration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        let coordinator = NativeTextViewCoordinator(
            text: .constant(storage), fontName: "SF Pro Text", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: onLinkClick, onInlineSelectionChange: nil)
        coordinator.textView = textView
        textView.delegate = coordinator
        coordinator.configuration = configuration
        if let layoutManager = textView.textLayoutManager {
            let bridge = LayoutBridge(layoutManager)
            coordinator.layoutBridge = bridge
            textView.layoutBridge = bridge
        }
        coordinator.rebuildTextStorageAndStyle(textView, from: storage)
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return (textView, coordinator, window)
    }

    /// The view point of the middle of the `index`-th link rect of the table at `tableStart`.
    private func linkPoint(_ tv: NativeTextView, tableStart: Int, index: Int = 0) throws -> NSPoint {
        let token = try #require(tv.tableToken(containing: tableStart))
        let rendered = try #require(tv.renderedTable(in: token.range))
        let origin = try #require(tv.narrowTableImageOrigin(image: rendered.image, anchor: rendered.anchor))
        let rects = rendered.geometry.linkCells.flatMap { $0.linkRects() }
        let rect = try #require(rects.count > index ? rects[index] : nil)
        return NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
    }

    @Test func pointOverATableLinkInTheViewFindsIt() throws {
        let doc = "intro\n\n| 题 | 出处 |\n| --- | --- |\n| [#42](https://example.com/q42) | [[笔记甲]]【2009】 |\n\noutro\n"
        let (tv, coordinator, window) = makeEditor(doc)
        defer { withExtendedLifetime((coordinator, window)) {} }
        let urlPoint = try linkPoint(tv, tableStart: 7, index: 0)
        let hit = try #require(tv.narrowTableHit(at: urlPoint))
        #expect(tv.tableToken(containing: hit.anchor)?.range.location == 7)
        #expect(hit.geometry.link(at: hit.imagePoint) == .url(URL(string: "https://example.com/q42")!))
        #expect(tv.tableLink(atWindowPoint: tv.convert(urlPoint, to: nil)) == .url(URL(string: "https://example.com/q42")!))
        let wikiPoint = try linkPoint(tv, tableStart: 7, index: 1)
        #expect(tv.tableLink(atWindowPoint: tv.convert(wikiPoint, to: nil)) == .wiki("笔记甲"))
        // Beside the table: nothing.
        #expect(tv.tableLink(atWindowPoint: tv.convert(NSPoint(x: urlPoint.x, y: 2), to: nil)) == nil)
        #expect(tv.textLayoutManager != nil)
    }

    /// Over a narrow table the hover texts of its links are registered; away
    /// from it, cleared.
    @Test func hoverTextsFollowThePointerInTheView() throws {
        let doc = "intro\n\n| 题 | 出处 |\n| --- | --- |\n| x | [[书#page=12]] |\n\noutro\n"
        let (tv, coordinator, window) = makeEditor(doc)
        defer { withExtendedLifetime((coordinator, window)) {} }
        let point = try linkPoint(tv, tableStart: 7)
        tv.updateTableLinkToolTips(atWindowPoint: tv.convert(point, to: nil))
        #expect(tv.tableLinkToolTips.registered.map(\.text) == ["书 · 第 12 页"])
        let rect = try #require(tv.tableLinkToolTips.registered.first?.rect)
        #expect(rect.contains(point))
        tv.updateTableLinkToolTips(atWindowPoint: tv.convert(NSPoint(x: point.x, y: 2), to: nil))
        #expect(tv.tableLinkToolTips.registered.isEmpty)
    }

    // MARK: Read-only display renderer

    @Test func displayRendererListsTableLinks() throws {
        _ = NSApplication.shared
        let source = "| 题 | 出处 |\n|---|---|\n| [#42](unireader://open?doc=1) | [[笔记 甲]] |"
        let style = MarkdownDisplayStyle(configuration: .default, font: .systemFont(ofSize: 14))
        let image = try #require(MarkdownDisplayRenderer.tableImage(
            source: source, style: style, availableWidth: 600, appearance: NSAppearance(named: .aqua)!))
        let links = MarkdownDisplayRenderer.tableLinks(in: image)
        #expect(links.count == 2)
        #expect(links.first?.url == URL(string: "unireader://open?doc=1"))
        let wiki = try #require(links.last)
        #expect(MarkdownDisplayRenderer.wikiLinkTarget(wiki.url) == "笔记 甲")
        #expect(MarkdownDisplayRenderer.tableLink(in: image, at: CGPoint(x: wiki.rect.midX, y: wiki.rect.midY)) == wiki.url)
        #expect(MarkdownDisplayRenderer.tableLink(in: image, at: CGPoint(x: 1, y: 1)) == nil)
        #expect(MarkdownDisplayRenderer.tableLinks(in: NSImage(size: NSSize(width: 10, height: 10))).isEmpty)
    }

    @Test func openingAWikiLinkGoesThroughOnLinkClick() async throws {
        var clicked: [String] = []
        let doc = "| a |\n| --- |\n| [[笔记甲]] |\n"
        let (tv, coordinator, window) = makeEditor(doc) { clicked.append($0) }
        defer { withExtendedLifetime((coordinator, window)) {} }
        let point = try linkPoint(tv, tableStart: 0)
        let link = try #require(tv.tableLink(atWindowPoint: tv.convert(point, to: nil)))
        tv.openTableLink(link)
        try await Task.sleep(for: .milliseconds(50))
        #expect(clicked == ["笔记甲"])
    }

    /// A press on a link follows it when released over the same link, not
    /// when released elsewhere; an Option-press is left to the cell.
    /// (The tracking loop between press and release reads the event queue,
    /// which a posted event never reaches under Swift Testing — the release is
    /// handed in directly.)
    @Test func pressOnATableLinkFollowsItOnlyWhenReleasedOnIt() async throws {
        var clicked: [String] = []
        let doc = "| a | b |\n| --- | --- |\n| [[笔记甲]] | x |\n"
        let (tv, coordinator, window) = makeEditor(doc) { clicked.append($0) }
        defer { withExtendedLifetime((coordinator, window)) {} }
        let on = tv.convert(try linkPoint(tv, tableStart: 0), to: nil)
        #expect(!tv.finishTableLinkPress(.wiki("笔记甲"), releasedAt: NSPoint(x: on.x, y: on.y + 300)))
        #expect(!tv.finishTableLinkPress(.wiki("别的"), releasedAt: on))
        #expect(tv.finishTableLinkPress(.wiki("笔记甲"), releasedAt: on))
        try await Task.sleep(for: .milliseconds(50))
        #expect(clicked == ["笔记甲"])

        let optionPress = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: on, modifierFlags: .option, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(!tv.followTableLinkIfHit(event: optionPress))
    }

    /// Following a link commits a cell that is open in the editor.
    @Test func openingALinkClosesTheCellEditor() async throws {
        let doc = "| a | b |\n| --- | --- |\n| [[笔记甲]] | x |\n"
        let (tv, coordinator, window) = makeEditor(doc) { _ in }
        defer { withExtendedLifetime((coordinator, window)) {} }
        #expect(tv.beginTableCellEditing(tableStart: 0, row: 1, column: 1))
        tv.tableEditSession?.editor.string = "y"
        tv.openTableLink(.wiki("笔记甲"))
        #expect(tv.tableEditSession == nil)
        #expect(tv.string.contains("| y |"))
    }
}
