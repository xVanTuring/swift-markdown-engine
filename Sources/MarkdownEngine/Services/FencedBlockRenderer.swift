//
//  FencedBlockRenderer.swift
//  MarkdownEngine
//
//  The embedder draws a fenced code block of a language it owns as an image
//  (a diagram, a plot, …) instead of showing the source.
//

import AppKit
import Foundation

/// What the engine asks a `FencedBlockRenderer` to draw.
public struct FencedBlockRequest: Sendable, Equatable {
    /// The info string after the opening fence, trimmed (e.g. `"grapher"`).
    public let language: String
    /// The text between the fences, without the fence lines.
    public let content: String
    /// Body font size of the editor, in points.
    public let fontSize: CGFloat

    public init(language: String, content: String, fontSize: CGFloat) {
        self.language = language
        self.content = content
        self.fontSize = fontSize
    }
}

/// A rendered block: the image and the size it takes in the text (points).
public struct FencedBlockRendering: Sendable {
    public let image: NSImage
    public let size: CGSize

    public init(image: NSImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}

/// Draws fenced code blocks of chosen languages as images.
///
/// While the caret is outside a block, the engine hides its source and shows the image in its place, laid out like a
/// rendered `$$…$$` formula (centered, full height reserved). With the caret inside, the source comes back as normal
/// editable text. Blocks of other languages, and blocks the renderer returns `nil` for (bad input), stay plain code.
public protocol FencedBlockRenderer: Sendable {
    /// Info-string words this renderer takes, lowercased (e.g. `["grapher"]`). Empty = never asked.
    var languages: Set<String> { get }

    /// Draw one block, or `nil` to leave it as a code block.
    func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering?

    /// A coarse fingerprint of everything the images depend on besides the block text (available width, color theme, …).
    /// A different value makes the engine re-ask for every block.
    func fingerprint() -> AnyHashable
}

public extension FencedBlockRenderer {
    func fingerprint() -> AnyHashable { 0 }
}

/// Default: no language is taken.
public struct NoOpFencedBlockRenderer: FencedBlockRenderer {
    public init() {}
    public var languages: Set<String> { [] }
    public func render(_ request: FencedBlockRequest, theme: MarkdownEditorTheme) -> FencedBlockRendering? { nil }
}
