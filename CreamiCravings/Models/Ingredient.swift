import Foundation

/// One ingredient line of a recipe.
struct Ing: Codable, Hashable {
    var text: String
    var key: String?
    var grams: Double?
    var ml: Double?
    var count: Double?
    var optional: Bool

    enum CodingKeys: String, CodingKey { case text, key, grams, ml, count, optional }

    init(text: String, key: String? = nil, grams: Double? = nil, ml: Double? = nil, count: Double? = nil, optional: Bool = false) {
        self.text = text; self.key = key; self.grams = grams; self.ml = ml; self.count = count; self.optional = optional
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        let k = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil
        key = (k?.isEmpty == false) ? k : nil
        grams = (try? c.decodeIfPresent(Double.self, forKey: .grams)) ?? nil
        ml = (try? c.decodeIfPresent(Double.self, forKey: .ml)) ?? nil
        count = (try? c.decodeIfPresent(Double.self, forKey: .count)) ?? nil
        optional = (try? c.decodeIfPresent(Bool.self, forKey: .optional)) ?? false
    }
}

struct Affiliate: Codable, Hashable {
    var brand: String
    var note: String?

    enum CodingKeys: String, CodingKey { case brand, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? "Affiliate"
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }
}

struct SwapOption: Codable, Hashable {
    var name: String
    var key: String?
    var ratio: Double
    var note: String?

    enum CodingKeys: String, CodingKey { case name, key, ratio, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Alternative"
        key = (try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil
        ratio = (try? c.decodeIfPresent(Double.self, forKey: .ratio)) ?? 1
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }
}

/// Catalog vegetarian flag: JSON true / false / "check"; absent means yes.
enum VegFlag: String, Codable, Hashable {
    case yes, no, check
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = b ? .yes : .no; return }
        if let s = try? c.decode(String.self) {
            switch s.lowercased() {
            case "true", "yes": self = .yes
            case "false", "no": self = .no
            default: self = .check
            }
            return
        }
        self = .yes
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .yes: try c.encode(true); case .no: try c.encode(false); case .check: try c.encode("check") }
    }
}

/// Catalog entry (Resources/ingredients.json value).
struct IngredientInfo: Codable, Hashable {
    var name: String
    var category: String
    var per100g: Nutrition
    var gramsPerCount: Double?
    var gramsPerMl: Double?
    var defaultGrams: Double?
    var affiliate: Affiliate?
    var storeAlternative: String?
    var homemadeAlternative: String?
    var swaps: [SwapOption]
    var pantryStaple: Bool
    var allergens: [String]
    var vegetarian: VegFlag
    var vegNote: String?
    var veganOverride: Bool?        // explicit "vegan": true/false in the catalog entry

    enum CodingKeys: String, CodingKey {
        case vegetarian, vegNote
        case veganOverride = "vegan"
        case name, category, per100g, gramsPerCount, gramsPerMl, defaultGrams, affiliate
        case storeAlternative, homemadeAlternative, swaps, pantryStaple, allergens
    }

    init(name: String, category: String = "other", per100g: Nutrition = .zero) {
        self.name = name; self.category = category; self.per100g = per100g
        swaps = []; pantryStaple = false; allergens = []; vegetarian = .yes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? "other"
        per100g = (try? c.decodeIfPresent(Nutrition.self, forKey: .per100g)) ?? .zero
        gramsPerCount = (try? c.decodeIfPresent(Double.self, forKey: .gramsPerCount)) ?? nil
        gramsPerMl = (try? c.decodeIfPresent(Double.self, forKey: .gramsPerMl)) ?? nil
        defaultGrams = (try? c.decodeIfPresent(Double.self, forKey: .defaultGrams)) ?? nil
        affiliate = (try? c.decodeIfPresent(Affiliate.self, forKey: .affiliate)) ?? nil
        storeAlternative = (try? c.decodeIfPresent(String.self, forKey: .storeAlternative)) ?? nil
        homemadeAlternative = (try? c.decodeIfPresent(String.self, forKey: .homemadeAlternative)) ?? nil
        swaps = (try? c.decodeIfPresent([SwapOption].self, forKey: .swaps)) ?? []
        pantryStaple = (try? c.decodeIfPresent(Bool.self, forKey: .pantryStaple)) ?? false
        allergens = (try? c.decodeIfPresent([String].self, forKey: .allergens)) ?? []
        vegetarian = (try? c.decodeIfPresent(VegFlag.self, forKey: .vegetarian)) ?? .yes
        vegNote = (try? c.decodeIfPresent(String.self, forKey: .vegNote)) ?? nil
        veganOverride = (try? c.decodeIfPresent(Bool.self, forKey: .veganOverride)) ?? nil
    }
}

enum IngCategory {
    static let liquidBase: Set<String> = ["milk", "protein_shake", "plant_milk", "ultra_filtered"]
    /// Display order for shopping list sections.
    static let order = ["milk", "ultra_filtered", "protein_shake", "plant_milk", "dairy", "sweetener", "stabilizer", "flavoring", "cocoa", "fruit", "mix_in", "sauce", "nut", "spice", "alcohol", "other"]

    static func title(_ c: String) -> String {
        switch c {
        case "milk": return "Milk"
        case "ultra_filtered": return "Ultra-filtered milk"
        case "protein_shake": return "Protein shakes"
        case "plant_milk": return "Plant milk"
        case "dairy": return "Dairy"
        case "sweetener": return "Sweeteners"
        case "stabilizer": return "Stabilizers"
        case "flavoring": return "Flavorings"
        case "cocoa": return "Cocoa"
        case "fruit": return "Fruit"
        case "mix_in": return "Mix-ins"
        case "sauce": return "Sauces"
        case "nut": return "Nuts"
        case "spice": return "Spices"
        case "alcohol": return "Alcohol"
        default: return "Other"
        }
    }
}
