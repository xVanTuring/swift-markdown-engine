//
//  CJKTableWrappingTests.swift
//  MarkdownEngine
//
//  (fork: xVanTuring) Chinese / Japanese / Korean cells wrap like Latin ones.
//  Written without spaces, a CJK sentence used to count as one unbreakable
//  word, so the column minimum was the whole sentence and every CJK table of
//  any length overflowed into the horizontal-scroll overlay.
//

import AppKit
import Foundation
import Testing
@testable import MarkdownEngine

@Suite("CJK table wrapping")
struct CJKTableWrappingTests {

    private let cjkSource = """
    | 方式 | 原理 | 特点 |
    |---|---|---|
    | 调幅（AM） | 用载波的振幅变化表示数字信号，两种振幅分别对应二进制的 0 和 1 | 实现简单，但抗干扰能力差，容易受到噪声影响 |
    | 正交幅度调制（QAM） | 同时调制振幅和相位，形成复合信号，从而在有限带宽内实现更高的数据传输速率 | 每个码元携带多个比特，频带利用率高，是现代通信常用的调制方式 |
    """

    private func render(_ source: String, availableWidth: CGFloat) throws -> NSImage {
        let parsed = try #require(MarkdownStyler.parseTableSource(source))
        let font = NSFont.systemFont(ofSize: 15)
        var ctx = MarkdownStyler.StylingContext(
            nsText: source as NSString,
            tokens: [],
            codeTokens: [],
            activeTokenIndices: [],
            baseFont: font,
            layoutBridge: nil,
            baseDefaultLineHeight: 18,
            codeBackgroundColor: .windowBackgroundColor,
            latexMarkerFont: font,
            configuration: .default,
            wikiLinkIDProvider: { _ in nil }
        )
        ctx.scopeBounds = nil
        let aqua = try #require(NSAppearance(named: .aqua))
        return MarkdownStyler.tableImage(
            for: source, parsed: parsed, ctx: ctx,
            appearance: aqua, availableWidth: availableWidth
        ).image
    }

    private func breaks(_ s: String) -> [Int] {
        Array(MarkdownStyler.cjkLineBreakOpportunities(in: s as NSString))
    }

    @Test func ideographsBreakBetweenEachOther() {
        #expect(breaks("中文表格") == [1, 2, 3])
    }

    @Test func punctuationStaysWithItsWord() {
        // No break before ， or 。 (they never start a line).
        let b = breaks("你好，世界。")
        #expect(!b.contains(2))
        #expect(!b.contains(5))
        #expect(b.contains(3))
        // No break after an opening bracket.
        #expect(!breaks("（注）说明").contains(1))
    }

    @Test func latinTextKeepsBreakingOnlyAtSpaces() {
        #expect(breaks("well-known https://example.com/a/b").isEmpty)
        // Mixed: breaks beside the CJK characters, none inside the Latin word.
        let b = breaks("QAM调制")
        #expect(b.contains(3))
        #expect(!b.contains(1) && !b.contains(2))
    }

    @Test func cjkTableWrapsToTheAvailableWidth() throws {
        let narrow = try render(cjkSource, availableWidth: 420)
        let wide = try render(cjkSource, availableWidth: 4000)
        #expect(narrow.size.width <= 420.5)
        // Same content in less width wraps onto more lines.
        #expect(narrow.size.height > wide.size.height + 20)
    }

    @Test func shortCJKTableKeepsItsNaturalWidth() throws {
        let source = """
        | 名称 | 数量 |
        |---|---|
        | 苹果 | 3 |
        """
        let a = try render(source, availableWidth: 420)
        let b = try render(source, availableWidth: 4000)
        #expect(abs(a.size.width - b.size.width) < 0.5)
        #expect(abs(a.size.height - b.size.height) < 0.5)
    }

    @Test func cjkColumnsKeepSixCharactersWhenTheTableOverflows() throws {
        // Too many columns to fit: columns sit at their minimums and the table
        // scrolls. A CJK column must not shrink to one character.
        let source = """
        | 特性 | 电路交换 | 报文交换 | 分组交换 | Notes |
        |---|---|---|---|---|
        | 基本原理 | EstablishTransferReleaseDedicatedPath | 存储转发：整个报文逐跳转发 | StoreAndForwardPacketsIndependently | AnotherVeryLongUnbreakableIdentifier |
        """
        let image = try render(source, availableWidth: 500)
        #expect(image.size.width > 500.5, "the table overflows (test premise)")
        let geometry = try #require(image.tableGeometry)
        let column2 = try #require(geometry.cellRect(row: 1, column: 2))
        // 15 pt font: six characters ≈ 90 pt of text, plus the cell padding.
        #expect(column2.width >= 90)
        // A short CJK column is not padded out past its own width.
        let column0 = try #require(geometry.cellRect(row: 0, column: 0))
        #expect(column0.width < 90 + 40)
    }
}
