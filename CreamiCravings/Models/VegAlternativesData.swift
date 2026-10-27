import Foundation

/// One ranked vegetarian alternative inside a role.
struct VegAlt: Codable, Hashable {
    var key: String
    var name: String
    var availability: String          // everywhere | most_stores | specialty
    var whereToBuy: String?
    var brands: String?
    var per100g: Nutrition
    var prep: String?
    var textureMatch: Int?
    var why: String?
    var aliasKeys: [String]           // old key names used by vegAdaptation swaps

    enum CodingKeys: String, CodingKey { case key, name, availability, whereToBuy, brands, per100g, prep, textureMatch, why, aliasKeys }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        availability = (try? c.decodeIfPresent(String.self, forKey: .availability)) ?? "most_stores"
        whereToBuy = (try? c.decodeIfPresent(String.self, forKey: .whereToBuy)) ?? nil
        brands = (try? c.decodeIfPresent(String.self, forKey: .brands)) ?? nil
        per100g = (try? c.decodeIfPresent(Nutrition.self, forKey: .per100g)) ?? .zero
        prep = (try? c.decodeIfPresent(String.self, forKey: .prep)) ?? nil
        textureMatch = (try? c.decodeIfPresent(Int.self, forKey: .textureMatch)) ?? nil
        why = (try? c.decodeIfPresent(String.self, forKey: .why)) ?? nil
        aliasKeys = (try? c.decodeIfPresent([String].self, forKey: .aliasKeys)) ?? []
    }

    var availabilityTitle: String {
        switch availability {
        case "everywhere": return "Everywhere"
        case "specialty": return "Specialty"
        default: return "Most stores"
        }
    }
}

struct VegRole: Codable, Hashable {
    var label: String
    var matchKeys: [String]
    var keywords: [String]
    var meatPer100g: Nutrition?
    var alternatives: [VegAlt]

    enum CodingKeys: String, CodingKey { case label, matchKeys, keywords, meatPer100g, alternatives }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? ""
        matchKeys = (try? c.decodeIfPresent([String].self, forKey: .matchKeys)) ?? []
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        meatPer100g = (try? c.decodeIfPresent(Nutrition.self, forKey: .meatPer100g)) ?? nil
        alternatives = decodeLenientArray(from: c, key: .alternatives)
    }
}

struct VegAlternativesData: Codable, Hashable {
    var roles: [String: VegRole]
    var keyToRole: [String: String]
    var upgrades: [String: UpgradeRole]

    enum CodingKeys: String, CodingKey { case roles, keyToRole, upgrades }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let boxes = (try? c.decodeIfPresent([String: LenientBox<VegRole>].self, forKey: .roles)) ?? nil
        roles = (boxes ?? [:]).compactMapValues { $0.v }
        keyToRole = (try? c.decodeIfPresent([String: String].self, forKey: .keyToRole)) ?? [:]
        let ups = (try? c.decodeIfPresent([String: LenientBox<UpgradeRole>].self, forKey: .upgrades)) ?? nil
        upgrades = (ups ?? [:]).compactMapValues { $0.v }
    }

    private static func padded(_ text: String) -> String {
        " " + text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined().split(separator: " ").joined(separator: " ") + " "
    }

    /// Longest role keyword found in `text` as a whole word or phrase (optional plural s); 0 when none.
    private func keywordScore(_ role: VegRole, in padded: String) -> Int {
        role.keywords.map { k -> Int in
            let w = VegAlternativesData.padded(k).trimmingCharacters(in: .whitespaces)
            return (padded.contains(" \(w) ") || padded.contains(" \(w)s ")) ? w.count : 0
        }.max() ?? 0
    }

    private func bestRole(in text: String) -> [(id: String, score: Int)] {
        let p = VegAlternativesData.padded(text)
        return roles.map { ($0.key, keywordScore($0.value, in: p)) }.filter { $0.1 > 0 }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
    }

    private static func family(_ id: String) -> String { String(id.split(separator: "_").first ?? "") }

    /// Role for an original line. Role keywords are checked first (recipe name, then line text), then keyToRole, then matchKeys.
    /// A keyword role from a different food family than the line's own key role (bacon line in a "burger") is ignored.
    func role(forKey key: String?, text: String, recipeName: String = "") -> (id: String, role: VegRole)? {
        var keyed: String?
        if let key, let id = keyToRole[key], roles[id] != nil { keyed = id }
        else if let key, let hit = roles.first(where: { $0.value.matchKeys.contains(key) }) { keyed = hit.key }
        func compatible(_ id: String) -> Bool { keyed.map { VegAlternativesData.family($0) == VegAlternativesData.family(id) } ?? true }
        if !recipeName.isEmpty, let hit = bestRole(in: recipeName).first(where: { compatible($0.id) }) { return (hit.id, roles[hit.id]!) }
        if let hit = bestRole(in: text).first(where: { compatible($0.id) }) { return (hit.id, roles[hit.id]!) }
        if let keyed { return (keyed, roles[keyed]!) }
        return nil
    }
}

/// "Protein upgrade" for wings and crispy bites: swap the vegetable base (cauliflower, chickpeas ...) for a protein at the same weight.
struct UpgradeRole: Codable, Hashable {
    var label: String
    var baseKeys: [String]
    var keywords: [String]
    var basePer100g: Nutrition
    var alternatives: [VegAlt]

    enum CodingKeys: String, CodingKey { case label, baseKeys, keywords, basePer100g, alternatives }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? "Protein upgrade"
        baseKeys = (try? c.decodeIfPresent([String].self, forKey: .baseKeys)) ?? []
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        basePer100g = (try? c.decodeIfPresent(Nutrition.self, forKey: .basePer100g)) ?? .zero
        alternatives = decodeLenientArray(from: c, key: .alternatives)
    }
}

/// Build-time mark on a recipe: which role applies and which `base` line is the wing base.
struct ProteinUpgradeRef: Codable, Hashable {
    var role: String
    var lineIndex: Int
}
