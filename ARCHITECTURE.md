# Architecture

MarkdownEngine is a TextKit 2 backed Markdown editor for macOS, exposed
to SwiftUI through `NativeTextViewWrapper`. This document is a codemap
and pipeline guide for contributors. For a user-facing intro, see the
[README](README.md).

## Bird's-eye view

The engine takes a Markdown `String`, tokenizes it, runs an ordered
pipeline of styling passes, and applies the resulting attributes to an
`NSTextView`. There is **no internal AST** — tokens carry `NSRange` spans
into the text, and styling is a flat list of `(range, attributes)`
tuples. Everything app-specific (wiki-link IDs, syntax highlighting,
embedded images, LaTeX) is provided by four service protocols the
embedder implements — or by the opt-in bridge products described below.

```
String  ──►  Tokenizer  ──►  [MarkdownToken]
                                 │
String + caret ───────────────────► active tokens (markers stay visible)
                                 │
                          MarkdownStyler.styleAttributes()
                                 │  (ordered styling passes)
                                 ▼
                          [StyledRange]
                                 │
                  NativeTextViewCoordinator.rebuildTextStorageAndStyle()
                                 │
                                 ▼
                          NSTextView
```

## Products

The package ships three library products. Embedders pick the subset they
need:

| Product | Target directory | What it adds | Transitive deps |
|---|---|---|---|
| `MarkdownEngine` | `Sources/MarkdownEngine/` | The editor itself | None |
| `MarkdownEngineCodeBlocks` | `Sources/MarkdownEngineCodeBlocks/` | `HighlighterSwiftBridge` — ready-made `SyntaxHighlighter` conformance | HighlighterSwift |
| `MarkdownEngineLatex` | `Sources/MarkdownEngineLatex/` | `SwiftMathBridge` — ready-made `LatexRenderer` conformance | SwiftMath |

Everything below describes the core `MarkdownEngine` target unless
noted. The bridge targets are thin wrappers (≈150–200 lines each) that
adapt their underlying library to the engine's service protocols and
add the caching the engine doesn't do internally.

## Codemap

All paths below are relative to `Sources/MarkdownEngine/`.

| Directory | Role | Where to start |
|---|---|---|
| `Configuration/` | Theme + tunable knob structs | `MarkdownEditorConfiguration.swift` |
| `Services/` | The 4 protocols embedders implement, no-op defaults, wiki-link transform | `MarkdownEditorServices.swift` |
| `Parser/` | Regex-driven tokenizer; emphasis runs through a stack parser | `MarkdownTokenizer.swift` |
| `Styling/` | One file per token class, orchestrated by `MarkdownStyler.styleAttributes()` | `MarkdownStyler.swift` |
| `Renderer/` | TextKit 2 layout wrappers, image cache, custom `NSTextLayoutFragment` | `LayoutBridge.swift` |
| `Input/` | Typing helpers (LaTeX / image auto-wrap, list continuation) | `MarkdownInputHandler.swift` |
| `TextView/` | The `NSTextView` subclass, the coordinator, and the SwiftUI bridge | `NativeTextViewWrapper.swift` |
| `MarkdownEngine.docc/` | DocC catalog | `MarkdownEngine.md` |

`TextView/` is the biggest directory. Two sub-folders matter:

- `NativeTextView/` — extensions on the AppKit subclass (paste,
  drag-select boost, spell policy, caret workarounds, etc.)
- `Coordinator/` — `NSTextViewDelegate` glue, split by concern
  (restyling, writing-tools, find, code-blocks, inline selection,
  autocorrect)

## The pipeline

### 1. Tokenize

`MarkdownTokenizer.parseTokens(in: text)` returns a flat
`[MarkdownToken]`. Each token has a `kind`, a `range`, a `contentRange`,
and `markerRanges` (for `**bold**`, the two `**`). Tokenization is pure,
allocation-light, and cheap enough to re-run on every keystroke.

Token kinds live in `Parser/MarkdownToken.swift`: `italic`, `bold`,
`boldItalic`, `link`, `wikiLink`, `heading`, `codeBlock`, `inlineCode`,
`blockLatex`, `inlineLatex`, `imageEmbed`.

### 2. Compute active tokens

The coordinator finds which tokens contain the caret — those are
*active* and their markers stay full size. Inactive markers go through
`shrinkInactiveMarkers` (in `MarkdownStyler.swift`) and render at
`hiddenMarkerFontSize`. **Markers are never removed from text storage;
they only visually shrink.** This is why copy, undo, find, and selection
stay aligned with what's on disk.

### 3. Style

`MarkdownStyler.styleAttributes()` (`MarkdownStyler.swift:78`) runs an
ordered pipeline of styling passes. Each pass returns
`[StyledRange] = [(range, attributes)]`. Passes are linear and additive
— later passes can clobber earlier ones, which is intentional
(`shrinkInactiveMarkers` runs last for that reason).

