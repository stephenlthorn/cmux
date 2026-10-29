@testable import CmuxNextApp
import CmuxNextSidebar
import Foundation
import Testing

extension ClassicUpgradeSimulationTests {
    /// A busy Mac at launch: the sidebar document's first load is still on the way while the migration makes the
    /// first window's workspaces. Once it lands they show in classic's order, each once, not newest first (the
    /// daemon's slot for a new workspace, where they stayed when their placements went to the older order).
    @Test func workspacesMadeBeforeTheSidebarDocumentLoadsKeepClassicsOrder() async throws {
        let profile = ClassicUpgradeProfile.multiWindow
        let mac = try ClassicUpgradeSimulator.Mac()
        try mac.save(profile)
        let before = try mac.classicDigest()
        let held = HeldSidebarDocumentLoad()
        let sim = try ClassicUpgradeSimulator(mac: mac, sidebarDocument: held.wrap)
        let launch = await sim.launch()
        #expect(launch.outcome?.decision == .firstRun, "\(String(describing: launch.outcome))")
        // The whole run went while the document had not loaded.
        #expect(held.asked && !held.isReleased, "the first sidebar.get was not held: asked \(held.asked)")
        held.release()
        // The document shows a hop after its load (a ceiling, not a budget).
        let clock = ContinuousClock()
        let shows = clock.now + .seconds(60)
        while SidebarDocStore.current?.firstShowSettled == false, clock.now < shows { try? await Task.sleep(for: .milliseconds(20)) }
        await sim.settle()
        try sim.verify(profile, classicBefore: before)
        await sim.shutdown()
    }
}

/// The home daemon's sidebar document with its first `sidebar.get` held back until ``release()``.
@MainActor
final class HeldSidebarDocumentLoad: SidebarDocRemote {
    private var real: (any SidebarDocRemote)?
    private var gate: CheckedContinuation<Void, Never>?
    /// The first `sidebar.get` was asked for.
    private(set) var asked = false
    private(set) var isReleased = false

    /// For `AppEnvironment.sidebarDocRemote`: this wraps the app's remote.
    var wrap: @MainActor @Sendable (any SidebarDocRemote) -> any SidebarDocRemote {
        { [self] real in
            self.real = real
            return self
        }
    }

    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }

    private func remote() throws -> any SidebarDocRemote {
        guard let real else { throw CancellationError() }
        return real
    }

    var isAvailable: Bool { real?.isAvailable ?? false }

    func get() async throws -> Data {
        if !asked {
            asked = true
            if !isReleased { await withCheckedContinuation { gate = $0 } }
        }
        return try await remote().get()
    }

    func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply {
        try await remote().move(items, to: target, key: key)
    }

    func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await remote().pin(items, key: key) }
    func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await remote().unpin(items, key: key) }

    func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply {
        try await remote().adopt(refs, key: key)
    }

    func apply(ops: Data, key: String) async throws -> SidebarDocReply { try await remote().apply(ops: ops, key: key) }
}
