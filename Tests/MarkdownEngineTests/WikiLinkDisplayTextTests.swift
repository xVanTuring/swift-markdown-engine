//
//  WikiLinkDisplayTextTests.swift
//  MarkdownEngineTests
//
//  A resolver can give a link shorter text to show (`[[Book#page=152]]` → `p.152`).
//  Display only: the name is hidden by size and kerned out to the shown text's
//  width, the fragment paints the text, and the caret brings the source back.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wiki-link display text")
struct WikiLinkDisplayTextTests {

    private struct PageResolver: WikiLinkResolver {
        func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? {
            guard let hash = displayName.range(of: "#page=") else {
                return displayName == "Note" ? WikiLinkResolution(id: "n", exists: true) : nil
            }
            return WikiLinkResolution(id: displayName, exists: true,
                                      displayText: "p." + displayName[hash.upperBound...],
                                      toolTip: String(displayName[..<hash.lowerBound]))
        }
    }

    private static let fontSize: CGFloat = 16

    private func makeTextView(_ text: String, caret: Int? = nil) -> (NativeTextView, NSFont) {
        _ = NSApplication.shared
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(wikiLinks: PageResolver())
        let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tv.configuration = config
        let (font, style) = TextStylingService.makeBaseFontAndStyle(
            fontName: NSFont.systemFont(ofSize: Self.fontSize).fontName,
            fontSize: Self.fontSize,
            layoutBridge: tv.layoutBridge,
            configuration: config
        )
        tv.baseFont = font
        tv.textStorage?.setAttributedString(NSAttributedString(string: text))
        let length = (text as NSString).length
        let ranges = MarkdownStyler.styleAttributes(
            text: text,
            fontName: font.fontName,
            fontSize: font.pointSize,
            layoutBridge: tv.layoutBridge,
            caretLocation: caret ?? length,
            activeTokenIndices: [],
            configuration: config
        )
        TextStylingService.applyStyledRanges(
            ranges,
            paragraphs: [NSRange(location: 0, length: length)],
            baseAttributes: [.font: font, .foregroundColor: config.theme.bodyText, .paragraphStyle: style],
            to: tv.textStorage
        )
        return (tv, font)
    }

    /// x of the character at `index` within its line.
    private func x(at index: Int, in tv: NativeTextView) throws -> CGFloat {
        let tlm = try #require(tv.textLayoutManager)
        let tcm = try #require(tlm.textContentManager)
        tlm.ensureLayout(for: tlm.documentRange)
        var result: CGFloat?
        tlm.enumerateTextLayoutFragments(from: tcm.documentRange.location, options: [.ensuresLayout]) { fragment in
            let start = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let r = line.characterRange
                let local = index - start
                if local >= r.location, local <= NSMaxRange(r) {
                    result = line.locationForCharacter(at: local).x
                    return false
                }
            }
            return true
        }
        return try #require(result)
    }

    @Test("a link with display text shows it in place of the name, the width of the shown text")
    func showsDisplayText() throws {
        let text = "see [[Linear Algebra#page=152]] here\n\nend"
        let name = NSRange(location: 6, length: 24)
        let (tv, font) = makeTextView(text)
        let storage = try #require(tv.textStorage)
        #expect(storage.attribute(.wikiLinkDisplay, at: name.location, effectiveRange: nil) as? String == "p.152")
        #expect(storage.attribute(.link, at: name.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.toolTip, at: name.location, effectiveRange: nil) as? String == "Linear Algebra")
        for i in name.location..<NSMaxRange(name) {
            let f = try #require(storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)
            #expect(f.pointSize < 1, "index \(i) is \(f.pointSize)pt")
        }
        // The name's room is the shown text's width.
        let shown = ("p.152" as NSString).size(withAttributes: [.font: font]).width
        let room = try x(at: NSMaxRange(name), in: tv) - x(at: name.location, in: tv)
        #expect(abs(room - shown) < 1.5, "room \(room) vs \(shown)")
    }

    @Test("the caret in the link shows its source; links without display text are untouched")
    func caretRevealsSource() throws {
        let (tv, _) = makeTextView("see [[Linear Algebra#page=152]] here", caret: 10)
        let storage = try #require(tv.textStorage)
        #expect(storage.attribute(.wikiLinkDisplay, at: 6, effectiveRange: nil) == nil)

        let (plain, _) = makeTextView("see [[Note]] here\n\nend")
        let ps = try #require(plain.textStorage)
        #expect(ps.attribute(.wikiLinkDisplay, at: 6, effectiveRange: nil) == nil)
        #expect(ps.attribute(.link, at: 6, effectiveRange: nil) != nil)
    }

    /// Not an assertion: writes a sample to look at (`WIKI_SAMPLE=/path.png`).
    @Test("sample image", .enabled(if: ProcessInfo.processInfo.environment["WIKI_SAMPLE"] != nil))
    func sample() throws {
        let (tv, _) = makeTextView("以 3 阶矩阵为例（[[27张宇基础30讲线代#page=152]]）：\n\n关系([[27张宇基础30讲线代#page=152]]、[[27张宇基础30讲线代#page=153]])：把 [[Note]] 按\n\n- bullet [[27张宇基础30讲线代#page=9]]\n\nend")
        tv.appearance = NSAppearance(named: .darkAqua)
        // The fragment that paints display text, bullets and the like (as `NativeTextViewWrapper` installs it).
        let delegate = MarkdownLayoutManagerDelegate()
        let tlm = try #require(tv.textLayoutManager)
        tlm.delegate = delegate
        tlm.invalidateLayout(for: tlm.documentRange)
        tlm.ensureLayout(for: tlm.documentRange)
        let rep = try #require(tv.bitmapImageRepForCachingDisplay(in: tv.bounds))
        tv.cacheDisplay(in: tv.bounds, to: rep)
        let path = ProcessInfo.processInfo.environment["WIKI_SAMPLE"]!
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        withExtendedLifetime(delegate) {}
    }
}
