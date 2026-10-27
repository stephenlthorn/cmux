import CoreGraphics
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalRowCapacityFit")
struct TerminalRowCapacityFitTests {
    @Test("phone overlay transitions preserve a previously rendered full width")
    func phoneOverlayTransitionPreservesFullWidth() {
        let selected = TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: true
        ).width

        #expect(selected == 1_032)
    }

    @Test("split panes report their current drawable width")
    func splitPaneUsesCurrentWidth() {
        let selected = TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: false
        ).width

        #expect(selected == 642)
    }

    @Test("invalid report widths are rejected")
    func invalidReportWidthsAreRejected() {
        #expect(TerminalColumnReportWidthSelection(
            currentWidth: 0,
            widestRenderedWidth: 1_032,
            preservesWidestRenderedWidth: true
        ).width == nil)
        #expect(TerminalColumnReportWidthSelection(
            currentWidth: 642,
            widestRenderedWidth: 0,
            preservesWidestRenderedWidth: true
        ).width == nil)
    }

    @Test("column capacity normalizes stretched live cell width back to the base font")
    func columnCapacityNormalizesLiveFontToBaseFont() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 36,
            containerPixelWidth: 1_206,
            cellPixelWidth: 18,
            liveFontSize: 24
        ))

        #expect(fit.capacityColumns(atBaseFontSize: 12) == 134)
    }

    @Test("column capacity is the measured grid when live font equals base font")
    func columnCapacityIdentityAtBaseFont() throws {
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 9,
            liveFontSize: 12
        ))

        #expect(fit.capacityColumns(atBaseFontSize: 12) == 134)
    }

    @Test("a container of exactly n cells reports n, not n - 1")
    func exactCellCountIsNotOneShort() throws {
        // 1320 px over 56 columns and 1900 px over 60 rows at 12.5 pt: the
        // container divided by (container / n) floors to n - 1.
        let fit = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1_900,
            cellPixelHeight: 1_900 / 60,
            containerPixelWidth: 1_320,
            cellPixelWidth: 1_320 / 56,
            liveFontSize: 12.5
        ))

        #expect(fit.capacityColumns(atBaseFontSize: 12.5) == 56)
        #expect(fit.capacityRows(atBaseFontSize: 12.5) == 60)
    }

    @Test("every whole-cell container reports its exact count at the base font")
    func everyWholeCellContainerIsExact() {
        let fonts: [(live: Float32, base: Float32)] = [(10, 10), (12.5, 12.5), (14, 14), (25, 12.5), (13, 10)]
        var misses: [String] = []
        for pixels in stride(from: 600, through: 2_400, by: 7) {
            for count in 20...120 {
                for font in fonts {
                    // The cell measured at the live font, for a container
                    // that holds exactly `count` cells at the base font.
                    let cell = CGFloat(pixels) / CGFloat(count) * CGFloat(font.live) / CGFloat(font.base)
                    guard let fit = TerminalRowCapacityFit(
                        containerPixelHeight: CGFloat(pixels),
                        cellPixelHeight: cell,
                        containerPixelWidth: CGFloat(pixels),
                        cellPixelWidth: cell,
                        liveFontSize: font.live
                    ) else {
                        misses.append("\(pixels)/\(count) nil")
                        continue
                    }
                    let columns = fit.capacityColumns(atBaseFontSize: font.base)
                    let rows = fit.capacityRows(atBaseFontSize: font.base)
                    if columns != count || rows != count {
                        misses.append("\(pixels)px/\(count)@\(font.live)->\(font.base): \(String(describing: columns))x\(String(describing: rows))")
                    }
                }
            }
        }
        #expect(misses.isEmpty, "\(misses.count) misses, first: \(misses.prefix(4))")
    }

    @Test("degenerate horizontal inputs return nil")
    func degenerateHorizontalInputsReturnNil() {
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 0,
            cellPixelWidth: 9,
            liveFontSize: 12
        )?.capacityColumns(atBaseFontSize: 12) == nil)
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 0,
            liveFontSize: 12
        )?.capacityColumns(atBaseFontSize: 12) == nil)
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1_200,
            cellPixelHeight: 18,
            containerPixelWidth: 1_206,
            cellPixelWidth: 9,
            liveFontSize: 12
        )?.capacityColumns(atBaseFontSize: 0) == nil)
    }
}
