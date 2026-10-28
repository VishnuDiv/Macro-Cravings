import Foundation

struct ConflictWarning: Identifiable, Hashable {
    var id: String { "\(a)|\(b)|\(period)|\(weekday)" }
    var a: String
    var b: String
    var message: String
    var severity: String
    var period: String           // am | pm | "" (not tied to a session)
    var weekday: Int             // 1...7 (Sunday = 1), 0 when not tied to a day
    var sameTimeLike: Bool { !period.isEmpty }
}

/// Skin routine logic: picking a template, ramp-ups, which products fall on which day, and conflicts between actives.
enum SkinRoutine {
    /// Templates ranked for a profile: skin type match first, then the concerns they cover.
    static func templates(for p: SkinProfile, content: SkincareContent) -> [SkinRoutineTemplate] {
        func score(_ t: SkinRoutineTemplate) -> Double {
            var s = 0.0
            if let st = p.skinType, t.skinTypes.contains(st) { s += 3 }
            let overlap = Set(t.concerns).intersection(p.concerns).count
            s += Double(overlap) * 2
            if t.concerns.isEmpty { s += 0.5 }
            return s
        }
        return content.routines.sorted { score($0) != score($1) ? score($0) > score($1) : $0.id < $1.id }.filter { score($0) > 0 }
    }

    /// Nights per week for a retinoid ramp-up, given whole weeks since it was started (week 1 = the first week).
    static func rampNights(weeksSinceStart: Int, ramp: [RampStep]) -> Int {
        guard !ramp.isEmpty else { return 7 }
        let week = max(1, weeksSinceStart + 1)
        return ramp.last(where: { $0.week <= week })?.nightsPerWeek ?? ramp[0].nightsPerWeek
    }

    /// The weekdays (1...7, Sunday = 1) a ramp-up uses for N nights a week, spread out.
    static func rampWeekdays(nights: Int) -> Set<Int> {
        switch min(7, max(1, nights)) {
        case 1: return [2]
        case 2: return [2, 5]
        case 3: return [2, 4, 6]
        case 4: return [2, 3, 5, 6]
        case 5: return [2, 3, 4, 5, 6]
        case 6: return [1, 2, 3, 4, 5, 6]
        default: return Set(1...7)
        }
    }

    static func weeks(from start: Date, to now: Date, calendar: Calendar = .current) -> Int {
        max(0, (calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0) / 7)
    }

    /// True when `product` is used in `period` on `weekday` (a retinoid ramp-up follows its week table).
    static func isUsed(_ product: SkinProduct, period: String, weekday: Int, now: Date, content: SkincareContent?, calendar: Calendar = .current) -> Bool {
        guard product.period == period || product.period == "both" else { return false }
        if product.frequency == "ramp-up" {
            let nights = rampNights(weeksSinceStart: weeks(from: product.startedAt, to: now, calendar: calendar), ramp: content?.rampUps["retinoid"] ?? [])
            return rampWeekdays(nights: nights).contains(weekday)
        }
        return product.weekdays.isEmpty || product.weekdays.contains(weekday)
    }

    /// Gentle warnings from the content's conflict rules. A sameTime rule fires when both actives fall in the same AM or PM session on any
    /// weekday; the others fire when both are in the routine at all. "*new_active" means two new actives started within two weeks.
    static func conflicts(products: [SkinProduct], content: SkincareContent, now: Date = Date(), calendar: Calendar = .current) -> [ConflictWarning] {
        var out: [ConflictWarning] = []
        func has(_ id: String) -> Bool { products.contains { $0.activeId == id } }
        let basics: Set<String> = ["sunscreen", "ceramides", "hyaluronic_acid", "centella", "peptides", "niacinamide"]
        for rule in content.conflicts {
            if rule.a == "*new_active" || rule.b == "*new_active" {
                let recent = products.filter { p in
                    guard let a = p.activeId, !basics.contains(a) else { return false }
                    return (calendar.dateComponents([.day], from: p.startedAt, to: now).day ?? 99) <= 14
                }
                if Set(recent.compactMap(\.activeId)).count >= 2 {
                    out.append(ConflictWarning(a: rule.a, b: rule.b, message: rule.message, severity: rule.severity, period: "", weekday: 0))
                }
                continue
            }
            guard has(rule.a), has(rule.b) else { continue }
            if !rule.sameTime {
                out.append(ConflictWarning(a: rule.a, b: rule.b, message: rule.message, severity: rule.severity, period: "", weekday: 0))
                continue
            }
            var hit: (String, Int)?
            search: for period in ["pm", "am"] {
                for weekday in 1...7 {
                    let used = products.filter { isUsed($0, period: period, weekday: weekday, now: now, content: content, calendar: calendar) }.compactMap(\.activeId)
                    if used.contains(rule.a) && used.contains(rule.b) { hit = (period, weekday); break search }
                }
            }
            if let (period, weekday) = hit {
                out.append(ConflictWarning(a: rule.a, b: rule.b, message: rule.message, severity: rule.severity, period: period, weekday: weekday))
            }
        }
        return out
    }
}
