import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
struct MobileWorkspaceSnapshotStoreTests {
    @Test
    func snapshotsRoundTripWithoutAuthorityOrTerminalOutput() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests.\(UUID().uuidString)")!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        var workspace = MobileWorkspacePreview(
            id: "workspace-a",
            macDeviceID: "mac-a",
            name: "Mario",
            terminals: [MobileTerminalPreview(id: "terminal-a", name: "codex")]
        )
        workspace.remoteWorkspaceID = "remote-workspace-a"
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            displayName: "Build Mac",
            workspaces: [workspace],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true,
            actionCapabilities: MobileWorkspaceActionCapabilities(
                supportsWorkspaceActions: true,
                supportsWorkspaceMetadata: true
            )
        )

        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let restored = store.load(userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(restored?.workspaces == [workspace])
        #expect(restored?.workspaces.first?.remoteWorkspaceID == "remote-workspace-a")
        #expect(restored?.status == .reconnecting)
        #expect(restored?.workspaceSnapshotIsAuthoritative == false)
        #expect(restored?.actionCapabilities == MobileWorkspaceActionCapabilities.none)
        #expect(store.load(userID: "user-b", teamID: "team-a", pairing: pairing) == nil)
        #expect(store.load(userID: "user-a", teamID: "team-b", pairing: pairing) == nil)
    }

    @Test
    func loadAllReturnsOnlyTheCurrentAccountAndTeamScope() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let nightly = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let stable = MacPairingKey(macDeviceID: "mac-a", instanceTag: "stable")
        let other = MacPairingKey(macDeviceID: "mac-b", instanceTag: "nightly")

        func state(for pairing: MacPairingKey) -> MacWorkspaceState {
            MacWorkspaceState(
                macDeviceID: pairing.canonicalMacDeviceID,
                instanceTag: pairing.normalizedInstanceTag,
                workspaces: [MobileWorkspacePreview(
                    id: .init(rawValue: pairing.pairingID + "-workspace"),
                    macDeviceID: pairing.canonicalMacDeviceID,
                    name: pairing.pairingID,
                    terminals: []
                )],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            )
        }

        await store.save(state: state(for: nightly), userID: "user-a", teamID: "team-a", pairing: nightly)
        await store.save(state: state(for: stable), userID: "user-a", teamID: "team-a", pairing: stable)
        await store.save(state: state(for: other), userID: "user-b", teamID: "team-a", pairing: other)

        let loaded = await store.loadAll(userID: "user-a", teamID: "team-a")
        #expect(Set(loaded.map(\.0)) == [nightly, stable])
        #expect(loaded.allSatisfy { $0.1.status == .reconnecting })
        #expect(await store.loadAll(userID: "user-a", teamID: "team-b").isEmpty)
    }

    @Test
    func authoritativeEmptyListRemovesThePreviousPreview() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let workspace = MobileWorkspacePreview(
            id: "workspace-a",
            macDeviceID: "mac-a",
            name: "Mario",
            terminals: []
        )
        let connected = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [workspace],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        let empty = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )

        await store.save(state: connected, userID: "user-a", teamID: "team-a", pairing: pairing)
        await store.save(state: empty, userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(store.load(userID: "user-a", teamID: "team-a", pairing: pairing) == nil)
        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
    }

    @Test
    func authoritativeEmptyGroupsRemainAuthoritativeAfterRestore() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            workspaceGroupsAreAuthoritative: true,
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )

        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)

        #expect(store.load(userID: "user-a", teamID: "team-a", pairing: pairing)?.workspaceGroupsAreAuthoritative == true)
    }

    @Test
    func malformedSnapshotsAreRemovedWhenTheStoreIsTouched() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let storageKey = defaults.dictionaryRepresentation().keys.first { $0.contains("cmux.mobile.v2.workspace-snapshot.") }!
        defaults.set(Data("not-json".utf8), forKey: storageKey)

        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
        #expect(defaults.data(forKey: storageKey) == nil)
    }

    @Test
    func expiredSnapshotsAreRemovedWhenTheStoreIsTouched() async {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let store = MobileWorkspaceSnapshotStore(defaults: defaults)
        let pairing = MacPairingKey(macDeviceID: "mac-a", instanceTag: "nightly")
        let state = MacWorkspaceState(
            macDeviceID: "mac-a",
            instanceTag: "nightly",
            workspaces: [MobileWorkspacePreview(id: "workspace-a", macDeviceID: "mac-a", name: "Mario", terminals: [])],
            status: .connected,
            workspaceSnapshotIsAuthoritative: true
        )
        await store.save(state: state, userID: "user-a", teamID: "team-a", pairing: pairing)
        let storageKey = defaults.dictionaryRepresentation().keys.first { $0.contains("cmux.mobile.v2.workspace-snapshot.") }!
        var object = try! JSONSerialization.jsonObject(with: defaults.data(forKey: storageKey)!) as! [String: Any]
        object["savedAt"] = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        defaults.set(try! JSONSerialization.data(withJSONObject: object), forKey: storageKey)

        #expect(await store.loadAll(userID: "user-a", teamID: "team-a").isEmpty)
        #expect(defaults.data(forKey: storageKey) == nil)
    }

    @Test
    func pairedMacReloadKeepsRetainedRowsOfAnUnavailableMac() async throws {
        let defaults = UserDefaults(suiteName: "cmux.snapshot-tests." + UUID().uuidString)!
        let snapshotStore = MobileWorkspaceSnapshotStore(defaults: defaults)
        func workspace(_ id: String) -> MobileWorkspacePreview {
            MobileWorkspacePreview(
                id: .init(rawValue: id),
                macDeviceID: "mac-b",
                name: id,
                terminals: []
            )
        }
        // An old snapshot from when mac-b was last the foreground Mac.
        await snapshotStore.save(
            state: MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [workspace("workspace-a")],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            ),
            userID: "user-1",
            teamID: "team-a",
            pairing: MacPairingKey(macDeviceID: "mac-b", instanceTag: nil)
        )
        let route = try CmxAttachRoute(
            id: "manual",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.82.214.113", port: 50922)
        )
        let pairedStore = DelayedTeamPairedMacStore(
            recordsByTeam: [
                "team-a": [
                    MobilePairedMac(
                        macDeviceID: "mac-b",
                        displayName: "Laptop Mac",
                        routes: [route],
                        createdAt: Date(timeIntervalSince1970: 1),
                        lastSeenAt: Date(timeIntervalSince1970: 20),
                        isActive: false,
                        stackUserID: "user-1",
                        teamID: "team-a"
                    ),
                ],
            ],
            blockedTeams: []
        )
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: pairedStore,
            identityProvider: StaticIdentityProvider(userID: "user-1"),
            teamIDProvider: { "team-a" },
            workspaceSnapshotStore: snapshotStore
        )
        await store.loadPairedMacs()
        let macB = MacPairingKey(pairingID: "mac-b")
        #expect(
            store.workspacesByMac[macB]?.workspaces.map(\.id.rawValue) == ["workspace-a"],
            "cold launch must still hydrate a Mac with no rows from its snapshot"
        )

        // Newer rows from a live read-only subscription (workspace-a has
        // since closed), then the Mac sleeps and its rows are retained.
        store.setWorkspaceStatesForTesting([
            "mac-b": MacWorkspaceState(
                macDeviceID: "mac-b",
                workspaces: [workspace("workspace-b"), workspace("workspace-c")],
                status: .connected,
                workspaceSnapshotIsAuthoritative: true
            ),
        ], foregroundMacDeviceID: nil)
        store.markSecondaryMacUnavailableForTesting("mac-b")

        // The Computers screen re-reads paired Macs every 10 seconds.
        await store.loadPairedMacs(forceRefresh: true)

        let retained = try #require(store.workspacesByMac[macB])
        #expect(
            retained.workspaces.map(\.id.rawValue) == ["workspace-b", "workspace-c"],
            "a paired-Mac reload must not replace retained rows with an older snapshot"
        )
        #expect(retained.status == .unavailable)
    }
}
