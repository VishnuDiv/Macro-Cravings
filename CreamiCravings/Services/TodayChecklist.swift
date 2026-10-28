import Foundation

enum CheckGroup: String, CaseIterable, Identifiable {
    case skinAM, skinPM, hair, photo, extra
    var id: String { rawValue }
    var title: String {
        switch self { case .skinAM: return "Skin, morning"; case .skinPM: return "Skin, evening"; case .hair: return "Hair"; case .photo: return "Progress photos"; case .extra: return "Your extras" }
    }
    var symbol: String {
        switch self { case .skinAM: return "sun.max"; case .skinPM: return "moon"; case .hair: return "comb"; case .photo: return "camera"; case .extra: return "drop" }
    }
    /// Groups that count toward streaks and the adherence ring (photos and extras are tracked on their own).
    var isRoutine: Bool { self == .skinAM || self == .skinPM || self == .hair }
}

struct CheckItem: Identifiable, Hashable {
    var id: String
    var group: CheckGroup
    var title: String
    var detail: String = ""
    var productId: UUID?            // skin items: the product this step is mapped to
    var productName = ""            // what the user mapped to the step; empty = not set yet
    var series: PhotoSeries?        // photo items: tapping opens the camera
    var autoDone = false            // a photo already taken today
}

/// What is on the Today checklist for a day, and the streaks and adherence derived from the ticks.
enum TodayChecklist {
    static func dayKey(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func items(on date: Date, data: UserData, skincare: SkincareContent?, lastPhoto: (PhotoSeries) -> Date?, calendar: Calendar = .current) -> [CheckItem] {
        var out: [CheckItem] = []
        let weekday = calendar.component(.weekday, from: date)
        for (group, period) in [(CheckGroup.skinAM, "am"), (.skinPM, "pm")] {
            for p in data.products where p.frequency != "as-needed" {
                guard SkinRoutine.isUsed(p, period: period, weekday: weekday, now: date, content: skincare, calendar: calendar) else { continue }
                var detail = ""
                if p.frequency == "ramp-up" {
                    let w = SkinRoutine.weeks(from: p.startedAt, to: date, calendar: calendar)
                    let n = SkinRoutine.rampNights(weeksSinceStart: w, ramp: skincare?.rampUps["retinoid"] ?? [])
                    detail = "Ramp-up week \(w + 1): \(n) night\(n == 1 ? "" : "s") this week"
                }
                out.append(CheckItem(id: "\(period)-\(p.id.uuidString)", group: group, title: Pretty.step(p.step), detail: detail, productId: p.id, productName: p.name))
            }
        }
        for h in data.hairItems where Cadence.isDue(h.schedule, start: h.startedAt, on: date, calendar: calendar) {
            out.append(CheckItem(id: "hair-\(h.id.uuidString)", group: .hair, title: h.title, detail: h.note))
        }
        for s in PhotoSeries.allCases {
            guard let sched = data.photoSchedules[s.rawValue], sched.enabled else { continue }
            let last = lastPhoto(s)
            let tookToday = last.map { calendar.isDate($0, inSameDayAs: date) } ?? false
            if tookToday || PhotoSchedules.isDue(last: last, schedule: sched, now: date, calendar: calendar) {
                out.append(CheckItem(id: "photo-\(s.rawValue)", group: .photo, title: s.title, detail: "Tap to open the camera", series: s, autoDone: tookToday))
            }
        }
        for x in data.extraItems { out.append(CheckItem(id: "extra-\(x.id.uuidString)", group: .extra, title: x.title)) }
        return out
    }

    static func ticked(_ data: UserData, _ date: Date, calendar: Calendar = .current) -> Set<String> { data.checks[dayKey(date, calendar: calendar)] ?? [] }

    /// Share of the day's skin and hair routine items that are ticked; nil when nothing was due.
    static func adherence(on date: Date, data: UserData, skincare: SkincareContent?, calendar: Calendar = .current) -> Double? {
        let routine = items(on: date, data: data, skincare: skincare, lastPhoto: { _ in nil }, calendar: calendar).filter { $0.group.isRoutine }
        guard !routine.isEmpty else { return nil }
        let t = ticked(data, date, calendar: calendar)
        return Double(routine.filter { t.contains($0.id) }.count) / Double(routine.count)
    }

    /// Adherence over the last `days` days up to `date`: ticked divided by due.
    static func weekAdherence(endingOn date: Date, days: Int = 7, data: UserData, skincare: SkincareContent?, calendar: Calendar = .current) -> Double? {
        var due = 0, done = 0
        for back in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -back, to: date) else { continue }
            let routine = items(on: d, data: data, skincare: skincare, lastPhoto: { _ in nil }, calendar: calendar).filter { $0.group.isRoutine }
            let t = ticked(data, d, calendar: calendar)
            due += routine.count; done += routine.filter { t.contains($0.id) }.count
        }
        return due == 0 ? nil : Double(done) / Double(due)
    }

    /// Consecutive days a routine group was fully done, ending today (today not yet finished does not break it). Days with nothing due are skipped.
    static func streak(_ group: CheckGroup, endingOn date: Date, data: UserData, skincare: SkincareContent?, calendar: Calendar = .current) -> Int {
        var n = 0
        for back in 0..<400 {
            guard let d = calendar.date(byAdding: .day, value: -back, to: date) else { break }
            let list = items(on: d, data: data, skincare: skincare, lastPhoto: { _ in nil }, calendar: calendar).filter { $0.group == group }
            if list.isEmpty { continue }
            let t = ticked(data, d, calendar: calendar)
            if list.allSatisfy({ t.contains($0.id) }) { n += 1 } else if back == 0 { continue } else { break }
        }
        return n
    }
}

/// For the photo entry: the routine adherence of the day the photo was taken.
enum Adherence {
    static func score(_ data: UserData, on date: Date, content: SkincareContent? = nil) -> Double? {
        TodayChecklist.adherence(on: date, data: data, skincare: content)
    }
}

/// Small text helpers for ids and weekdays.
enum Pretty {
    static func text(_ id: String) -> String { id.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized }
    /// Display names for routine steps ("spf" is SPF).
    static func step(_ id: String) -> String {
        switch id { case "spf": return "SPF"; case "spot": return "Spot treatment"; default: return text(id) }
    }
    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static func days(_ d: Set<Int>) -> String { d.isEmpty || d.count == 7 ? "every day" : d.sorted().map { weekdayNames[$0 - 1] }.joined(separator: ", ") }
}
