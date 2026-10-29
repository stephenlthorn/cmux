import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileTerminalTabStripTests {
    private let build = MobileTerminalPreview(id: "build", name: "build")
    private let tests = MobileTerminalPreview(id: "tests", name: "tests")
    private let shell = MobileTerminalPreview(id: "shell", name: "zsh")

    @Test func aWorkspaceWithOneTabShowsNoStrip() {
        let strip = MobileTerminalTabStrip(terminals: [build], selectedID: "build")
        #expect(strip.tabs.isEmpty)
    }

    @Test func everyTabShowsInWorkspaceOrderWithTheSelectedOneMarked() {
        let strip = MobileTerminalTabStrip(terminals: [build, tests, shell], selectedID: "tests")
        #expect(strip.tabs.map(\.name) == ["build", "tests", "zsh"])
        #expect(strip.tabs.map(\.isSelected) == [false, true, false])
    }

    @Test func aSelectionThatIsGoneMarksTheFirstTab() {
        let strip = MobileTerminalTabStrip(terminals: [build, tests], selectedID: "closed")
        #expect(strip.tabs.map(\.isSelected) == [true, false])
    }
}
