//
//  FencedBlockRendererTests.swift
//  MarkdownEngineTests
//
//  A fenced block of a language the embedder draws (`FencedBlockRenderer`) shows as the embedder's image while the
//  caret is elsewhere — source collapsed, one tall line carrying the image — and as plain code with the caret inside.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Fenced block renderer")
struct FencedBlockRendererTests {

    private struct StubRenderer: FencedBlockRenderer {
        var languages: Set<String> = ["grapher"]
        var returnsImage = true
        func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? {
            guard returnsImage else { return nil }
            let size = CGSize(width: 200, height: 120)
            return FencedBlockRendering(image: NSImage(size: size), size: size)
        }
        func fingerprint() -> AnyHashable { returnsImage }
    }

    private static let fontSize: CGFloat = 16
    private let text = "intro\n\n```grapher\nsurface: x\nview: azimuth=30\n```\n\nafter"

    /// The text styled the way the editor does it, with the caret at `caret`.
    private func styled(_ text: String, caret: Int, renderer: StubRenderer = StubRenderer()) throws -> NSTextStorage {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(fencedBlocks: renderer)
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = config
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: NSFont.systemFont(ofSize: Self.fontSize).fontName,
            fontSize: Self.fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: config
        )
        tv.baseFont = font
        tv.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(NSAttributedString(string: text))
        let length = (text as NSString).length
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: config.extensionRegistry)
        let active = MarkdownDetection.computeActiveTokenIndices(
            selectionRange: NSRange(location: caret, length: 0), tokens: tokens, in: text as NSString)
        let ranges = MarkdownStyler.styleAttributes(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            layoutBridge: tv.layoutBridge,
            caretLocation: caret,
            activeTokenIndices: active,
            precomputedTokens: tokens,
            configuration: config
        )
        TextStylingService.applyStyledRanges(
            ranges,
            paragraphs: [NSRange(location: 0, length: length)],
            baseAttributes: [.font: font, .foregroundColor: config.theme.bodyText, .paragraphStyle: style],
            to: tv.textStorage
        )
        return try #require(tv.textStorage)
    }

    private func imageAnchors(in storage: NSTextStorage) -> [NSRange] {
        var found: [NSRange] = []
        storage.enumerateAttribute(.latexImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { found.append(range) }
        }
        return found
    }

    @Test("caret outside: the block becomes one image anchored on its first content character")
    func rendersWhenCaretIsOutside() throws {
        let storage = try styled(text, caret: (text as NSString).length)
        let anchors = imageAnchors(in: storage)
        #expect(anchors.count == 1)
        let anchor = try #require(anchors.first)
        let first = (text as NSString).range(of: "surface")
        #expect(anchor.location == first.location)
        #expect(storage.attribute(.latexIsBlock, at: anchor.location, effectiveRange: nil) as? Bool == true)
        let bounds = try #require(storage.attribute(.latexBounds, at: anchor.location, effectiveRange: nil) as? NSValue)
        #expect(bounds.rectValue.size == CGSize(width: 200, height: 120))

        // The fence lines are hidden and the code background is gone.
        let fence = (text as NSString).range(of: "```grapher")
        let color = storage.attribute(.foregroundColor, at: fence.location, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.clear)
        let background = storage.attribute(.backgroundColor, at: first.location, effectiveRange: nil) as? NSColor
        #expect(background == nil || background == NSColor.clear)
    }

    @Test("caret inside: the source is shown as plain code, no image")
    func showsSourceWhenCaretIsInside() throws {
        let inside = (text as NSString).range(of: "azimuth").location
        let storage = try styled(text, caret: inside)
        #expect(imageAnchors(in: storage).isEmpty)
    }

    @Test("other languages and a nil rendering stay code")
    func leavesOtherBlocksAlone() throws {
        let other = "```swift\nlet x = 1\n```\n\nafter"
        #expect(imageAnchors(in: try styled(other, caret: (other as NSString).length)).isEmpty)

        var failing = StubRenderer()
        failing.returnsImage = false
        #expect(imageAnchors(in: try styled(text, caret: (text as NSString).length, renderer: failing)).isEmpty)

        let empty = "```grapher\n```\n\nafter"
        #expect(imageAnchors(in: try styled(empty, caret: (empty as NSString).length)).isEmpty)
    }

    @Test("no renderer registered: nothing changes")
    func defaultRendererDoesNothing() throws {
        var none = StubRenderer()
        none.languages = []
        #expect(imageAnchors(in: try styled(text, caret: (text as NSString).length, renderer: none)).isEmpty)
    }

    @Test("the drawn image's frame can be queried for an overlay")
    func reportsTheFrameOfTheDrawnImage() throws {
        _ = NSApplication.shared
        let storage = try styled(text, caret: (text as NSString).length)
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(fencedBlocks: StubRenderer())
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.configuration = config
        tv.textContainer?.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(storage)
        // The editor installs this delegate itself; without it the fragments are plain AppKit ones.
        let tlm = try #require(tv.textLayoutManager)
        let delegate = MarkdownLayoutManagerDelegate()
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        let frames = withExtendedLifetime(delegate) { tv.renderedBlockFrames() }
        #expect(frames.count == 1)
        let item = try #require(frames.first)
        #expect(item.anchor.location == (text as NSString).range(of: "surface").location)
        #expect(item.frame.size == CGSize(width: 200, height: 120))
        // Centered in the 600pt column.
        #expect(abs(item.frame.midX - 300) < 12)
        // Below the intro paragraph, above the trailing one.
        #expect(item.frame.minY > 10)
        #expect(item.frame.maxY < tv.frame.height + 400)
    }

    @Test("the layout fingerprint follows the renderer's")
    func fingerprintIsFolded() {
        var a = MarkdownEditorServices(fencedBlocks: StubRenderer())
        let first = a.layoutFingerprint()
        var failing = StubRenderer()
        failing.returnsImage = false
        a.fencedBlocks = failing
        #expect(a.layoutFingerprint() != first)
    }
}
