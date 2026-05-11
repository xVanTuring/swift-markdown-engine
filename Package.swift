// swift-tools-version: 5.9
import PackageDescription

// MarkdownEngine — a TextKit-2 backed Markdown editor view for macOS.
//
// Embedders import `MarkdownEngine` and supply their own adapters that
// conform to the engine's service protocols (`WikiLinkResolver`,
// `EmbeddedImageProvider`, `SyntaxHighlighter`, `LatexRenderer`). The engine
// itself has zero external dependencies.
//
// Users who want syntax highlighting for fenced code blocks without
// writing their own bridge can additionally depend on the
// `MarkdownEngineHighlighter` product, which ships a turnkey
// `SyntaxHighlighter` conformance backed by HighlighterSwift. The
// extra product is opt-in: the core `MarkdownEngine` library stays
// HighlighterSwift-free at link time.
let package = Package(
    name: "MarkdownEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownEngine", targets: ["MarkdownEngine"]),
        .library(name: "MarkdownEngineHighlighter", targets: ["MarkdownEngineHighlighter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/smittytone/HighlighterSwift", from: "3.0.0")
    ],
    targets: [
        .target(name: "MarkdownEngine"),
        .target(
            name: "MarkdownEngineHighlighter",
            dependencies: [
                "MarkdownEngine",
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ]
        ),
        .testTarget(
            name: "MarkdownEngineTests",
            dependencies: ["MarkdownEngine"]
        )
    ]
)
