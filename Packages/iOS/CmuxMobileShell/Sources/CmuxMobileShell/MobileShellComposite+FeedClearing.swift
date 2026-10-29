public import CmuxMobileShellModel
import Foundation

/// Phone-local "Clear" for the Notifications and Feed tabs. A cleared row is
/// hidden on this phone for good, even when the Mac lists it again; the Mac
/// keeps its own history.
@MainActor
extension MobileShellComposite {
    static let feedClearedRowsLimit = 5_000
    private static let notificationFeedClearedRowsDefaultsKey = "cmux.mobile.notificationFeed.clearedRowKeys.v1"
    private static let agentFeedClearedRowsDefaultsKey = "cmux.mobile.agentFeed.clearedRowKeys.v1"

    static func notificationFeedRowKey(_ id: MobileNotificationFeedItemID) -> String {
        "\(id.macDeviceID)|\(id.macInstanceTag ?? "")|\(id.notificationID)"
    }

    func notificationFeedIsCleared(_ item: MobileNotificationFeedItem) -> Bool {
        notificationFeedClearedRows().contains(Self.notificationFeedRowKey(item.id))
    }

    /// Stop rows can switch identity between delivery lanes, so they are also
    /// matched by turn, like their read state.
    func agentFeedIsCleared(_ item: MobileAgentFeedItem) -> Bool {
        let rows = agentFeedClearedRows()
        return rows.contains(Self.agentFeedRowKey(item.id))
            || (item.kind == .stop && rows.contains(Self.agentFeedTurnKey(item)))
    }

    @discardableResult
    func insertClearedNotificationFeedRows(_ items: [MobileNotificationFeedItem]) -> Bool {
        var rows = notificationFeedClearedRows()
        guard rows.insert(contentsOf: items.map { Self.notificationFeedRowKey($0.id) }) else { return false }
        notificationFeedClearedRowsCache = rows
        feedLocalStateDefaults?.set(rows.persistedKeys, forKey: Self.notificationFeedClearedRowsDefaultsKey)
        return true
    }

    @discardableResult
    func insertClearedAgentFeedRows(_ items: [MobileAgentFeedItem]) -> Bool {
        var rows = agentFeedClearedRows()
        let keys = items.flatMap { item in
            item.kind == .stop
                ? [Self.agentFeedRowKey(item.id), Self.agentFeedTurnKey(item)]
                : [Self.agentFeedRowKey(item.id)]
        }
        guard rows.insert(contentsOf: keys) else { return false }
        agentFeedClearedRowsCache = rows
        feedLocalStateDefaults?.set(rows.persistedKeys, forKey: Self.agentFeedClearedRowsDefaultsKey)
        return true
    }

    private func notificationFeedClearedRows() -> MobileFeedClearedRows {
        if let rows = notificationFeedClearedRowsCache { return rows }
        let rows = loadClearedRows(forKey: Self.notificationFeedClearedRowsDefaultsKey)
        notificationFeedClearedRowsCache = rows
        return rows
    }

    private func agentFeedClearedRows() -> MobileFeedClearedRows {
        if let rows = agentFeedClearedRowsCache { return rows }
        let rows = loadClearedRows(forKey: Self.agentFeedClearedRowsDefaultsKey)
        agentFeedClearedRowsCache = rows
        return rows
    }

    /// Mirrors the Feed timeline's own filter: tool calls, the user's own
    /// prompts, successful tool results, and notification history never show
    /// as rows, so they must never count toward the needs-input badge.
    static func agentFeedShowsInTimeline(_ item: MobileAgentFeedItem) -> Bool {
        guard item.source.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("notification") != .orderedSame else { return false }
        switch item.kind {
        case .toolUse, .userPrompt: return false
        case .toolResult: return item.toolResultIsError
        default: return true
        }
    }

    /// Needs-input triage the user set by swipe, keyed by row, so a request
    /// marked Done stays Done after a relaunch.
    func agentFeedPersistedTriage() -> [String: Bool] {
        if let triage = agentFeedPersistedTriageCache { return triage }
        let triage = feedLocalStateDefaults?.dictionary(forKey: Self.agentFeedTriageDefaultsKey) as? [String: Bool] ?? [:]
        agentFeedPersistedTriageCache = triage
        return triage
    }

    func agentFeedPersistTriage(_ needsInput: Bool?, forRowKey key: String) {
        var triage = agentFeedPersistedTriage()
        guard triage[key] != needsInput else { return }
        triage[key] = needsInput
        if triage.count > Self.feedClearedRowsLimit {
            let liveKeys = Set(agentFeedSnapshotsByMac.values.flatMap { $0.items.map { Self.agentFeedRowKey($0.id) } })
            triage = triage.filter { liveKeys.contains($0.key) }
        }
        agentFeedPersistedTriageCache = triage
        feedLocalStateDefaults?.set(triage, forKey: Self.agentFeedTriageDefaultsKey)
    }

    private static let agentFeedTriageDefaultsKey = "cmux.mobile.agentFeed.triageOverrides.v1"

    private func loadClearedRows(forKey key: String) -> MobileFeedClearedRows {
        MobileFeedClearedRows(
            limit: Self.feedClearedRowsLimit,
            persistedKeys: feedLocalStateDefaults?.stringArray(forKey: key) ?? []
        )
    }
}
