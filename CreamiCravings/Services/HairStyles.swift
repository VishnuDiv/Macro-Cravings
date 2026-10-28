import Foundation

struct StyleMatch: Identifiable {
    var style: HairStyle
    var score: Double
    var reasons: [String]
    var id: String { style.id }
}

enum HairStyles {
    /// Styles ranked for a profile. Face shape, hair type and length add points; a style that only works up to a Norwood stage below the
    /// user's is left out; styles that are "great" for a receding hairline rank higher when that is a concern, "avoid" ones are dropped.
    static func rank(_ p: HairProfile, content: HaircareContent) -> [StyleMatch] {
        let receding = p.concerns.contains("receding_hairline") || (p.norwood ?? 1) >= 2
        var out: [StyleMatch] = []
        for s in content.styles {
            if let n = p.norwood, n > s.norwoodMax { continue }
            if receding && s.receding == "avoid" { continue }
            var score = 0.0
            var why: [String] = []
            if let f = p.faceShape, s.faceShapes.contains(f) { score += 3; why.append("suits a \(f) face") }
            if let t = p.hairType, s.hairTypes.contains(t) { score += 2; why.append("works with \(t) hair") }
            if let l = p.length, s.lengths.contains(l) { score += 1; why.append("fits \(l) hair") }
            if receding && s.receding == "great" { score += 2; why.append("great for a receding hairline") }
            if p.faceShape != nil && !s.faceShapes.contains(p.faceShape ?? "") && p.hairType != nil && !s.hairTypes.contains(p.hairType ?? "") { continue }
            if score > 0 { out.append(StyleMatch(style: s, score: score, reasons: why)) }
        }
        return out.sorted { $0.score != $1.score ? $0.score > $1.score : $0.style.id < $1.style.id }
    }
}

/// When a recurring item (hair routine items, photo series) is due. Shared by hair routine items and photo schedules.
enum Cadence {
    /// daily | every-2-days | 2x-week | weekly, counted from `start`.
    static func isDue(_ schedule: String, start: Date, on day: Date, calendar: Calendar = .current) -> Bool {
        let d0 = calendar.startOfDay(for: start), d1 = calendar.startOfDay(for: day)
        let days = calendar.dateComponents([.day], from: d0, to: d1).day ?? 0
        guard days >= 0 else { return false }
        switch schedule {
        case "every-2-days": return days % 2 == 0
        case "weekly": return days % 7 == 0
        case "2x-week": return days % 7 == 0 || days % 7 == 3
        default: return true
        }
    }
}
