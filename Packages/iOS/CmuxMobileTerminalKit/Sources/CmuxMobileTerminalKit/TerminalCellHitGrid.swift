public import CoreGraphics

/// Maps a touch on the terminal surface to the grid cell under it.
///
/// libghostty lays the grid out from its real cell size, starting after the
/// window padding; whatever the surface has left past the last column or row
/// stays unused. A cell size of the surface's pixel extent divided by the cell
/// count spreads that leftover over every cell, so the error grows toward the
/// far edges: on a 72x60 grid of 18x35 px cells a tap in the lower rows landed
/// one row up and one in the right columns one column left. The cell goes to
/// the Mac's click, file-path hit testing and local mouse clicks.
public struct TerminalCellHitGrid: Equatable, Sendable {
    /// One cell in device pixels (libghostty's `cell_width_px` and
    /// `cell_height_px`).
    public var cellPixelSize: CGSize
    /// The window padding before the first column and row, in points.
    public var padding: CGSize

    /// Creates a hit grid.
    /// - Parameters:
    ///   - cellPixelSize: One cell in device pixels.
    ///   - padding: The window padding before the first column and row, in points.
    public init(cellPixelSize: CGSize, padding: CGSize = .zero) {
        self.cellPixelSize = cellPixelSize
        self.padding = padding
    }

    /// The cell under a point.
    ///
    /// - Parameters:
    ///   - point: The touch location in the surface's coordinate space.
    ///   - gridOrigin: The top-left corner of the displayed grid box.
    ///   - scale: Device pixels per point.
    ///   - displayScale: The scale a grid displayed scaled to fit is drawn
    ///     at; 1 otherwise.
    /// - Returns: The zero-based column and row, never negative.
    public func cell(
        at point: CGPoint,
        gridOrigin: CGPoint,
        scale: CGFloat,
        displayScale: CGFloat
    ) -> (col: Int, row: Int) {
        let scale = max(scale, 1)
        let displayScale = displayScale > 0 ? displayScale : 1
        // Back to the grid's own points, then past the padding.
        let x = (point.x - gridOrigin.x) / displayScale - padding.width
        let y = (point.y - gridOrigin.y) / displayScale - padding.height
        let cellW = max(cellPixelSize.width / scale, 1)
        let cellH = max(cellPixelSize.height / scale, 1)
        let col = max(0, Int((x / cellW).rounded(.down)))
        let row = max(0, Int((y / cellH).rounded(.down)))
        return (col, row)
    }
}
