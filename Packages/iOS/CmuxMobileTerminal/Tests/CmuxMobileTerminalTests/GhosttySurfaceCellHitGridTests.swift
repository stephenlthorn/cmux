#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import GhosttyKit
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Taps map to a grid cell for the Mac's click, file-path hit testing and
/// local mouse clicks. The cell size they used was the surface's pixel
/// extent divided by the cell count, which spreads the padding and the
/// leftover past the last cell over every cell.
@MainActor
@Suite("Surface tap cell mapping", .serialized)
struct GhosttySurfaceCellHitGridTests {
    private final class Delegate: NSObject, GhosttySurfaceViewDelegate {
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceInput data: Data
        ) {}

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didResize size: TerminalGridSize,
            reportID: UInt64
        ) {}
    }

    @Test("taps map with libghostty's own cell size")
    func tapsUseLibghosttyCellSize() async throws {
        let delegate = Delegate()
        let view = GhosttySurfaceView(runtime: try GhosttyRuntime.shared(), delegate: delegate, fontSize: 10)
        view.autoFocusOnWindowAttach = false
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.frame = window.bounds
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        defer {
            view.prepareForDismantle()
            view.removeFromSuperview()
            window.isHidden = true
        }

        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while view.cellHitGrid.cellPixelSize == .zero, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        let surface = try #require(view.surface)
        let measured = ghostty_surface_size(surface)

        #expect(measured.cell_width_px > 0 && measured.cell_height_px > 0)
        #expect(view.cellHitGrid.cellPixelSize == CGSize(
            width: CGFloat(measured.cell_width_px),
            height: CGFloat(measured.cell_height_px)
        ))
    }
}
#endif
