import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxTerminalSizing
import Foundation
import Testing
@testable import CmuxMobileShell

// A Mac that supports shared sizing publishes a size state for every terminal
// it sizes itself. A terminal it does not size (a mirrored tmux tab) has its
// grid set by tmux, and the Mac shrinking it to the phone only crops tmux's
// output. The phone shows such a terminal at the Mac's grid, scaled to fit.

private let surfaceID = "live-terminal"
private let sharedSizing = "terminal.shared_sizing.v1"
private let baseCapabilities = ["events.v1", "terminal.bytes.v1", "terminal.render_grid.v1", "terminal.replay.v1"]

private func sizeStateObject() throws -> [String: Any] {
    let state = TerminalSizingState(
        generation: 1, cols: 80, rows: 48, reason: .smallest,
        owners: [], policy: TerminalSizingPolicy(), participants: []
    )
    let data = try JSONEncoder().encode(state)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor
private func attach(router: LivenessHostRouter) async throws -> MobileShellComposite {
    let store = try await makeConnectedStore(router: router, box: TransportBox(), clock: TestClock())
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    return store
}

private func sentReports(_ router: LivenessHostRouter) async -> Int {
    await router.requests(for: "mobile.terminal.viewport").filter { !$0.clearsViewport }.count
}

@MainActor
@Test func aMirroredTerminalIsShownAtTheMacGridWithoutResizingIt() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(baseCapabilities + [sharedSizing])
    await router.enqueueReplayGrid(text: "tmux", columns: 152, rows: 45)
    let store = try await attach(router: router)

    let granted = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 60, rows: 40)

    #expect(granted?.columns == 152)
    #expect(granted?.rows == 45)
    #expect(await sentReports(router) == 0, "the phone must not shrink a terminal the Mac does not size")
}

@MainActor
@Test func aTerminalTheMacSizesStillGetsThePhonesViewport() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(baseCapabilities + [sharedSizing])
    await router.enqueueReplayGrid(text: "zsh", columns: 152, rows: 45, sizeState: try sizeStateObject())
    await router.enqueueReplayTexts(["resized"])
    let store = try await attach(router: router)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 60, rows: 40)

    #expect(await sentReports(router) >= 1)
}

@MainActor
@Test func aMacWithoutSharedSizingStillGetsThePhonesViewport() async throws {
    let router = LivenessHostRouter()
    await router.enqueueReplayGrid(text: "zsh", columns: 152, rows: 45)
    await router.enqueueReplayTexts(["resized"])
    let store = try await attach(router: router)

    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 60, rows: 40)

    #expect(await sentReports(router) >= 1)
}

@MainActor
@Test func aViewportSentBeforeTheTerminalWasKnownToBeMirroredIsWithdrawn() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(baseCapabilities + [sharedSizing])
    await router.enqueueReplayTexts(["cold-replay", "resized"])
    let store = try await attach(router: router)
    _ = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 60, rows: 40)
    let reportsBefore = await sentReports(router)
    let clearsBefore = await router.requests(for: "mobile.terminal.viewport").filter(\.clearsViewport).count

    await router.enqueueReplayGrid(text: "tmux", columns: 60, rows: 40)
    await router.enqueueReplayGrid(text: "tmux", columns: 152, rows: 45)
    let replays = await router.count(of: "mobile.terminal.replay")
    store.requestColdAttachTerminalReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replays + 1)
    var clears = clearsBefore
    for _ in 0..<100 where clears == clearsBefore {
        try await Task.sleep(nanoseconds: 50_000_000)
        clears = await router.requests(for: "mobile.terminal.viewport").filter(\.clearsViewport).count
    }
    #expect(clears == clearsBefore + 1, "the phone withdraws the size it asked for")
    let granted = await store.updateTerminalViewport(surfaceID: surfaceID, columns: 60, rows: 30)
    #expect(await sentReports(router) == reportsBefore, "and asks for no new size")
    #expect(granted?.rows != 30)
}
