import Foundation

/// When progress photos are due. daily / every 2 days / weekly / custom (N days), counted from the last photo of the series.
enum PhotoSchedules {
    /// The day the next photo is due: last photo + interval; after missed days it is due today (never in the past).
    static func nextDue(last: Date?, schedule: PhotoSchedule, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let last else { return today }
        let due = calendar.date(byAdding: .day, value: schedule.intervalDays, to: calendar.startOfDay(for: last)) ?? today
        return max(due, today)
    }

    static func isDue(last: Date?, schedule: PhotoSchedule, now: Date, calendar: Calendar = .current) -> Bool {
        guard schedule.enabled else { return false }
        return calendar.isDate(nextDue(last: last, schedule: schedule, now: now, calendar: calendar), inSameDayAs: now)
    }

    static func dueSeries(_ schedules: [String: PhotoSchedule], lastPhoto: (PhotoSeries) -> Date?, now: Date, calendar: Calendar = .current) -> [PhotoSeries] {
        PhotoSeries.allCases.filter { s in schedules[s.rawValue].map { isDue(last: lastPhoto(s), schedule: $0, now: now, calendar: calendar) } ?? false }
    }

    /// When to notify next: the due day at the chosen time; if that moment has passed, the same time tomorrow.
    static func nextReminder(last: Date?, schedule: PhotoSchedule, now: Date, calendar: Calendar = .current) -> Date {
        let due = nextDue(last: last, schedule: schedule, now: now, calendar: calendar)
        var at = calendar.date(bySettingHour: schedule.hour, minute: schedule.minute, second: 0, of: due) ?? due
        if at <= now { at = calendar.date(byAdding: .day, value: 1, to: at) ?? at }
        return at
    }
}
