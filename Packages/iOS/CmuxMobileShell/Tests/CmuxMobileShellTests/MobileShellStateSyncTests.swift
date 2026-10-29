import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing

@testable import CmuxMobileShell

// Behavior tests for mobile state sync v2 (docs/mobile-state-sync-v2.md):
// negotiation via `mobile.sync.fetch`, delta application from
// `mobile.sync.delta` events, legacy fallback on `method_not_found`, and the
// suppression of full-list refetches while v2 is active. Uses the scripted
// liveness host router/transport so events flow through the production
// subscribe/consume path.

private func workspaceRecord(
    id: String,
    title: String,
    customDescription: String? = nil,
    customDescriptionIsTruncated: Bool = false,
    customColorHex: String? = nil,
    sortIndex: Int,
    surfaces: [WorkspaceSyncRecord.Surface]? = nil
) -> WorkspaceSyncRecord {
    WorkspaceSyncRecord(
        id: id,
        windowID: "win-1",
        title: title,
        customDescription: customDescription,
        customDescriptionIsTruncated: customDescriptionIsTruncated,
        customColorHex: customColorHex,
        currentDirectory: nil,
        isSelected: false,
        isPinned: false,
        groupID: nil,
        preview: nil,
        previewAt: nil,
        lastActivityAt: 1.0,
        hasUnread: false,
        sortIndex: sortIndex,
        terminals: [],
        surfaces: surfaces
    )
}

private func syncSnapshotResultData(
    epoch: String,
    rev: UInt64,
    records: [WorkspaceSyncRecord]
) throws -> Data {
    let response = MobileSyncFetchResponse(
        epoch: epoch,
        workspaces: MobileSyncCollectionPayload(
            mode: .snapshot,
            rev: rev,
            fromRev: nil,
            records: records,
            removedIDs: []
        ),
        groups: MobileSyncCollectionPayload(
            mode: .snapshot,
            rev: rev,
            fromRev: nil,
            records: [],
            removedIDs: []
        )
    )
    return try JSONEncoder().encode(response)
}

private func syncDeltaEventFrame(
    epoch: String,
    fromRev: UInt64,
    toRev: UInt64,
    records: [WorkspaceSyncRecord],
    removedIDs: [String] = []
) throws -> Data {
    let event = MobileSyncDeltaEvent(
        epoch: epoch,
        collection: .workspaces,
        fromRev: fromRev,
        toRev: toRev,
        records: records,
        removedIDs: removedIDs
    )
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "mobile.sync.delta",
        "payload": try MobileSyncFrameCoder().jsonObject(from: event),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

private func workspaceUpdatedEventFrame() throws -> Data {
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "workspace.updated",
        "payload": [String: Any](),
    ]
    return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
}

private let workspaceRowActionCapabilities = [
    "events.v1",
    "terminal.render_grid.v1",
    "terminal.replay.v1",
    "workspace.actions.v1",
    "workspace.metadata.v1",
    "workspace.read_state.v1",
    "workspace.close.v1",
]

/// `makeConnectedStore`, but recording app diagnostics into `diagnosticLog`.
@MainActor
private func makeConnectedStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    diagnosticLog: DiagnosticLog
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        diagnosticLog: diagnosticLog
    )
    store.signIn()
    let connected = await store.connectPairingURL(
        try attachURL(for: try makeTicket(clock: clock))
    )
    #expect(connected, "scripted connect must succeed")
    return store
}

