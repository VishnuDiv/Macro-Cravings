import Foundation

/// Derives a "vegan" flag for catalog entries and a vegan status for recipes. Display and filtering only: it never changes
/// swaps, alternatives, their order or any nutrition.
enum VeganRules {
    // MARK: tunable word lists
    private static let alwaysAnimal = ["honey", "whey", "casein", "collagen", "gelatin", "gelatine", "ghee", "paneer", "curd", "labneh", "kefir", "skyr", "lard", "tallow"]
    private static let eggWords = ["egg", "eggs"]                                         // whole words (eggplant is fine)
    private static let cheeseWords = ["cheese", "parmesan", "mozzarella", "cheddar", "feta", "ricotta", "mascarpone", "halloumi", "gouda", "brie", "provolone", "gruyere", "pecorino"]
    private static let plantQualifiers = ["vegan", "plant", "almond", "oat", "soy", "cashew", "coconut", "rice", "hemp", "pea", "nut", "nutritional"]
    private static let butterNotDairy = ["peanut", "almond", "cashew", "nut", "seed", "cocoa", "apple", "sunflower", "pumpkin", "hazelnut", "pistachio", "coconut", "shea", "soy",
                                         "sesame", "cookie", "biscoff", "tahini", "vegan", "plant", "dairy free", "fruit"]
    private static let creamNotDairy = ["tartar", "coconut", "cashew", "oat", "almond", "soy", "plant", "vegan", "hemp", "rice"]
    private static let nonVeganPowderTypes: Set<String> = ["whey_isolate", "whey_blend", "casein", "whey_casein_blend", "egg", "collagen"]

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Explicit overrides first, then the derivation rules. `powders` are used for protein_powder_* entries.
    static func isVegan(key: String, info: IngredientInfo, powders: [ProteinPowder]) -> Bool {
        if let o = info.veganOverride { return o }
        let k = key.lowercased()
        // obvious overrides
        if k.hasPrefix("vegan_") || k.hasPrefix("vegan") && k.contains("_") { return true }
        if k == "honey" || k.hasSuffix("_honey") { return false }
        if ["tofu", "tempeh", "seitan"].contains(where: { k.contains($0) }) || k.contains("soy_chunks") { return true }

        if info.vegetarian != .yes { return false }
        if info.allergens.contains("dairy") || info.allergens.contains("egg") { return false }

        let name = info.name.lowercased()
        let words = Set(tokens(k) + tokens(name))
        let plant = !words.isDisjoint(with: plantQualifiers)

        if !alwaysAnimal.filter({ w in words.contains(w) || name.contains(w) || k.contains(w) }).isEmpty {
            if words.contains("vegan") || words.contains("plant") { return true }
            // "honey" in "honey mustard" is still honey; "butter" is handled below
            return false
        }
        if !words.isDisjoint(with: eggWords) && !words.contains("vegan") { return false }
        if cheeseWords.contains(where: { name.contains($0) || k.contains($0) }) && !plant { return false }
        if (words.contains("yogurt") || words.contains("yoghurt")) && !plant { return false }
        if words.contains("mayonnaise") && !words.contains("vegan") { return false }
        if words.contains("butter") && butterNotDairy.allSatisfy({ !(name.contains($0) || k.contains($0)) }) { return false }
        if words.contains("cream") && creamNotDairy.allSatisfy({ !(name.contains($0) || k.contains($0)) }) { return false }
        if words.contains("milk") && !plant { return false }
        if k.hasPrefix("protein_powder"), let p = powders.first(where: { $0.ingredientKey == key }) {
            return !nonVeganPowderTypes.contains(p.type)
        }
        return true
    }

    /// Vegan status of a displayed recipe version. Every non-optional line must resolve to a vegan catalog entry. A line the
    /// catalog does not know makes the recipe vegan only when its tags include "vegan" (and no resolved line is non-vegan).
    /// `lines`: the effective ingredient keys (nil key = unknown); omitted lines ("leave it out") are skipped by the caller.
    static func recipeIsVegan(keys: [String?], tags: [String], catalog: Catalog) -> Bool {
        var unknown = false
        for k in keys {
            guard let k, let v = catalog.isVegan(k) else { unknown = true; continue }
            if !v { return false }
        }
        return !unknown || tags.contains("vegan")
    }

    /// Vegan status of a recipe version given as a Recipe (its non-optional lines).
    static func isVegan(_ r: Recipe, catalog: Catalog) -> Bool {
        recipeIsVegan(keys: r.allIngredients.filter { !$0.optional }.map(\.key), tags: r.tags, catalog: catalog)
    }

    /// For the stable list badge and filter: the recipe as written, or its default vegetarian version.
    static func isVeganForLists(_ r: Recipe, catalog: Catalog) -> Bool {
        if isVegan(r, catalog: catalog) { return true }
        return r.vegAdaptation != nil && isVegan(r.vegVersion(), catalog: catalog)
    }
}
