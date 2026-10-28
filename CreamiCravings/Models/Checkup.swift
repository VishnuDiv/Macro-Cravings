import Foundation

// AI check-up result types (HEALTH_SPEC §10b). They mirror CheckupSchema field for field; sections the user did not ask for are null.

struct CheckupObservation: Codable, Hashable {
    var area: String
    var finding: String
    var severity: String          // none | mild | moderate | severe
    var confidence: String        // low | medium | high
    var severityRank: Int { ["none": 0, "mild": 1, "moderate": 2, "severe": 3][severity] ?? 0 }
}

struct CheckupSkinRec: Codable, Hashable {
    var action: String
    var activeId: String?
    var frequency: String
    var why: String
    var priority: String          // high | medium | low
}

struct CheckupHairRec: Codable, Hashable {
    var action: String
    var interventionId: String?
    var why: String
    var priority: String
}

struct CheckupSkin: Codable, Hashable {
    var observations: [CheckupObservation]
    var likelyDrivers: [String]
    var recommendations: [CheckupSkinRec]
    var avoid: [String]
}

struct CheckupHair: Codable, Hashable {
    var norwoodEstimate: String
    var observations: [CheckupObservation]
    var recommendations: [CheckupHairRec]
    var styleIds: [String]
}

struct CheckupResult: Codable, Hashable {
    struct Overall: Codable, Hashable { var summary: String; var nextCheckupWeeks: Int }
    struct Quality: Codable, Hashable { var ok: Bool; var issues: [String] }
    struct Derm: Codable, Hashable { var recommended: Bool; var reason: String }
    var overall: Overall
    var photoQuality: Quality
    var skin: CheckupSkin?
    var hair: CheckupHair?
    var seeDermatologist: Derm
}

/// Token counts reported by the API (summed over a retry).
struct CheckupUsage: Codable, Hashable {
    var inputTokens = 0
    var outputTokens = 0
    static func + (a: CheckupUsage, b: CheckupUsage) -> CheckupUsage { CheckupUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens) }
}

/// "2026-10-27" in the user's calendar.
func isoDay(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: d)
}

enum CheckupPricing {
    /// Claude Opus 5.5: $4 per million input tokens, $20 per million output tokens.
    static let inputPerMTok = 4.0
    static let outputPerMTok = 20.0
    static func cost(_ u: CheckupUsage) -> Double { (Double(u.inputTokens) * inputPerMTok + Double(u.outputTokens) * outputPerMTok) / 1_000_000 }
    static func label(_ cost: Double) -> String { "≈ $" + String(format: "%.2f", cost) }
}

struct CheckupPhotoRef: Codable, Hashable {
    var entryId: UUID
    var series: PhotoSeries
    var date: Date
}

/// A saved check-up: the JSON result, the photos it used (ids only), the date and the cost.
struct CheckupRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var scope: String              // skin | hair | both
    var result: CheckupResult
    var photos: [CheckupPhotoRef]
    var usage: CheckupUsage
    var cost: Double
    var effort: String             // high, or medium after a max_tokens retry

    /// One line for the "previous check-up summary" in the next request.
    var summaryLine: String { "\(isoDay(date)): \(result.overall.summary)" }
}
