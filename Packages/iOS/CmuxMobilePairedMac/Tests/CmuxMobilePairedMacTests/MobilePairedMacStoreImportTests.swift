import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobilePairedMac

@Suite struct MobilePairedMacStoreImportTests {
    @Test func upgradePreservesSavedComputersWithoutChangingLegacyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        let destinationURL = directory.appendingPathComponent("v2.sqlite3")
        let legacy = try MobilePairedMacStore(databaseURL: legacyURL)
        let route = try CmxAttachRoute(id: "direct", kind: .tailscale,
                                       endpoint: .hostPort(host: "100.64.0.1", port: 8443))
        let date = Date(timeIntervalSince1970: 1_000)
        try await legacy.upsert(macDeviceID: "same-mac", displayName: "Mac", routes: [route],
                                instanceTag: "internal", markActive: true, stackUserID: "alice",
                                teamID: "team-a", now: date)
        _ = try await legacy.upsertIfNewer(macDeviceID: "same-mac", displayName: "Mac", routes: [route],
                                           instanceTag: "internal", customName: "Home Mac",
                                           customColor: "palette:2", customIcon: "house", markActive: true,
                                           stackUserID: "alice", teamID: "team-a", now: date.addingTimeInterval(1))
        try await legacy.setConnectionMethod(macDeviceID: "same-mac", instanceTag: nil,
                                              rawValue: "tailscale", stackUserID: "alice", teamID: "team-a")
        try await legacy.setDirectAddresses(macDeviceID: "same-mac", instanceTag: nil,
                                            rawJSON: "[{\"address\":\"192.168.1.10\",\"enabled\":true}]",
                                            stackUserID: "alice", teamID: "team-a")
        // Device-local route authority must never be created by moving metadata.
        try await legacy.authorizeUserTailscaleRoutes(macDeviceID: "same-mac", instanceTag: nil,
                                                     stackUserID: "alice", teamID: "team-a", routes: [route])
        let before = try await legacy.loadAll()
        #expect(before.first(where: { $0.stackUserID == "alice" && $0.teamID == "team-a" && $0.instanceTag == "internal" })?.customName == "Home Mac")
        let upgraded = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        let imported = try #require(try await upgraded.loadAll(stackUserID: "alice", teamID: "team-a")
            .first(where: { $0.instanceTag == "internal" }))
        #expect(imported.customName == "Home Mac")
        #expect(imported.customColor == "palette:2")
        #expect(imported.customIcon == "house")
        #expect(imported.routes == [route])
        #expect(imported.createdAt == date)
        #expect(imported.lastSeenAt == date.addingTimeInterval(1))
        #expect(imported.isActive)
        #expect(imported.legacyTailscaleRoutes?.isEmpty != false)
        #expect(try await upgraded.loadAll().count == 1)
        #expect(try await legacy.loadAll() == before)

        try await upgraded.remove(macDeviceID: "same-mac", instanceTag: "internal",
                                  stackUserID: "alice", teamID: "team-a")
        let reopened = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await reopened.loadAll(stackUserID: "alice", teamID: "team-a").isEmpty)
        #expect(try await reopened.loadAll().count == 0)
    }

    @Test func existingV2RowsWinAndUnrequestedImportsRemainIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        let destinationURL = directory.appendingPathComponent("production.sqlite3")
        let legacy = try MobilePairedMacStore(databaseURL: legacyURL)
        let destination = try MobilePairedMacStore(databaseURL: destinationURL)
        for (store, name) in [(legacy, "Old name"), (destination, "New name")] {
            try await store.upsert(macDeviceID: "mac", displayName: name, routes: [],
                                   instanceTag: "internal", markActive: true,
                                   stackUserID: "alice", teamID: "team", now: Date())
        }
        let upgraded = try MobilePairedMacStore(databaseURL: destinationURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await upgraded.loadAll().first?.displayName == "New name")
        let otherEnvironment = try MobilePairedMacStore(databaseURL: directory.appendingPathComponent("development.sqlite3"))
        #expect(try await otherEnvironment.loadAll().isEmpty)
    }

    /// An older build that opened the store but never used it leaves a legacy
    /// file with no `paired_macs` table: there is nothing to import.
    @Test func legacyFileWithoutSavedComputersTableKeepsStoreUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        _ = try MobilePairedMacStore(databaseURL: legacyURL)
        try #require(FileManager.default.fileExists(atPath: legacyURL.path))

        try await Self.expectUsableStore(at: directory.appendingPathComponent("v2.sqlite3"),
                                         importingLegacyDatabaseURL: legacyURL)
    }

    /// A legacy file that cannot be read is skipped, not rethrown from every
    /// later store call: that would read as losing every saved Computer.
    @Test func unreadableLegacyFileKeepsStoreUsable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("legacy.sqlite3")
        try Data(repeating: 0x5A, count: 8_192).write(to: legacyURL)

        try await Self.expectUsableStore(at: directory.appendingPathComponent("v2.sqlite3"),
                                         importingLegacyDatabaseURL: legacyURL)
    }

    private static func expectUsableStore(at databaseURL: URL, importingLegacyDatabaseURL legacyURL: URL) async throws {
        let store = try MobilePairedMacStore(databaseURL: databaseURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await store.loadAll().isEmpty)
        try await store.upsert(macDeviceID: "mac", displayName: "Mac", routes: [],
                               instanceTag: "internal", markActive: true,
                               stackUserID: "alice", teamID: "team", now: Date())
        #expect(try await store.loadAll().map(\.macDeviceID) == ["mac"])
        let reopened = try MobilePairedMacStore(databaseURL: databaseURL, importingLegacyDatabaseURL: legacyURL)
        #expect(try await reopened.loadAll().map(\.macDeviceID) == ["mac"])
    }
}
