import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Agent feed decision replies")
struct MobileAgentFeedDecisionReplyTests {
    private func pendingPermission(in store: MobileShellComposite, owner: String = "test-mac") throws -> MobileAgentFeedItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": 1,
            "items": [[
                "id": "perm-1",
                "workstream_id": "claude-session-1",
                "source": "claude",
                "kind": "permissionRequest",
                "status": "pending",
                "request_id": "req-1",
                "created_at": "2026-10-30T12:00:00Z",
                "updated_at": "2026-10-30T12:00:00Z",
            ]],
        ])
        #expect(store.applyAgentFeedSnapshot(
            try MobileAgentFeedListResponse.decode(data),
            macDeviceID: owner,
            displayName: "Agent Mac"
        ))
        return try #require(store.agentFeedItems.first)
    }

    @Test("A decision the Mac refused is reported instead of vanishing")
    func refusedDecision() async throws {
        let router = RoutingHostRouter()
        await router.setRejectFeedDecisions(true)
        let store = try await makeRoutingConnectedStore(router: router, hostCapabilities: [MobileShellComposite.agentFeedCapability])
        let row = try pendingPermission(in: store)

        #expect(!(await store.submitAgentFeedPermissionReply(row, mode: "once")))
        #expect(store.agentFeedDecisionReplyFailure == row.id)
    }

    @Test("A decision for a Mac that is not connected is reported")
    func disconnectedMac() async throws {
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter(), hostCapabilities: [MobileShellComposite.agentFeedCapability])
        let row = try pendingPermission(in: store, owner: "other-mac")

        #expect(!(await store.submitAgentFeedQuestionReply(row, selections: ["yes"])))
        #expect(store.agentFeedDecisionReplyFailure == row.id)
    }

    @Test("A delivered decision clears an earlier failure, and dismissing clears it too")
    func deliveredDecision() async throws {
        let router = RoutingHostRouter()
        await router.setRejectFeedDecisions(true)
        let store = try await makeRoutingConnectedStore(router: router, hostCapabilities: [MobileShellComposite.agentFeedCapability])
        let row = try pendingPermission(in: store)
        _ = await store.submitAgentFeedExitPlanReply(row, mode: "approve")
        #expect(store.agentFeedDecisionReplyFailure == row.id)
        store.dismissAgentFeedDecisionReplyFailure()
        #expect(store.agentFeedDecisionReplyFailure == nil)

        _ = await store.submitAgentFeedExitPlanReply(row, mode: "approve")
        await router.setRejectFeedDecisions(false)
        #expect(await store.submitAgentFeedExitPlanReply(row, mode: "approve"))
        #expect(store.agentFeedDecisionReplyFailure == nil)
    }
}
