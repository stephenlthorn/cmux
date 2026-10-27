import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

/// iPhone 17 Pro Max at 3x under a 72x60 grid: libghostty's cells are 18x35
/// px after a 2 pt (6 px) left padding, and the 1320x2124 px surface leaves
/// 12 px past the last column and 24 px below the last row. Spreading that
/// over the cells (18.33x35.4 px) put taps in the lower rows one row up and
/// in the right columns one column left.
@Suite("TerminalCellHitGrid")
struct TerminalCellHitGridTests {
    private let scale: CGFloat = 3
    private let origin = CGPoint(x: 0, y: 120)
    private let grid = TerminalCellHitGrid(
        cellPixelSize: CGSize(width: 18, height: 35),
        padding: CGSize(width: 2, height: 0)
    )

    /// A point inside one cell, `fraction` of the way across it on both axes.
    private func point(
        col: Int,
        row: Int,
        fraction: CGFloat = 0.5,
        displayScale: CGFloat = 1
    ) -> CGPoint {
        CGPoint(
            x: origin.x + (6 + (CGFloat(col) + fraction) * 18) / scale * displayScale,
            y: origin.y + (CGFloat(row) + fraction) * 35 / scale * displayScale
        )
    }

    private func cell(at point: CGPoint, displayScale: CGFloat = 1) -> (col: Int, row: Int) {
        grid.cell(at: point, gridOrigin: origin, scale: scale, displayScale: displayScale)
    }

    @Test("the centre of the last row maps to that row")
    func lastRowCentre() {
        #expect(cell(at: point(col: 0, row: 59)).row == 59)
    }

    @Test("the centre of the last column maps to that column")
    func lastColumnCentre() {
        #expect(cell(at: point(col: 71, row: 0)).col == 71)
    }

    @Test("every cell's centre and inner edges map to that cell", arguments: [0.05, 0.5, 0.95] as [CGFloat])
    func everyCellMapsToItself(fraction: CGFloat) {
        var misses: [String] = []
        for row in 0..<60 {
            for col in 0..<72 {
                let hit = cell(at: point(col: col, row: row, fraction: fraction))
                if hit.col != col || hit.row != row {
                    misses.append("(\(col),\(row))->(\(hit.col),\(hit.row))")
                }
            }
        }
        #expect(misses.isEmpty, "\(misses.count) misses, first: \(misses.prefix(4))")
    }

    @Test("a grid displayed scaled to fit maps through its display scale")
    func scaledToFitGrid() {
        let hit = cell(at: point(col: 71, row: 59, fraction: 0.9, displayScale: 0.5), displayScale: 0.5)
        #expect(hit.col == 71)
        #expect(hit.row == 59)
    }

    @Test("a tap in the padding or outside the grid's top-left clamps to the first cell")
    func paddingClampsToFirstCell() {
        for tap in [
            origin,
            CGPoint(x: origin.x + 1.5, y: origin.y + 1),
            CGPoint(x: origin.x - 10, y: origin.y - 10),
        ] {
            let hit = cell(at: tap)
            #expect(hit.col == 0 && hit.row == 0, "\(tap) -> (\(hit.col),\(hit.row))")
        }
    }
}
