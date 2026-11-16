public import Foundation

/// Which day word a transcript separator shows, by the clock it is given.
///
/// Messages labels a separator "Today" or "Yesterday", the weekday within a
/// week, and the date after that. The answer depends on "now", so a
/// separator left on screen past midnight must be recomputed.
public enum ConversationDayLabel: Equatable, Sendable {
    case today, yesterday, weekday, date

    /// - Parameters:
    ///   - date: When the message was sent.
    ///   - now: The current time.
    ///   - calendar: The calendar that decides where days start.
    public init(for date: Date, now: Date, calendar: Calendar = .current) {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        switch days {
        case ..<1: self = .today
        case 1: self = .yesterday
        case 2..<7: self = .weekday
        default: self = .date
        }
    }
}
