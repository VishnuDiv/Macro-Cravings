import Foundation

struct BaseLiquid: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var family: String            // milk | ultra_filtered | plant | protein_shake
    var brand: String?
    var servingMl: Double
    var perServing: Nutrition
    var gramsPerMl: Double
    var ingredientKey: String?
    var note: String?

    enum CodingKeys: String, CodingKey { case id, name, family, brand, servingMl, perServing, gramsPerMl, ingredientKey, note }

    init(id: String, name: String, family: String, brand: String? = nil, servingMl: Double = 240,
         perServing: Nutrition, gramsPerMl: Double = 1.03, ingredientKey: String? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.family = family; self.brand = brand; self.servingMl = servingMl
        self.perServing = perServing; self.gramsPerMl = gramsPerMl; self.ingredientKey = ingredientKey; self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nm = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Milk"
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nm
        name = nm
        family = (try? c.decodeIfPresent(String.self, forKey: .family)) ?? "milk"
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? nil
        let s = (try? c.decodeIfPresent(Double.self, forKey: .servingMl)) ?? 240
        servingMl = s > 0 ? s : 240
        perServing = (try? c.decodeIfPresent(Nutrition.self, forKey: .perServing)) ?? .zero
        let g = (try? c.decodeIfPresent(Double.self, forKey: .gramsPerMl)) ?? 1.03
        gramsPerMl = g > 0 ? g : 1.03
        ingredientKey = (try? c.decodeIfPresent(String.self, forKey: .ingredientKey)) ?? nil
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    static func familyTitle(_ f: String) -> String {
        switch f {
        case "milk": return "Milk"
        case "ultra_filtered": return "Ultra-filtered"
        case "plant": return "Plant milk"
        case "protein_shake": return "Protein shakes"
        case "custom": return "My milks"
        default: return f.capitalized
        }
    }
}
