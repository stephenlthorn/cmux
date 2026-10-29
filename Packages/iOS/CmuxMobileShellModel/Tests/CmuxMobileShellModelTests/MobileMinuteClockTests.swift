import Foundation
import Testing

@testable import CmuxMobileShellModel

@Suite struct MobileMinuteClockTests {
    private let minute = Date(timeIntervalSince1970: 1_750_000_020)

    @Test func nextTickIsTheFollowingWholeMinute() {
        #expect(MobileMinuteClock.nextTick(after: minute.addingTimeInterval(30)) == minute.addingTimeInterval(60))
        #expect(MobileMinuteClock.nextTick(after: minute.addingTimeInterval(0.001)) == minute.addingTimeInterval(60))
    }

    @Test func aTickExactlyOnABoundaryWaitsForTheNextMinute() {
        #expect(MobileMinuteClock.nextTick(after: minute) == minute.addingTimeInterval(60))
    }

    @Test func dayChangesOnlyAcrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = Date(timeIntervalSince1970: 1_750_000_000)
        let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: evening))!
        #expect(!MobileMinuteClock.dayChanged(from: evening, to: evening.addingTimeInterval(60), calendar: calendar))
        #expect(MobileMinuteClock.dayChanged(from: evening, to: startOfNextDay, calendar: calendar))
    }
}

@Suite struct MobileFeedTimestampTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let locale = Locale(identifier: "en_US")

    @Test func showsHowLongAgoAgainstTheSuppliedClock() {
        #expect(MobileFeedTimestamp.relativeLabel(for: now.addingTimeInterval(-5 * 60), now: now, locale: locale)
            == "5m ago")
        #expect(MobileFeedTimestamp.relativeLabel(for: now.addingTimeInterval(-3 * 3600), now: now, locale: locale)
            == "3h ago")
    }

    @Test func aMacClockAheadOfThePhoneReadsNowInsteadOfTheFuture() {
        #expect(MobileFeedTimestamp.relativeLabel(for: now.addingTimeInterval(90), now: now, locale: locale)
            == MobileFeedTimestamp.relativeLabel(for: now, now: now, locale: locale))
    }
}

@Suite struct MobileFeedClearedRowsTests {
    @Test func remembersClearedKeys() {
        var rows = MobileFeedClearedRows(limit: 10)
        let first = rows.insert("a")
        let second = rows.insert("a")
        #expect(first)
        #expect(!second)
        #expect(rows.contains("a"))
        #expect(!rows.contains("b"))
    }

    @Test func forgetsTheOldestClearedKeysPastTheLimit() {
        var rows = MobileFeedClearedRows(limit: 2)
        rows.insert(contentsOf: ["a", "b", "c"])
        #expect(!rows.contains("a"))
        #expect(rows.contains("b"))
        #expect(rows.contains("c"))
    }

    @Test func restoresFromItsPersistedOrder() {
        var rows = MobileFeedClearedRows(limit: 2)
        rows.insert(contentsOf: ["a", "b"])
        var restored = MobileFeedClearedRows(limit: 2, persistedKeys: rows.persistedKeys)
        restored.insert("c")
        #expect(restored.persistedKeys == ["b", "c"])
    }

    @Test func restoringMoreKeysThanTheLimitKeepsTheNewest() {
        let rows = MobileFeedClearedRows(limit: 2, persistedKeys: ["a", "b", "c"])
        #expect(rows.persistedKeys == ["b", "c"])
    }
}
