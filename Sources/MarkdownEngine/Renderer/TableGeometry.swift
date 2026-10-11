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

    init(columnLeft: [CGFloat], rowTop: [CGFloat], borderWidth: CGFloat, imageSize: CGSize) {
        self.columnLeft = columnLeft
        self.rowTop = rowTop
        self.borderWidth = borderWidth
        self.imageSize = imageSize
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
}

private var tableGeometryKey: UInt8 = 0

extension NSImage {
    /// Layout of the table this image was rendered from; nil for any other image.
    var tableGeometry: TableGeometry? {
        get { objc_getAssociatedObject(self, &tableGeometryKey) as? TableGeometry }
        set { objc_setAssociatedObject(self, &tableGeometryKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
