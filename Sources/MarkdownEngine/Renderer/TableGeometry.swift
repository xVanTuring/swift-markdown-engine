//
//  TableGeometry.swift
//  MarkdownEngine
//
//  Where each cell sits inside a rendered table image. Recorded when the table
//  is drawn and attached to the image itself, so a cached image carries its
//  own layout and a click can be mapped back to a cell.
//

import AppKit
import ObjectiveC

/// Cell boundaries of one rendered table, in the image's top-down coordinates.
final class TableGeometry {
    /// x of each column's left edge (just inside the border), plus the right edge of the last.
    let columnLeft: [CGFloat]
    /// y of each row's top edge (just inside the border), plus the bottom edge of the last.
    let rowTop: [CGFloat]
    let borderWidth: CGFloat
    let imageSize: CGSize
    /// The look it was drawn in: its cell padding is what the cell editor copies.
    let style: TableAppearance
    /// (fork: xVanTuring) A cell whose text the image leaves out: the one open
    /// in the in-place editor, which lies over it with no fill and shows the
    /// same text where it was. Part of the image (and of its cache key): the
    /// table is rendered again when the editor opens, moves or closes, so the
    /// views that show it get a new image, as on any other change.
    let hiddenCell: (row: Int, column: Int)?
    /// (fork: xVanTuring) The text of every cell that holds a link, laid out
    /// where the image draws it, so a click can be mapped to the link under it.
    let linkCells: [TableCellText]

    init(columnLeft: [CGFloat], rowTop: [CGFloat], borderWidth: CGFloat, imageSize: CGSize,
         style: TableAppearance = .grid, hiddenCell: (row: Int, column: Int)? = nil,
         linkCells: [TableCellText] = []) {
        self.columnLeft = columnLeft
        self.rowTop = rowTop
        self.borderWidth = borderWidth
        self.imageSize = imageSize
        self.style = style
        self.hiddenCell = hiddenCell
        self.linkCells = linkCells
    }

    /// (fork: xVanTuring) The link drawn under `point` (image coordinates), or
    /// nil when the point is not on a link's text. The cell open in the
    /// in-place editor has none: its text is the editor's.
    func link(at point: CGPoint) -> TableCellLink? {
        guard !linkCells.isEmpty, let cell = cell(at: point) else { return nil }
        if let hidden = hiddenCell, hidden.row == cell.row, hidden.column == cell.column { return nil }
        return linkCells.first { $0.row == cell.row && $0.column == cell.column }?.link(at: point)
    }

    var columnCount: Int { max(0, columnLeft.count - 1) }
    var rowCount: Int { max(0, rowTop.count - 1) }

    /// The cell's box, padding included, border excluded.
    func cellRect(row: Int, column: Int) -> CGRect? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return nil }
        return CGRect(
            x: columnLeft[column],
            y: rowTop[row],
            width: columnLeft[column + 1] - borderWidth - columnLeft[column],
            height: rowTop[row + 1] - borderWidth - rowTop[row]
        )
    }

    /// The cell under `point` (image coordinates). A click on a border line
    /// goes to the cell before it; outside the table returns nil.
    func cell(at point: CGPoint) -> (row: Int, column: Int)? {
        guard point.x >= 0, point.y >= 0, point.x <= imageSize.width, point.y <= imageSize.height,
              columnCount > 0, rowCount > 0 else { return nil }
        func index(of value: CGFloat, in edges: [CGFloat]) -> Int {
            var found = 0
            for i in 0..<(edges.count - 1) where value >= edges[i] { found = i }
            return found
        }
        return (index(of: point.y, in: rowTop), index(of: point.x, in: columnLeft))
    }

    /// The cell closest to `point` (image coordinates), even when it lies
    /// outside the table — a drag that leaves the table keeps selecting.
    func nearestCell(to point: CGPoint) -> (row: Int, column: Int)? {
        guard columnCount > 0, rowCount > 0 else { return nil }
        let clamped = CGPoint(
            x: min(max(point.x, 0), imageSize.width),
            y: min(max(point.y, 0), imageSize.height)
        )
        return cell(at: clamped)
    }
}

// MARK: - Links in cells (fork: xVanTuring)

/// What a link inside a table cell points at.
enum TableCellLink: Equatable {
    /// `[text](url)`: opened as a click on a link in body text opens it.
    case url(URL)
    /// `[[name]]`: handed to `onLinkClick`, as a click on a wiki link in body text.
    case wiki(String)
}

extension NSAttributedString.Key {
    /// `TableCellLink` — set on a cell's link text when the cell is formatted.
    /// Not `.link`: the cell is drawn into an image, and what is clickable is
    /// decided by `TableGeometry.link(at:)`, not by a text view.
    static let tableCellLink = NSAttributedString.Key("MarkdownTableCellLink")
}

/// One cell's text as the table image draws it: the formatted string (with its
/// alignment) and the rect it is drawn into, in the image's top-down coordinates.
final class TableCellText {
    let row: Int
    let column: Int
    let frame: CGRect
    let text: NSAttributedString

    init(row: Int, column: Int, frame: CGRect, text: NSAttributedString) {
        self.row = row
        self.column = column
        self.frame = frame
        self.text = text
    }

    /// Laid out the way `NSAttributedString.draw(with:options:)` lays out the
    /// cell: no line fragment padding, no font leading (string drawing adds it
    /// only with `.usesFontLeading`), wrapped to the cell's width.
    /// The storage owns its layout manager, not the other way round: kept
    /// here, or the layout manager is left with no text.
    private lazy var storage = NSTextStorage(attributedString: text)
    private lazy var layout: (NSLayoutManager, NSTextContainer) = {
        let storage = self.storage
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return (layoutManager, container)
    }()

    /// The link whose text is under `point` (image coordinates). Only the
    /// glyphs count: the space beside a short line and the cell's padding are
    /// not part of the link, so a click there still opens the cell.
    func link(at point: CGPoint) -> TableCellLink? {
        let (layoutManager, container) = layout
        guard text.length > 0, layoutManager.numberOfGlyphs > 0 else { return nil }
        let p = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let glyph = layoutManager.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -1, dy: 0).contains(p) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        return text.attribute(.tableCellLink, at: index, effectiveRange: nil) as? TableCellLink
    }

    /// Rects of the link text, in image coordinates (used by the tests).
    func linkRects() -> [CGRect] {
        let (layoutManager, container) = layout
        var rects: [CGRect] = []
        text.enumerateAttribute(.tableCellLink, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                rects.append(rect.offsetBy(dx: self.frame.minX, dy: self.frame.minY))
            }
        }
        return rects
    }
}

private var tableGeometryKey: UInt8 = 0

extension NSImage {
    /// Layout of the table this image was rendered from; nil for any other image.
    var tableGeometry: TableGeometry? {
        get { objc_getAssociatedObject(self, &tableGeometryKey) as? TableGeometry }
        set { objc_setAssociatedObject(self, &tableGeometryKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
