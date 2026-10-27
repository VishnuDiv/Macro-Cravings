import Foundation

struct ProteinPowder: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var brand: String?
    var type: String              // whey_isolate | whey_blend | casein | whey_casein_blend | plant | egg | collagen | custom
    var flavors: [String]
    var scoopGrams: Double
    var perScoop: Nutrition
    var ingredientKey: String?
    var note: String?

    enum CodingKeys: String, CodingKey { case id, name, brand, type, flavors, scoopGrams, perScoop, ingredientKey, note }

    init(id: String, name: String, brand: String? = nil, type: String = "custom", flavors: [String] = [],
         scoopGrams: Double = 30, perScoop: Nutrition, ingredientKey: String? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.brand = brand; self.type = type; self.flavors = flavors
        self.scoopGrams = scoopGrams; self.perScoop = perScoop; self.ingredientKey = ingredientKey; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nm = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Protein powder"
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nm
        name = nm
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? nil
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? "whey_blend"
        flavors = (try? c.decodeIfPresent([String].self, forKey: .flavors)) ?? []
        let s = (try? c.decodeIfPresent(Double.self, forKey: .scoopGrams)) ?? 30
        scoopGrams = s > 0 ? s : 30
        perScoop = (try? c.decodeIfPresent(Nutrition.self, forKey: .perScoop)) ?? .zero
        ingredientKey = (try? c.decodeIfPresent(String.self, forKey: .ingredientKey)) ?? nil
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    static let typeOrder = ["custom", "whey_isolate", "whey_blend", "whey_casein_blend", "casein", "plant", "egg", "collagen"]

    static func typeTitle(_ t: String) -> String {
        switch t {
        case "whey_isolate": return "Whey isolate"
        case "whey_blend": return "Whey blend"
        case "casein": return "Casein"
        case "whey_casein_blend": return "Whey + casein blend"
        case "plant": return "Plant protein"
        case "egg": return "Egg white"
        case "collagen": return "Collagen"
        case "custom": return "My powders"
        default: return t.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
