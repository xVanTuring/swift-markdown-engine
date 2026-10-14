//
//  MarkdownStyler+FencedBlocks.swift
//  MarkdownEngine
//
//  A fenced code block whose language the embedder draws itself (`FencedBlockRenderer`) is shown as that image,
//  laid out like a rendered `$$…$$` formula: the source collapses to nothing and one tall line carries the image.
//  With the caret inside the block the source comes back as ordinary code.
//

import AppKit
import Foundation

extension MarkdownStyler {

    static func styleFencedBlocks(_ ctx: StylingContext) -> [StyledRange] {
        let renderer = ctx.services.fencedBlocks
        let languages = renderer.languages
        guard !languages.isEmpty else { return [] }

        var attrs: [StyledRange] = []
        for (idx, token) in ctx.tokens.enumerated() where token.kind == .codeBlock {
            if ctx.outsideScope(token.range) || ctx.activeTokenIndices.contains(idx) { continue }
            guard let openLine = token.markerRanges.first,
                  let language = fenceLanguage(of: openLine, in: ctx.nsText),
                  languages.contains(language.lowercased()) else { continue }

            let rawContent = ctx.nsText.substring(with: token.contentRange)
            let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty,
                  let rendering = renderer.render(
                      FencedBlockRequest(language: language, content: content, fontSize: ctx.baseFont.pointSize),
                      theme: ctx.configuration.theme) else { continue }

            // The code look (background, spell-check marks) goes away along with the source.
            attrs.append((token.range, [.backgroundColor: NSColor.clear, NSAttributedString.Key.spellingState: 0]))
            let drawn = appendRenderedStandaloneBlock(
                for: token,
                rawContent: rawContent,
                image: rendering.image,
                imageBounds: CGRect(x: 0, y: 0, width: rendering.size.width, height: rendering.size.height),
                paragraphSpacingBefore: ctx.configuration.blockLatex.paragraphSpacingBefore,
                paragraphSpacing: ctx.configuration.blockLatex.paragraphSpacing,
                alignment: .center,
                mode: .collapsedSource(markerTexts: []),
                ctx: ctx,
                attrs: &attrs)
            if !drawn {
                // Not on lines of its own (inside a list item, say): keep it as code.
                attrs.removeLast()
            }
        }
        return attrs
    }

    /// The word after the opening backticks: "```grapher\n" → "grapher".
    private static func fenceLanguage(of openLine: NSRange, in text: NSString) -> String? {
        let line = text.substring(with: openLine)
        let word = line.drop { $0 == "`" }.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? nil : word
    }
}
