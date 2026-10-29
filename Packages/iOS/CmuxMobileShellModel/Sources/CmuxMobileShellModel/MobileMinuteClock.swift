public import Foundation

/// Minute-aligned ticks for relative timestamps ("5m", "3 hr. ago") and the
/// feed's Today/Yesterday sections. A label computed once never advances on
/// its own, so a list left open must re-read the clock on each minute
/// boundary or it keeps showing the time it was first drawn at.
public enum MobileMinuteClock {
    /// The first whole-minute boundary strictly after `date`.
    public static func nextTick(after date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60)
    }

    /// Whether `later` falls on a different calendar day than `earlier`.
    public static func dayChanged(from earlier: Date, to later: Date, calendar: Calendar) -> Bool {
        !calendar.isDate(earlier, inSameDayAs: later)
    }

    /// Calls `tick` with the current date on every minute boundary until the
    /// calling task is cancelled.
    @MainActor
    public static func run(_ tick: @MainActor (Date) -> Void) async {
        while !Task.isCancelled {
            let delay = nextTick(after: Date()).timeIntervalSinceNow
            do {
                try await Task.sleep(for: .seconds(max(delay, 0.05)))
            } catch {
                return
            }
            tick(Date())
        }
    }
}

/// Relative labels for feed rows, computed against an explicit clock so a
/// row redraw shows the true age instead of the age when it was cached.
public enum MobileFeedTimestamp {
    /// "5 min. ago" style label. A Mac clock running ahead of the phone can
    /// stamp a row slightly in the future; that reads as now, not "in 1 min."
    public static func relativeLabel(
        for date: Date,
        now: Date,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// The rows a user cleared from a feed on this phone, remembered across
/// launches. Bounded so it cannot grow forever; the oldest cleared keys are
/// forgotten first, and by then the Mac has usually trimmed those rows too.
public struct MobileFeedClearedRows: Equatable, Sendable {
    public private(set) var persistedKeys: [String]
    private var keys: Set<String>
    private let limit: Int

    public init(limit: Int, persistedKeys: [String] = []) {
        self.limit = max(1, limit)
        var seen = Set<String>()
        let unique = persistedKeys.filter { seen.insert($0).inserted }
        self.persistedKeys = Array(unique.suffix(self.limit))
        keys = Set(self.persistedKeys)
    }

    public func contains(_ key: String) -> Bool {
        keys.contains(key)
    }

    @discardableResult
    public mutating func insert(_ key: String) -> Bool {
        guard keys.insert(key).inserted else { return false }
        persistedKeys.append(key)
        if persistedKeys.count > limit {
            let overflow = persistedKeys.count - limit
            persistedKeys.prefix(overflow).forEach { keys.remove($0) }
            persistedKeys.removeFirst(overflow)
        }
        return true
    }

    @discardableResult
    public mutating func insert(contentsOf newKeys: some Sequence<String>) -> Bool {
        newKeys.reduce(false) { changed, key in insert(key) || changed }
    }
}
