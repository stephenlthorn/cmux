@testable import CmuxMobileShell
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing

@MainActor
@Suite("Clearing feed rows on the phone")
struct MobileShellFeedClearingTests {
    @Test("A cleared notification leaves the feed and its unread count, and stays gone after a refresh")
    func clearedNotificationStaysGone() async throws {
        let store = composite()
        #expect(store.applyNotificationFeedSnapshot(
            try notifications(revision: 1, ids: ["keep", "clear"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        let cleared = try #require(store.notificationFeedItems.first { $0.notificationID == "clear" })

        await store.clearNotificationFeedItems([cleared])

        #expect(store.notificationFeedItems.map(\.notificationID) == ["keep"])
        #expect(store.notificationFeedUnreadCount == 1)
        #expect(store.applyNotificationFeedSnapshot(
            try notifications(revision: 2, ids: ["keep", "clear"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.notificationFeedItems.map(\.notificationID) == ["keep"])
    }

    @Test("Clearing a notification on one Mac leaves the same id from another Mac")
    func clearingIsScopedToTheOwningMac() async throws {
        let store = composite()
        #expect(store.applyNotificationFeedSnapshot(
            try notifications(revision: 1, ids: ["same"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.applyNotificationFeedSnapshot(
            try notifications(revision: 1, ids: ["same"]),
            macDeviceID: "mac-b",
            displayName: "Laptop"
        ))
        let fromA = try #require(store.notificationFeedItems.first { $0.macDeviceID == "mac-a" })

        await store.clearNotificationFeedItems([fromA])

        #expect(store.notificationFeedItems.map(\.macDeviceID) == ["mac-b"])
    }

    @Test("Cleared notifications are remembered across launches")
    func clearedNotificationsPersist() async throws {
        let defaults = try #require(UserDefaults(suiteName: "feed-clearing-\(UUID().uuidString)"))
        let first = composite(defaults: defaults)
        #expect(first.applyNotificationFeedSnapshot(
            try notifications(revision: 1, ids: ["a", "b"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        await first.clearNotificationFeedItems(first.notificationFeedItems.filter { $0.notificationID == "a" })

        let relaunched = composite(defaults: defaults)
        #expect(relaunched.applyNotificationFeedSnapshot(
            try notifications(revision: 1, ids: ["a", "b"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(relaunched.notificationFeedItems.map(\.notificationID) == ["b"])
    }

    @Test("A cleared Feed row leaves the timeline and the needs-input count, and stays gone after a refresh")
    func clearedAgentFeedRowStaysGone() throws {
        let store = composite()
        #expect(store.applyAgentFeedSnapshot(
            try agentFeed(revision: 1, ids: ["keep", "clear"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.agentFeedNeedsInputCount == 2)
        let cleared = try #require(store.agentFeedItems.first { $0.itemID == "clear" })

        store.clearAgentFeedItems([cleared])

        #expect(store.agentFeedItems.map(\.itemID) == ["keep"])
        #expect(store.agentFeedNeedsInputCount == 1)
        #expect(store.applyAgentFeedSnapshot(
            try agentFeed(revision: 2, ids: ["keep", "clear"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(store.agentFeedItems.map(\.itemID) == ["keep"])
    }

    @Test("Clear All skips Feed requests that are still waiting on an answer")
    func clearAllKeepsPendingRequests() throws {
        let store = composite()
        #expect(store.applyAgentFeedSnapshot(
            try agentFeed(revision: 1, ids: ["waiting"], extraRows: [
                agentRow(id: "done", kind: "stop", status: "resolved", requestID: nil, createdAt: "2026-08-14T09:00:00Z"),
            ]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))

        store.clearAllAgentFeedItems(store.agentFeedItems)

        #expect(store.agentFeedItems.map(\.itemID) == ["waiting"])
    }

    @Test("Rows the Feed never shows do not count as needing input")
    func hiddenRowsDoNotRaiseTheBadge() throws {
        let store = composite()
        let future = "2099-01-01T00:00:00Z"
        #expect(store.applyAgentFeedSnapshot(
            try agentFeed(revision: 1, ids: [], extraRows: [
                agentRow(id: "tool", kind: "toolUse", status: "resolved", createdAt: future),
                agentRow(id: "prompt", kind: "userPrompt", status: "resolved", createdAt: future),
                agentRow(id: "ok-result", kind: "toolResult", status: "resolved", createdAt: future),
                agentRow(id: "message", kind: "assistantMessage", status: "resolved", createdAt: future),
            ]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))

        #expect(store.agentFeedNeedsInputCount == 1)
        #expect(store.agentFeedItems.filter(\.effectiveNeedsInput).map(\.itemID) == ["message"])
    }

    @Test("Marking a waiting request Done survives a relaunch")
    func doneTriagePersists() throws {
        let defaults = try #require(UserDefaults(suiteName: "feed-triage-\(UUID().uuidString)"))
        let first = composite(defaults: defaults)
        #expect(first.applyAgentFeedSnapshot(
            try agentFeed(revision: 1, ids: ["waiting"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        first.setAgentFeedItemNeedsInput(try #require(first.agentFeedItems.first), false)

        let relaunched = composite(defaults: defaults)
        #expect(relaunched.applyAgentFeedSnapshot(
            try agentFeed(revision: 1, ids: ["waiting"]),
            macDeviceID: "mac-a",
            displayName: "Studio"
        ))
        #expect(relaunched.agentFeedNeedsInputCount == 0)
    }

    @Test("A failing Feed refresh backs off and then waits for the next trigger")
    func refreshFailuresBackOff() {
        #expect(MobileShellComposite.agentFeedRetryDelay(afterConsecutiveFailures: 1) == .seconds(1))
        #expect(MobileShellComposite.agentFeedRetryDelay(afterConsecutiveFailures: 2) == .seconds(4))
        #expect(MobileShellComposite.agentFeedRetryDelay(afterConsecutiveFailures: 3) == nil)
    }

    private func composite(defaults: UserDefaults? = nil) -> MobileShellComposite {
        let store = MobileShellComposite(workspaces: [workspace()])
        store.feedLocalStateDefaults = defaults
        return store
    }

    private func workspace() -> MobileWorkspacePreview {
        var preview = MobileWorkspacePreview(id: "row", macDeviceID: "mac-a", name: "Workspace", terminals: [])
        preview.remoteWorkspaceID = "workspace"
        return preview
    }

    private func notifications(revision: Int, ids: [String]) throws -> MobileNotificationFeedListResponse {
        let rows = ids.enumerated().map { index, id in
            #"{"id":"\#(id)","workspace_id":"workspace","title":"Title","body":"Body","created_at":\#(200 - index),"is_read":false}"#
        }.joined(separator: ",")
        return try MobileNotificationFeedListResponse.decode(Data(
            #"{"revision":\#(revision),"notifications":[\#(rows)]}"#.utf8
        ))
    }

    private func agentFeed(
        revision: Int,
        ids: [String],
        extraRows: [[String: Any]] = []
    ) throws -> MobileAgentFeedListResponse {
        let rows = ids.enumerated().map { index, id in
            agentRow(id: id, createdAt: "2026-08-14T1\(index):00:00Z")
        } + extraRows
        let data = try JSONSerialization.data(withJSONObject: ["revision": revision, "items": rows])
        return try MobileAgentFeedListResponse.decode(data)
    }

    private func agentRow(
        id: String,
        kind: String = "permissionRequest",
        status: String = "pending",
        requestID: String? = nil,
        createdAt: String
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "workstream_id": "claude-s1",
            "source": "claude",
            "kind": kind,
            "status": status,
            "created_at": createdAt,
            "updated_at": createdAt,
        ]
        row["request_id"] = requestID ?? (kind == "permissionRequest" ? "req-\(id)" : nil)
        return row
    }
}
