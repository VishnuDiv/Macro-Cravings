import Foundation

/// The user's yogurt: "My Greek yogurt" in Settings (0% by default).
enum GreekYogurtPref: String, Codable, CaseIterable, Identifiable {
    case zero, twoPercent, full, asWritten
    var id: String { rawValue }
    var title: String {
        switch self {
        case .zero: return "0%"
        case .twoPercent: return "2%"
        case .full: return "Full-fat"
        case .asWritten: return "As written"
        }
    }
    /// "0% Greek yogurt", used in the "using ..." note on a line.
    var label: String { self == .asWritten ? "" : (self == .full ? "full-fat Greek yogurt" : "\(title) Greek yogurt") }
}

/// Which lines the picker changes, and to what. Only Greek yogurt and skyr variants with more than 1 g fat per 100 g are touched:
/// never regular yogurt, curd, labneh or quark, and never a line that already is nonfat.
enum YogurtRules {
    static let fatThreshold = 1.0

    static func isVariant(_ key: String?, catalog: Catalog) -> Bool {
        guard let key, key.hasPrefix("greek_yogurt") || key.hasPrefix("skyr"), let info = catalog.info(key) else { return false }
        return info.per100g.fat > fatThreshold
    }

    /// The catalog key a line is shown and computed as, or nil to leave it alone.
    static func target(pref: GreekYogurtPref, key: String?, catalog: Catalog) -> String? {
        guard pref != .asWritten, let key, isVariant(key, catalog: catalog) else { return nil }
        let isSkyr = key.hasPrefix("skyr")
        let t: String?
        switch pref {
        case .zero: t = isSkyr ? "skyr_plain" : "greek_yogurt_nonfat"
        case .twoPercent: t = isSkyr ? nil : "greek_yogurt_2pct"
        case .full: t = isSkyr ? nil : "greek_yogurt_full"
        case .asWritten: t = nil
        }
        guard let t, t != key, catalog.info(t) != nil else { return nil }
        return t
    }
}
