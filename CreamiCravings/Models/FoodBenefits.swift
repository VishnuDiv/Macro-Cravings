import Foundation

/// What a food is "good for". Data: Resources/food_benefits.json (a content file; its "_schema" key describes the shape).
enum Benefit: String, Codable, CaseIterable, Identifiable {
    case gut, skin, hair, muscle, heart, energy, bones
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .gut: return "leaf.fill"; case .skin: return "sparkles"; case .hair: return "comb.fill"; case .muscle: return "dumbbell.fill"
        case .heart: return "heart.fill"; case .energy: return "bolt.fill"; case .bones: return "figure.stand"
        }
    }
    /// "Why it's good for your skin"
    var sheetTitle: String {
        switch self {
        case .gut: return "Why it's good for your gut"; case .skin: return "Why it's good for your skin"; case .hair: return "Why it's good for your hair"
        case .muscle: return "Why it's good for your muscles"; case .heart: return "Why it's good for your heart"
        case .energy: return "Why it gives you energy"; case .bones: return "Why it's good for your bones"
        }
    }
}

/// Minimal JSON value, for the rules' free-form "when" conditions.
enum JSONAny: Decodable, Hashable {
    case number(Double), string(String), bool(Bool), array([JSONAny]), object([String: JSONAny]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONAny].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONAny].self) { self = .object(o) }
        else { self = .null }
    }
    var number: Double? { if case .number(let d) = self { return d }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var strings: [String] { if case .array(let a) = self { return a.compactMap(\.string) }; return [] }
    var object: [String: JSONAny] { if case .object(let o) = self { return o }; return [:] }
}

struct BenefitEntry: Decodable, Hashable {
    var benefits: [String]
    var why: String
    var minGrams: Double?                   // grams per serving needed to count (spices 1-3)
    var tags: [String]                      // fermented, legume, omega3, vitamin_c, plant, dairy ...
    enum CodingKeys: String, CodingKey { case benefits, why, minGrams, tags }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        benefits = (try? c.decode([String].self, forKey: .benefits)) ?? []
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
        minGrams = (try? c.decodeIfPresent(Double.self, forKey: .minGrams)) ?? nil
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }
}

/// A rule over a whole recipe. `when` conditions are ANDed, all per serving: fiber_g, protein_g, sugar_g, kcal, proteinPer100kcal as {op: value}
/// (op >= or <=); hasTag; allTags; tagGrams {tag: {op: grams}}; distinctPlantTagged {op: n}. satFatShare is skipped (the catalog has no saturated fat).
struct BenefitRule: Decodable, Hashable {
    var id: String
    var when: [String: JSONAny]
    var benefits: [String]
    var weight: Double
    var why: String
    enum CodingKeys: String, CodingKey { case id, when, benefits, weight, why }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        when = (try? c.decode([String: JSONAny].self, forKey: .when)) ?? [:]
        benefits = (try? c.decode([String].self, forKey: .benefits)) ?? []
        weight = (try? c.decode(Double.self, forKey: .weight)) ?? 1
        why = (try? c.decode(String.self, forKey: .why)) ?? ""
    }
}

struct FoodBenefits: Decodable {
    var ingredientBenefits: [String: BenefitEntry]
    var rules: [BenefitRule]
    var defaultMinGrams: Double
    var spiceMinGrams: Double
    var maxChips = 4
    enum CodingKeys: String, CodingKey { case ingredientBenefits, rules, defaultMinGrams, spiceMinGrams, _schema }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let e = (try? c.decodeIfPresent([String: LenientBox<BenefitEntry>].self, forKey: .ingredientBenefits)) ?? nil
        ingredientBenefits = (e ?? [:]).compactMapValues { $0.v }
        rules = decodeLenientArray(from: c, key: .rules)
        let schema = (try? c.decode([String: JSONAny].self, forKey: ._schema)) ?? [:]
        defaultMinGrams = (try? c.decode(Double.self, forKey: .defaultMinGrams)) ?? schema["defaultMinGrams"]?.number ?? 10
        spiceMinGrams = (try? c.decode(Double.self, forKey: .spiceMinGrams)) ?? schema["spiceMinGrams"]?.number ?? 1
    }
}