@MainActor
struct MobileShellStateSyncTests {
    @Test func negotiationAppliesSnapshotAndSuppressesLegacyRefetch() async throws {
        let firstWorkspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.setCapabilities(workspaceRowActionCapabilities)
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [
                    workspaceRecord(
                        id: firstWorkspaceID,
                        title: "synced-alpha",
                        customDescription: "Release validation",
                        customDescriptionIsTruncated: true,
                        customColorHex: "#1565C0",
                        sortIndex: 0,
                        surfaces: [.init(
                            surfaceID: "surface-alpha",
                            kind: "future.canvas",
                            title: "Canvas",
                            filePath: "/tmp/canvas"
                        )]
                    ),
                    workspaceRecord(id: UUID().uuidString, title: "synced-beta", sortIndex: 1),
                ]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let negotiated = try await pollUntil { store.stateSyncActive }
        #expect(negotiated, "v2 negotiation must complete against a scripted sync host")
        let projected = try await pollUntil {
            store.workspaces.map(\.name).contains("synced-alpha")
        }
        #expect(projected, "snapshot projection must reach the published workspace list")
        let customizedWorkspace = try #require(
            store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == firstWorkspaceID })
        )
        #expect(customizedWorkspace.customDescription == "Release validation")
        #expect(customizedWorkspace.customDescriptionIsTruncated)
        #expect(customizedWorkspace.customColorHex == "#1565C0")
        #expect(customizedWorkspace.actionCapabilities.supportsWorkspaceActions)
        #expect(customizedWorkspace.actionCapabilities.supportsWorkspaceMetadata)
        #expect(customizedWorkspace.actionCapabilities.supportsReadStateActions)
        #expect(customizedWorkspace.actionCapabilities.supportsCloseActions)
        let projectedSurface = try #require(customizedWorkspace.surfaces.first)
        #expect(projectedSurface.kind == .other("future.canvas"))
        #expect(projectedSurface.filePath == "/tmp/canvas")

        // A workspace.updated push must no longer trigger the legacy full-list
        // refetch while v2 owns the list.
        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let legacyEventGenerationBefore =
            store.workspaceListEventGeneration
        let transport = try #require(box.get())
        await transport.deliver(try workspaceUpdatedEventFrame())
        // Deliver a delta behind it; its application proves the updated event
        // was consumed first (same stream, in order).
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 3,
            toRev: 4,
            records: [
                workspaceRecord(
                    id: firstWorkspaceID,
                    title: "synced-alpha",
                    customDescription: "Ready for launch",
                    customColorHex: "#E91E63",
                    sortIndex: 0
                ),
                workspaceRecord(id: UUID().uuidString, title: "synced-gamma", sortIndex: 2),
            ]
        ))
        let deltaApplied = try await pollUntil {
            let updatedWorkspace = store.workspaces.first {
                $0.rpcWorkspaceID.rawValue == firstWorkspaceID
            }
            return store.workspaces.map(\.name).contains("synced-gamma")
                && updatedWorkspace?.customDescription == "Ready for launch"
                && updatedWorkspace?.customColorHex == "#E91E63"
        }
        #expect(deltaApplied, "contiguous delta must update workspace metadata and extend the mirrored list")
        let updatedWorkspace = try #require(
            store.workspaces.first(where: { $0.rpcWorkspaceID.rawValue == firstWorkspaceID })
        )
        #expect(updatedWorkspace.customDescription == "Ready for launch")
        #expect(updatedWorkspace.customColorHex == "#E91E63")
        let listCallsAfter = await router.count(of: "mobile.workspace.list")
        #expect(
            listCallsAfter == listCallsBefore,
            "workspace.updated must not schedule a full-list refetch while state sync is active"
        )
        #expect(
            store.workspaceListEventGeneration
                == legacyEventGenerationBefore,
            "state-sync events must not impersonate pending legacy refresh work"
        )
    }

    @Test func gappedDeltaTriggersCursorRepairFetch() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        // The repair fetch answers with the missing span's outcome (snapshot
        // for simplicity; the mirror accepts either).
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 9,
                records: [workspaceRecord(id: UUID().uuidString, title: "repaired", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }

        let transport = try #require(box.get())
        // fromRev 7 > mirror rev 3: a gap the shell must repair with a fetch.
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 7,
            toRev: 8,
            records: [workspaceRecord(id: UUID().uuidString, title: "lost", sortIndex: 1)]
        ))
        let repaired = try await pollUntil {
            store.workspaces.map(\.name).contains("repaired")
        }
        #expect(repaired, "a gapped delta must trigger a cursor fetch that re-bases the mirror")
        let fetches = await router.count(of: "mobile.sync.fetch")
        #expect(fetches >= 2, "gap repair must issue a second mobile.sync.fetch")
    }

    @Test func removedWorkspaceEvictsSummaryBatchesMapsAndChipImmediately() async throws {
        let removedID = UUID().uuidString
        let keptID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [
                    workspaceRecord(id: removedID, title: "removed", sortIndex: 0),
                    workspaceRecord(id: keptID, title: "kept", sortIndex: 1),
                ]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }
        _ = try await pollUntil {
            store.foregroundWorkspaceChangesIDs.contains(removedID)
        }
        store.workspaceChangesSummaryFetchedAtByWorkspaceID = [
            removedID: clock.now,
            keptID: clock.now,
        ]
        store.workspaceChangesSummaryTrailingExpiryByWorkspaceID = [
            removedID: clock.now.addingTimeInterval(15),
            keptID: clock.now.addingTimeInterval(15),
        ]
        store.setWorkspaceChangeChipsByWorkspaceID([
            removedID: MobileWorkspaceChangesChip(
                filesChanged: 1,
                additions: 2,
                deletions: 3
            ),
            keptID: MobileWorkspaceChangesChip(
                filesChanged: 4,
                additions: 5,
                deletions: 6
            ),
        ])

        let transport = try #require(box.get())
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 3,
            toRev: 4,
            records: [],
            removedIDs: [removedID]
        ))
        _ = try await pollUntil {
            !store.foregroundWorkspaceChangesIDs.contains(removedID)
        }
        let batches = store.workspaceChangesSummaryFetchPolicy.batches(
            workspaceIDs: store.foregroundWorkspaceChangesIDs,
            fetchedAtByWorkspaceID: [:],
            now: clock.now,
            force: true
        )

        #expect(batches.flatMap { $0 } == [keptID])
        #expect(Set(store.workspaceChangesSummaryFetchedAtByWorkspaceID.keys) == [keptID])
        #expect(Set(store.workspaceChangesSummaryTrailingExpiryByWorkspaceID.keys) == [keptID])
        #expect(Set(store.workspaceChangeChipsByWorkspaceID.keys) == [keptID])
    }

    @Test func failedRepairFetchFallsBackToLegacyListAndReenablesRefetch() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        // The gap-repair fetch fails transiently; the shell must not strand
        // the mirror behind a suppressed refetch loop.
        await router.scriptSyncFetchTransientError()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        _ = try await pollUntil { store.stateSyncActive }

        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let transport = try #require(box.get())
        await transport.deliver(try syncDeltaEventFrame(
            epoch: "epoch-1",
            fromRev: 9,
            toRev: 10,
            records: [workspaceRecord(id: UUID().uuidString, title: "lost", sortIndex: 1)]
        ))
        let fellBack = try await pollUntil { !store.stateSyncActive }
        #expect(fellBack, "a failed repair fetch must drop back to legacy semantics")
        let reloaded = try await pollUntil {
            await router.count(of: "mobile.workspace.list") > listCallsBefore
        }
        #expect(reloaded, "the fallback must converge with one authoritative legacy reload")
    }

    @Test func replacingTheForegroundClientDemotesStateSyncAuthority() async throws {
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: UUID().uuidString, title: "synced-alpha", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let negotiated = try await pollUntil { store.stateSyncActive }
        #expect(negotiated)

        // Promoting/replacing the foreground client (secondary-to-foreground,
        // reconnect) must implicitly demote v2: the new client's events flow
        // through the legacy invalidation path until ITS negotiation grants
        // authority, so no window exists where the old Mac's authority
        // suppresses the new Mac's updates.
        try installFreshLivenessRemoteClient(on: store, router: router, box: box, clock: clock)
        #expect(store.stateSyncActive == false)
    }

    @Test func transientNegotiationFailureStillRunsTheLegacyReload() async throws {
        // The negotiation fetch itself fails transiently (not method_not_found).
        // Events missed in the subscription gap must still be recovered by the
        // authoritative legacy reload even though authority was never granted.
        let router = LivenessHostRouter()
        await router.scriptSyncFetchTransientError()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let probed = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= 1
        }
        #expect(probed)
        #expect(store.stateSyncActive == false)
        // The connect flow's route binding uses "workspace.list"; only the
        // fallback reload issues "mobile.workspace.list" here.
        let reloaded = try await pollUntil {
            await router.count(of: "mobile.workspace.list") >= 1
        }
        #expect(reloaded, "a transient negotiation failure must trigger the authoritative legacy reload")
    }

    @Test func legacyMacKeepsWorkspaceUpdatedRefetchLoop() async throws {
        // No scripted sync result: the router answers `method_not_found`,
        // modeling a released Mac.
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)

        let probed = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= 1
        }
        #expect(probed, "the shell must probe mobile.sync.fetch once per connection")
        #expect(store.stateSyncActive == false)

        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        let transport = try #require(box.get())
        await transport.deliver(try workspaceUpdatedEventFrame())
        let refetched = try await pollUntil {
            await router.count(of: "mobile.workspace.list") > listCallsBefore
        }
        #expect(refetched, "a legacy Mac must keep the workspace.updated refetch loop")
    }

    @Test func foregroundMutationRefreshRunsTrailingFetchForMutationDuringInFlightRefresh() async throws {
        let workspaceID = "live-workspace"
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: workspaceID, title: "synced-alpha", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 4,
                records: [workspaceRecord(id: workspaceID, title: "synced-beta", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 5,
                records: [workspaceRecord(id: workspaceID, title: "synced-gamma", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let negotiated = try await pollUntil {
            store.stateSyncActive
                && store.workspaces.contains { $0.rpcWorkspaceID.rawValue == workspaceID }
        }
        #expect(negotiated, "state sync must settle before the mutation refresh check")
        let foregroundTarget = WorkspaceMutationTarget(
            client: store.remoteClient,
            isForeground: true,
            macDeviceID: store.foregroundMacDeviceID
        )
        let fetchesBefore = await router.count(of: "mobile.sync.fetch")
        #expect(fetchesBefore >= 1)
        await router.holdSyncFetchRequest(number: fetchesBefore + 1)

        let firstRefresh = Task { @MainActor in
            await store.refreshAfterWorkspaceMutation(foregroundTarget)
        }
        let firstRequestStarted = await router.waitForCount(
            of: "mobile.sync.fetch",
            atLeast: fetchesBefore + 1
        )
        #expect(firstRequestStarted, "first foreground mutation refresh must start a state-sync fetch")

        let secondRefresh = Task { @MainActor in
            await store.refreshAfterWorkspaceMutation(foregroundTarget)
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        await router.releaseAllHeld()
        await firstRefresh.value
        await secondRefresh.value

        let trailingReloaded = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= fetchesBefore + 2
        }
        #expect(trailingReloaded, "a mutation arriving during an in-flight refresh must trigger one trailing fetch")
    }

    @Test func shortLivenessProbeDoesNotBoundTheSharedStateSyncFetch() async throws {
        let workspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: workspaceID, title: "synced-alpha", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 4,
                records: [workspaceRecord(id: workspaceID, title: "synced-after-resume", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let negotiated = try await pollUntil {
            store.stateSyncActive && store.workspaces.map(\.name).contains("synced-alpha")
        }
        #expect(negotiated)
        let fetchesBefore = await router.count(of: "mobile.sync.fetch")
        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        // The Mac answers the post-resume fetch slower than the probe deadline.
        await router.holdSyncFetchRequest(number: fetchesBefore + 1)

        let healthy = await store.reloadWorkspaceListFromMac(timeoutNanoseconds: 50_000_000)
        #expect(!healthy, "the probe must report within its own short deadline")
        // Long enough for a fetch RPC bounded by the probe's 50ms deadline to
        // fail and fall back to the legacy list.
        try await Task.sleep(nanoseconds: 200_000_000)
        await router.releaseAllHeld()

        let applied = try await pollUntil {
            store.workspaces.map(\.name).contains("synced-after-resume")
        }
        #expect(applied, "the shared fetch must keep its normal RPC timeout and apply the slow answer")
        #expect(store.stateSyncActive, "a probe deadline must not demote v2 to the legacy list")
        #expect(
            await router.count(of: "mobile.workspace.list") == listCallsBefore,
            "a probe deadline must not trigger the legacy fallback reload"
        )
    }

    @Test func livenessProbeDeadlineReportsTimedOutRefreshFailure() async throws {
        let workspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: workspaceID, title: "synced-alpha", sortIndex: 0)]
            )
        )
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 4,
                records: [workspaceRecord(id: workspaceID, title: "synced-after-resume", sortIndex: 0)]
            )
        )
        let box = TransportBox()
        let clock = TestClock()
        let log = DiagnosticLog(capacity: 256, role: .mobileClient)
        let store = try await makeConnectedStore(
            router: router,
            box: box,
            clock: clock,
            diagnosticLog: log
        )
        let negotiated = try await pollUntil {
            store.stateSyncActive && store.workspaces.map(\.name).contains("synced-alpha")
        }
        #expect(negotiated)
        let fetchesBefore = await router.count(of: "mobile.sync.fetch")
        await router.holdSyncFetchRequest(number: fetchesBefore + 1)
        await log.clear()

        let healthy = await store.reloadWorkspaceListFromMac(timeoutNanoseconds: 50_000_000)
        #expect(!healthy)
        func isRefreshFailure(_ event: DiagnosticEvent) -> Bool {
            event.code == .appFeatureAction
                && event.a == DiagnosticAppEventKind.workspaceListRefreshFailed.rawValue
        }
        let recorded = try await pollUntil {
            (await log.snapshot()).events.contains(where: isRefreshFailure)
        }
        #expect(recorded)
        let failures = (await log.snapshot()).events
            .filter(isRefreshFailure)
            .map(\.b)
        #expect(
            failures == [DiagnosticFailureKind.timedOut.rawValue],
            "a probe whose deadline expired must report a timeout, not an unknown failure"
        )
        await router.releaseAllHeld()
    }

    @Test func legacyEventChurnLetsTheInFlightListLandThenRunsOneTrailingFetch() async throws {
        // No scripted sync result: a legacy Mac on the workspace.updated loop.
        let router = LivenessHostRouter()
        let box = TransportBox()
        let clock = TestClock()
        let store = try await makeConnectedStore(router: router, box: box, clock: clock)
        let probed = try await pollUntil {
            await router.count(of: "mobile.sync.fetch") >= 1
        }
        #expect(probed)
        #expect(store.stateSyncActive == false)

        let listCallsBefore = await router.count(of: "mobile.workspace.list")
        await router.scriptWorkspaceListTitles(["first-answer", "trailing-answer"])
        await router.holdNextWorkspaceListRequests(count: 2)
        let transport = try #require(box.get())
        let eventGenerationBefore = store.workspaceListEventGeneration

        await transport.deliver(try workspaceUpdatedEventFrame())
        let firstStarted = await router.waitForCount(
            of: "mobile.workspace.list",
            atLeast: listCallsBefore + 1
        )
        #expect(firstStarted)
        let revisionBefore = store.foregroundWorkspaceStateRevision
        // Title churn while the first (slow) fetch is in flight.
        await transport.deliver(try workspaceUpdatedEventFrame())
        await transport.deliver(try workspaceUpdatedEventFrame())
        let consumed = try await pollUntil {
            store.workspaceListEventGeneration == eventGenerationBefore &+ 3
        }
        #expect(consumed)
        #expect(
            await router.count(of: "mobile.workspace.list") == listCallsBefore + 1,
            "events during an in-flight fetch must not cancel it and start another"
        )

        await router.releaseNextHeld()
        let firstApplied = try await pollUntil {
            store.foregroundWorkspaceStateRevision != revisionBefore
                && store.workspaces.map(\.name).contains("first-answer")
        }
        #expect(firstApplied, "the in-flight fetch must land despite newer events")
        let trailingStarted = await router.waitForCount(
            of: "mobile.workspace.list",
            atLeast: listCallsBefore + 2
        )
        #expect(trailingStarted, "events coalesced during the fetch must run a trailing fetch")
        await router.releaseAllHeld()
        let trailingApplied = try await pollUntil {
            store.workspaces.map(\.name).contains("trailing-answer")
        }
        #expect(trailingApplied)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(
            await router.count(of: "mobile.workspace.list") == listCallsBefore + 2,
            "the coalesced events must run exactly one trailing fetch"
        )
    }

    @Test func lateScopedAttachFullListDoesNotOverwriteStateSyncProjection() async throws {
        let syncedWorkspaceID = UUID().uuidString
        let router = LivenessHostRouter()
        await router.scriptSyncFetchResult(
            jsonData: try syncSnapshotResultData(
                epoch: "epoch-1",
                rev: 3,
                records: [workspaceRecord(id: syncedWorkspaceID, title: "synced-alpha", sortIndex: 0)]
            )
        )
        // The attach-token full list fails, so the connect binds through the
        // workspace-scoped list and schedules a full list afterwards; hold
        // that one until v2 has negotiated.
        await router.failWorkspaceListRequest(number: 1)
        await router.holdWorkspaceListRequest(number: 3)
        let box = TransportBox()
        let clock = TestClock()
        let runtime = LivenessTestRuntime(
            transportFactory: LivenessTransportFactory(router: router, box: box),
            now: { clock.now }
        )
        let store = MobileShellComposite.preview(runtime: runtime)
        store.signIn()
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: 56584)
        )
        let ticket = try CmxAttachTicket(
            workspaceID: UUID().uuidString,
            terminalID: "live-terminal",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: [route],
            expiresAt: clock.now.addingTimeInterval(3_600),
            authToken: "attach-secret"
        )
        let connected = await store.connectPairingURL(try attachURL(for: ticket))
        #expect(connected, "scripted scoped connect must succeed")
        let fullListStarted = await router.waitForCount(of: "workspace.list", atLeast: 3)
        #expect(fullListStarted, "a scoped connect must schedule the full attach-token list")
        let listScopes = await router.workspaceIDs(for: "workspace.list")
        #expect(listScopes.count == 3 && listScopes[2] == nil, "the held request must be the unscoped full list")
        let negotiated = try await pollUntil {
            store.stateSyncActive && store.workspaces.map(\.name).contains("synced-alpha")
        }
        #expect(negotiated)

        await router.releaseAllHeld()
        let settled = try await pollUntil { store.workspaceListRefreshTask == nil }
        #expect(settled)
        #expect(store.stateSyncActive)
        #expect(
            store.workspaces.map(\.name).contains("synced-alpha"),
            "a late full list must not overwrite the v2 projection"
        )
    }
}