If the coordinator passes `scopedRanges`, range-based scans (auto-link
detection, etc.) only touch those paragraphs — that's the optimization
that keeps per-keystroke styling cheap.

### 4. Apply

`NativeTextViewCoordinator+Restyling.swift` runs the wiki-link
storage → display transform (`WikiLinkService`), sets
`NSTextView.string`, then walks the `[StyledRange]` list and calls
`addAttribute(_:value:range:)` on the text storage.

## Invariants

1. **The core `MarkdownEngine` target has zero external dependencies.**
   The four heavy pieces (wiki-link resolution, images, syntax
   highlighting, LaTeX) ship as `Sendable` protocols with no-op
   defaults. The opt-in bridge targets
   (`MarkdownEngineCodeBlocks`, `MarkdownEngineLatex`) layer deps on
   top — never pull HighlighterSwift or SwiftMath into the core target.
2. **Tokens are pure and re-derivable.** Don't cache tokens outside
   `NativeTextViewCoordinator`; don't mutate token ranges after a
   styling pass.
3. **Markers shrink, they don't disappear.** Anything tempted to remove
   characters from text storage to "hide" markup is wrong — every
   selection / copy / find / undo bug downstream will trace back to it.
4. **Wiki-link storage and display are different strings.** Storage:
   `[[Name|<id>]]`. Display: `[[Name]]`. `WikiLinkService` handles both
   directions; display IDs must never leak into the binding.
5. **Service callbacks are synchronous.** `SyntaxHighlighter.highlight()`
   and `LatexRenderer.render()` block. If an embedder's implementation
   is slow, they cache (both bundled bridges do this); the engine won't
   async-render for them.
6. **Spelling is suppressed inside code, LaTeX, and wiki-link markers.**
   Don't override `.spellingState = 0` without thinking through
   code-block UX.
7. **Public surface stays small.** Favor `internal`. Most types in
   `Styling/`, `Renderer/`, and `TextView/` are intentionally internal.
   New public symbols need a DocC comment.

## Worked example: adding a new inline syntax

Let's add spoilers: `||hidden text||`. Four files change, all inside the
core `MarkdownEngine` target.

**1.** `Parser/MarkdownToken.swift` — add a kind:

```swift
case spoiler
```

**2.** `Parser/MarkdownTokenizer.swift` — add a regex (model on
`imageEmbedRegex` at the top of the file) and a parse loop inside
`parseTokens(in:)`:

```swift
static let spoilerRegex = try! NSRegularExpression(
    pattern: #"\|\|([^\|\r\n]+)\|\|"#
)

// inside parseTokens(in:)
for match in spoilerRegex.matches(in: text, options: [], range: fullRange) {
    let full = match.range
    let content = match.range(at: 1)
    let open = NSRange(location: full.location, length: 2)
    let close = NSRange(location: full.location + full.length - 2, length: 2)
    tokens.append(MarkdownToken(kind: .spoiler,
                                range: full,
                                contentRange: content,
                                markerRanges: [open, close]))
}
```

**3.** New file `Styling/MarkdownStyler+Spoiler.swift`:

```swift
import AppKit

extension MarkdownStyler {
    static func styleSpoilers(_ ctx: StylingContext) -> [StyledRange] {
        var out: [StyledRange] = []
        for token in ctx.tokens where token.kind == .spoiler {
            out.append((token.contentRange,
                        [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }
}
```

**4.** `Styling/MarkdownStyler.swift` — call the new pass in
`styleAttributes()`, before `shrinkInactiveMarkers(ctx)`:

```swift
result += styleSpoilers(ctx)
```

Add a test in `Tests/MarkdownEngineTests/`, an entry in `CHANGELOG.md`
under `[Unreleased]`, and you're done. No changes to bridge targets are
needed — new syntax types live entirely in the core engine.

## Where to look next

- **Configuration knobs:** `Configuration/MarkdownEditorConfiguration.swift`
- **Color palette:** `Configuration/MarkdownEditorTheme.swift`
- **Wiki-link transform:** `Services/WikiLinkService.swift`
- **Caret-aware marker visibility:** `MarkdownStyler.swift` →
  `shrinkInactiveMarkers`
- **Typing-time behavior:** `Input/MarkdownInputHandler.swift`,
  `Input/MarkdownListHandler.swift`
- **Cross-view formatting commands:** `Services/MarkdownEditorServices.swift`
  → `MarkdownEditorBus`
- **LaTeX / image caching inside the engine:**
  `Renderer/EmbeddedImageCache.swift`
- **Reference bridge implementations:**
  `Sources/MarkdownEngineCodeBlocks/HighlighterSwiftBridge.swift`,
  `Sources/MarkdownEngineLatex/SwiftMathBridge.swift`
