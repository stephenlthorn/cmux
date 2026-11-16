import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationDayLabelTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func aMessageFromEarlierTheSameDayIsToday() {
        #expect(ConversationDayLabel(for: date(30, 9), now: date(30, 23), calendar: calendar) == .today)
    }

    @Test func pastMidnightTheSameMessageBecomesYesterday() {
        #expect(ConversationDayLabel(for: date(30, 23), now: date(31, 0), calendar: calendar) == .yesterday)
    }

    @Test func withinAWeekItIsTheWeekday() {
        #expect(ConversationDayLabel(for: date(26, 12), now: date(31, 12), calendar: calendar) == .weekday)
    }

    @Test func aWeekOrMoreAgoItIsTheDate() {
        #expect(ConversationDayLabel(for: date(23, 12), now: date(30, 12), calendar: calendar) == .date)
    }

    @Test func theLabelFollowsTheClockItIsGivenNotTheRealOne() {
        let longAgo = Date(timeIntervalSince1970: 0)
        #expect(ConversationDayLabel(for: longAgo, now: longAgo, calendar: calendar) == .today)
    }
}
