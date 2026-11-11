//
//  SwiftMathBridge.swift
//  MarkdownEngineLatex
//
//  Ready-made LatexRenderer conformance backed by SwiftMath.
//

import AppKit
import Foundation
import CryptoKit
import SwiftMath
import MarkdownEngine

/// A drop-in ``LatexRenderer`` backed by [SwiftMath].
///
/// Renders both block (`$$ … $$`) and inline (`$ … $`) LaTeX strings into
/// `NSImage`s using the Latin Modern math font. Results are cached per
/// (latex, mode, font size, appearance, theme color fingerprint) so repeated
/// renders are free.
///
/// Light/dark appearance is taken from the host editor's window
/// effective appearance, not from `NSApp.effectiveAppearance`, so apps
/// that force a light window when the system is in dark mode still get
/// correctly-tinted formulas.
///
/// [SwiftMath]: https://github.com/mgriebling/SwiftMath
public final class SwiftMathBridge: LatexRenderer, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let latex: String
        let mode: LatexRenderMode
        let fontSize: CGFloat
        let isDarkMode: Bool
        let lightColorRGB: UInt32
        let darkColorRGB: UInt32
    }

    private struct CacheEntry {
        let image: NSImage
        let size: CGSize
        let baselineOffset: CGFloat
    }

    private let singleLetterPaddingBottom: CGFloat
    private var cache: [CacheKey: CacheEntry] = [:]
    private let cacheLock = NSLock()

    /// On-disk mirror of the render cache. The in-memory cache dies with the
    /// process, so the ~450ms cold render of a formula-heavy note used to recur on
    /// the FIRST open of every session. Persisting keeps it cold only on the very
    /// first render ever (per formula); every later launch loads the PNG from disk
    /// (~0.3ms) instead of typesetting (~2ms). Lives in the app's Caches dir, which
    /// the OS may purge under pressure — a purge just re-renders, so it is safe.
    private lazy var diskCacheDir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("MarkdownEngineLatex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Reused across renders: `MTMathUILabel()` adds an errorLabel subview on every
    /// init, so a fresh label per formula doubles the per-formula label overhead.
    /// render() is main-thread-only (it reads NSApp), so a single shared label is safe.
    private lazy var reusableLabel = MTMathUILabel()

    /// - Parameter singleLetterPaddingBottom: Extra bottom padding (in
    ///   points) added to single-letter formulas to prevent visual
    ///   clipping; matches the engine's
    ///   ``MarkdownEditorConfiguration/blockLatex/singleLetterPaddingBottom``
    ///   default. Override to match a customized configuration.
    public init(singleLetterPaddingBottom: CGFloat = 1.0) {
        self.singleLetterPaddingBottom = singleLetterPaddingBottom
    }

    /// Clears the rendered-image cache. Call after appearance flips if
    /// the host code doesn't re-render formulas automatically.
    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
        // The disk mirror is keyed by appearance/theme/font, so a flip already
        // maps to different keys; but an explicit clearCache() means "forget
        // everything", so drop the disk mirror too.
        if let dir = diskCacheDir {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - LatexRenderer

    public func render(
        latex: String,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        // Preserve the historical mode-less behavior.
        render(latex: latex, mode: .inline, fontSize: fontSize, theme: theme)
    }

    /// A formula's typesetting, bitmap and disk-cache passes leave ~0.6 MB of autoreleased temporaries.
    /// A note styles all its formulas in a single pass, so without a pool per formula they pile up
    /// until the pass ends: 500 cold formulas in one pass reached 334 MB, with the pool it stays flat.
    public func render(
        latex: String,
        mode: LatexRenderMode,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        autoreleasepool { renderUnpooled(latex: latex, mode: mode, fontSize: fontSize, theme: theme) }
    }

    private func renderUnpooled(
        latex: String,
        mode: LatexRenderMode,
        fontSize: CGFloat,
        theme: MarkdownEditorTheme
    ) -> LatexRenderResult? {
        let normalizedLatex = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLatex.isEmpty else { return nil }

        let appearance = NSApp.keyWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        let isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let textColor = isDarkMode ? theme.latexDarkModeText : theme.latexLightModeText
        let key = CacheKey(
            latex: normalizedLatex,
            mode: mode,
            fontSize: fontSize,
            isDarkMode: isDarkMode,
            lightColorRGB: Self.colorFingerprint(theme.latexLightModeText),
            darkColorRGB: Self.colorFingerprint(theme.latexDarkModeText)
        )

        cacheLock.lock()
        if let cached = cache[key] {
            cacheLock.unlock()
            return LatexRenderResult(
                image: cached.image,
                size: cached.size,
                baselineOffset: cached.baselineOffset
            )
        }
        cacheLock.unlock()

        // Disk mirror: a hit here skips the ~2ms typeset for a ~0.3ms PNG load.
        if let entry = loadFromDisk(key: key) {
            cacheLock.lock()
            cache[key] = entry
            cacheLock.unlock()
            return LatexRenderResult(image: entry.image, size: entry.size,
                                     baselineOffset: entry.baselineOffset)
        }

        guard let entry = renderLatex(
            normalizedLatex,
            mode: mode,
            fontSize: fontSize,
            textColor: textColor
        ) else {
            return nil
        }

        cacheLock.lock()
        cache[key] = entry
        cacheLock.unlock()
        saveToDisk(key: key, entry: entry)

        return LatexRenderResult(
            image: entry.image,
            size: entry.size,
            baselineOffset: entry.baselineOffset
        )
    }

    // MARK: - Disk cache

    /// Stable filename for a cache key: SHA-256 of the fingerprinting fields, hex.
    private func diskFilename(for key: CacheKey) -> String {
        let mode = key.mode == .display ? "display" : "inline"
        // `v2`: images are now sized by their ink, not only by SwiftMath's ascent/descent —
        // entries written before that are cut off at the bottom and must not be reused.
        // `v3`: CJK characters are drawn (`standInsForCJK`); earlier entries left them out.
        let composite = "v3|\(key.latex)|\(mode)|\(key.fontSize)|\(key.isDarkMode)|\(key.lightColorRGB)|\(key.darkColorRGB)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mathcache"
    }

    /// Persisted form: PNG pixels + the point-size and baseline the layout needs
    /// (PNG carries pixels only, not the point size or baseline, so they are stored
    /// alongside). Reconstructed image is byte-identical in appearance (PNG lossless).
    private func loadFromDisk(key: CacheKey) -> CacheEntry? {
        guard let dir = diskCacheDir else { return nil }
        let url = dir.appendingPathComponent(diskFilename(for: key))
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let png = plist["png"] as? Data,
              let w = plist["w"] as? Double, let h = plist["h"] as? Double,
              let baseline = plist["b"] as? Double,
              let rep = NSBitmapImageRep(data: png) else {
            return nil
        }
        let size = CGSize(width: w, height: h)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return CacheEntry(image: image, size: size, baselineOffset: CGFloat(baseline))
    }

    private func saveToDisk(key: CacheKey, entry: CacheEntry) {
        guard let dir = diskCacheDir,
              let rep = entry.image.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let plist: [String: Any] = [
            "png": png, "w": Double(entry.size.width), "h": Double(entry.size.height),
            "b": Double(entry.baselineOffset)
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        else { return }
        try? data.write(to: dir.appendingPathComponent(diskFilename(for: key)), options: .atomic)
    }

    // MARK: - Private

    /// TeX's rules 5–6 for binary signs, applied the way TeX does: looking past spacing and style
    /// changes. SwiftMath applies them in `MTMathList.finalized` against the atom right before the
    /// sign, so in `x = \; -1` it sees the `\;`, keeps `-` binary, and the typesetter then meets
    /// relation + binary — an invalid pair that trips `assert` in `getInterElementSpace` (a crash
    /// in Debug builds; release builds drop the spacing). A sign settled here as unary stays so
    /// through `finalized`, which only ever turns binary into unary.
    static func settleBinarySigns(in list: MTMathList?) {
        forEachList(in: list) { list in
            var prev: MTMathAtom?
            for atom in list.atoms {
                if atom.type == .space || atom.type == .style { continue }   // glue, not an atom, to TeX
                switch atom.type {
                case .binaryOperator:
                    if prev.map({ [.binaryOperator, .relation, .open, .punctuation, .largeOperator].contains($0.type) }) ?? true {
                        atom.type = .unaryOperator
                    }
                case .relation, .punctuation, .close:
                    if let p = prev, p.type == .binaryOperator { p.type = .unaryOperator }
                default:
                    break
                }
                prev = atom
            }
            if let p = prev, p.type == .binaryOperator { p.type = .unaryOperator }
        }
    }

    /// SwiftMath's parser drops every character outside ASCII (Cyrillic and accented Latin aside), so
    /// `[X]_补` came out as `[X]` and `x>0 \text{且} y>0` as `x>0 y>0`. Each CJK character goes to the
    /// parser as a Cyrillic letter the formula doesn't use instead — SwiftMath keeps that as an ordinary
    /// atom — and `restoreCJK` puts the character back into the atom; Core Text then draws it in a system
    /// CJK font (font fallback). One stand-in per character, so a script takes one token as in TeX:
    /// `_补码` subscripts only `补`. Characters beyond the 64 stand-ins stay as they were (dropped).
    static func standInsForCJK(_ latex: String) -> (latex: String, originals: [String: String]) {
        guard latex.unicodeScalars.contains(where: { isCJK($0.value) }) else { return (latex, [:]) }
        let used = Set(latex.unicodeScalars)
        var pool = (UInt32(0x0410)...UInt32(0x044F)).compactMap(Unicode.Scalar.init).filter { !used.contains($0) }
        pool.reverse()   // so `popLast` hands them out in order
        var standIn: [Unicode.Scalar: Unicode.Scalar] = [:]
        var originals: [String: String] = [:]
        var out = String.UnicodeScalarView()
        // SwiftMath reads a command name as every cased letter that follows the backslash, Cyrillic
        // included: `\quad时` must go in as `\quad Л`, or it parses as the unknown command `\quadЛ`.
        var afterBackslash = false, inControlWord = false
        for s in latex.unicodeScalars {
            if isCJK(s.value), let c = standIn[s] ?? pool.popLast() {
                standIn[s] = c
                originals[String(c)] = String(s)
                if inControlWord { out.append(" ") }
                out.append(c)
                afterBackslash = false; inControlWord = false
                continue
            }
            out.append(s)
            let asciiLetter = s.isASCII && s.properties.isAlphabetic
            if afterBackslash {
                afterBackslash = false
                inControlWord = asciiLetter   // `\\` and `\,` are one-character commands
            } else if s == "\\" {
                afterBackslash = true; inControlWord = false
            } else {
                inControlWord = inControlWord && asciiLetter
            }
        }
        return (String(out), originals)
    }

    /// Puts back the characters `standInsForCJK` replaced, in every list of the parsed formula.
    static func restoreCJK(in list: MTMathList?, _ originals: [String: String]) {
        guard !originals.isEmpty else { return }
        forEachList(in: list) { list in
            for atom in list.atoms {
                if let original = originals[atom.nucleus] { atom.nucleus = original }
            }
        }
    }

    /// Han, kana, Hangul, and the CJK / full-width punctuation that goes with them — the same ranges
    /// as the parser's `InlineParser.isCJK`, which decides what may sit inside a formula.
    private static func isCJK(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x11FF, 0x2E80...0x2FFF, 0x3000...0x303F, 0x3040...0x31FF, 0x3200...0x4DBF,
             0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFE30...0xFE4F,
             0xFF00...0xFFEF, 0x20000...0x3FFFF:
            return true
        default:
            return false
        }
    }

    /// Calls `body` on `list` and on every list nested in it: scripts, fraction parts, radicand and
    /// degree, inner / over / under / accent / colour groups, table cells.
    static func forEachList(in list: MTMathList?, _ body: (MTMathList) -> Void) {
        guard let list else { return }
        body(list)
        for atom in list.atoms {
            forEachList(in: atom.subScript, body)
            forEachList(in: atom.superScript, body)
            switch atom {
            case let a as MTFraction: forEachList(in: a.numerator, body); forEachList(in: a.denominator, body)
            case let a as MTRadical: forEachList(in: a.radicand, body); forEachList(in: a.degree, body)
            case let a as MTInner: forEachList(in: a.innerList, body)
            case let a as MTOverLine: forEachList(in: a.innerList, body)
            case let a as MTUnderLine: forEachList(in: a.innerList, body)
            case let a as MTAccent: forEachList(in: a.innerList, body)
            case let a as MTMathColor: forEachList(in: a.innerList, body)
            case let a as MTMathTextColor: forEachList(in: a.innerList, body)
            case let a as MTMathColorbox: forEachList(in: a.innerList, body)
            case let a as MTMathTable: a.cells.joined().forEach { forEachList(in: $0, body) }
            default: break
            }
        }
    }

    /// Fold an `NSColor` to a 24-bit fingerprint that's good enough to
    /// bust the cache when the theme changes the LaTeX text color.
    private static func colorFingerprint(_ color: NSColor) -> UInt32 {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
        let r = UInt32(max(0, min(255, Int(rgb.redComponent * 255))))
        let g = UInt32(max(0, min(255, Int(rgb.greenComponent * 255))))
        let b = UInt32(max(0, min(255, Int(rgb.blueComponent * 255))))
        return (r << 16) | (g << 8) | b
    }

    private func renderLatex(
        _ latex: String,
        mode: LatexRenderMode,
        fontSize: CGFloat,
        textColor: NSColor
    ) -> CacheEntry? {
        // Reused instance (see `reusableLabel`); every property is set below so no
        // stale state carries between formulas.
        let mathLabel = reusableLabel
        // Parsed here instead of through `mathLabel.latex` so CJK can get through the parser
        // (`standInsForCJK`) and binary signs beside spacing can be settled first
        // (`settleBinarySigns`). A parse error still leaves no display list.
        var parseError: NSError?
        let (parseable, cjk) = Self.standInsForCJK(latex)
        let mathList = MTMathListBuilder.build(fromString: parseable, error: &parseError)
        if parseError == nil {
            Self.restoreCJK(in: mathList, cjk)
            Self.settleBinarySigns(in: mathList)
        }
        mathLabel.mathList = parseError == nil ? mathList : nil
        mathLabel.fontSize = fontSize
        mathLabel.textColor = textColor
        mathLabel.textAlignment = .left
        mathLabel.labelMode = mode == .display ? .display : .text

        // Latin Modern Math gives the cleanest LaTeX glyphs at typical sizes.
        if let mathFont = MTFontManager().font(withName: "latinmodern-math", size: fontSize) {
            mathLabel.font = mathFont
        }

        mathLabel.layoutSubtreeIfNeeded()

        guard let displayList = mathLabel.displayList else { return nil }

        // SwiftMath skips unsupported glyphs (e.g. emoji/raw Greek), which can yield
        // zero-sized output. Bail instead of trying to render a 0x0 image — lockFocus
        // (used internally by NSImage drawing) crashes on zero dimensions.
        let exactWidth = displayList.width
        let exactHeight = displayList.ascent + displayList.descent
        guard exactWidth > 0, exactHeight > 0 else { return nil }

        let isSimpleSingleLetter = latex.range(of: #"^[A-Za-z]{1,3}$"#, options: .regularExpression) != nil
        let paddingBottom: CGFloat = isSimpleSingleLetter ? singleLetterPaddingBottom : 0
        let canvasHeight = exactHeight + paddingBottom

        // `displayList.width` is the advance width, which excludes the right-side ink
        // overhang of slanted glyphs (V, Y, P, F, …), and its ascent/descent run short
        // of the ink too — subscripts (`a_n`, `\lim_{n\to\infty}`) hang below the
        // reported descent. Cropping to those numbers clips the glyphs, so render with
        // slack on the right, top and bottom, then crop to the measured ink.
        let rightSlack = ceil(fontSize)
        let vSlack = ceil(fontSize * 0.5)
        let probeWidth = ceil(exactWidth) + rightSlack
        let probeHeight = canvasHeight + 2 * vSlack

        // The label centres the formula in what the insets leave, i.e. in the same
        // `canvasHeight` band as before, now sitting `vSlack` inside the probe.
        mathLabel.contentInsets = MTEdgeInsets(top: vSlack, left: 0, bottom: vSlack, right: 0)
        defer { mathLabel.contentInsets = MTEdgeInsets() }

        guard let probeRep = renderLabelToRep(mathLabel, size: CGSize(width: probeWidth, height: probeHeight)),
              let probeCG = probeRep.cgImage else {
            return nil
        }

        let ink = Self.inkBounds(probeCG, sizeInPoints: CGSize(width: probeWidth, height: probeHeight))
        let finalWidth = max(ceil(exactWidth), ceil(ink?.right ?? exactWidth))
        // Whole points, so the crop lands on pixel rows at any backing scale.
        let extraTop = max(0, min(vSlack, ceil(vSlack - (ink?.top ?? vSlack))))
        let extraBottom = max(0, min(vSlack, ceil((ink?.bottom ?? 0) - (vSlack + canvasHeight))))
        let finalSize = CGSize(width: finalWidth, height: canvasHeight + extraTop + extraBottom)

        // Points→pixels via the rep, so this is correct at any backing scale.
        let pxPerPoint = CGFloat(probeCG.width) / probeWidth
        let cropRect = CGRect(
            x: 0,
            y: ((vSlack - extraTop) * pxPerPoint).rounded(),
            width: min(CGFloat(probeCG.width), (finalWidth * pxPerPoint).rounded()),
            height: (finalSize.height * pxPerPoint).rounded()
        )
        guard cropRect.width > 0, cropRect.height > 0,
              let croppedCG = probeCG.cropping(to: cropRect) else {
            return nil
        }

        let finalRep = NSBitmapImageRep(cgImage: croppedCG)
        finalRep.size = finalSize
        let image = NSImage(size: finalSize)
        image.addRepresentation(finalRep)

        return CacheEntry(
            image: image,
            size: finalSize,
            baselineOffset: displayList.descent + extraBottom
        )
    }

    private func renderLabelToRep(_ label: MTMathUILabel, size: CGSize) -> NSBitmapImageRep? {
        // `bitmapImageRepForCachingDisplay` + `cacheDisplay(in:to:)` is the
        // documented way to snapshot an NSView that isn't in a window. Setting
        // `wantsLayer = true` and `layer.render(in:)` snapshots the (empty)
        // backing layer instead of triggering MTMathUILabel's `draw(_:)`.
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutSubtreeIfNeeded()

        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return nil }
        label.cacheDisplay(in: label.bounds, to: rep)
        return rep
    }

    /// Edges (in points, y from the top) of the non-transparent ink, or `nil` if empty —
    /// lets us crop a formula to its true ink instead of its typographic box.
    private static func inkBounds(
        _ image: CGImage, sizeInPoints: CGSize
    ) -> (right: CGFloat, top: CGFloat, bottom: CGFloat)? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0, sizeInPoints.width > 0, sizeInPoints.height > 0 else { return nil }

        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Rows are stored top first. Scan each from the right, stopping once we
        // pass the running max; a row with any ink at all also bounds top/bottom.
        var maxX = -1
        var minY = -1
        var maxY = -1
        for y in 0..<h {
            let row = y * bytesPerRow
            var x = w - 1
            var rowHasInk = false
            while x >= 0 {
                if data[row + x * 4 + 3] > 10 {
                    rowHasInk = true
                    if x > maxX { maxX = x }
                    break
                }
                x -= 1
            }
            if rowHasInk {
                if minY < 0 { minY = y }
                maxY = y
            }
        }
        guard maxX >= 0 else { return nil }

        // +1: pixel `n` spans [n, n+1). Convert to points.
        let sx = sizeInPoints.width / CGFloat(w)
        let sy = sizeInPoints.height / CGFloat(h)
        return ((CGFloat(maxX) + 1) * sx, CGFloat(minY) * sy, (CGFloat(maxY) + 1) * sy)
    }
}
