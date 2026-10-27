import Foundation

/// "What it is" / "For you" note for a catalog ingredient (data/catalog/clarity_notes.json). Display only: it never changes macros.
struct IngredientNote: Codable, Hashable {
    var what: String
    var forYou: String?
    enum CodingKeys: String, CodingKey { case what, forYou }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        what = (try? c.decodeIfPresent(String.self, forKey: .what)) ?? ""
        forYou = (try? c.decodeIfPresent(String.self, forKey: .forYou)) ?? nil
    }
}

/// A display rewrite for ingredient text, e.g. "tomato puree" -> "tomato puree (tomato paste)".
struct TextRule: Codable, Hashable {
    var match: String
    var display: String
    var note: String?
    var category: String?
    enum CodingKeys: String, CodingKey { case match, display, note, category }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = try c.decode(String.self, forKey: .match)
        display = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? "$0"
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
        category = (try? c.decodeIfPresent(String.self, forKey: .category)) ?? nil
    }
}

struct ClarityNotes: Codable {
    var ingredientNotes: [String: IngredientNote]
    var textRules: [TextRule]
    enum CodingKeys: String, CodingKey { case ingredientNotes, textRules }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let notes = (try? c.decodeIfPresent([String: LenientBox<IngredientNote>].self, forKey: .ingredientNotes)) ?? nil
        ingredientNotes = (notes ?? [:]).compactMapValues { $0.v }
        textRules = decodeLenientArray(from: c, key: .textRules)
    }
}
