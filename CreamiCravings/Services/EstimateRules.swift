import Foundation

/// A guessed amount for a line that has no grams, ml, count or catalog default (shown as "≈ 20 g · est.").
struct AmountEstimate: Equatable {
    var grams: Double
    var reason: String
}

/// Every rule that guesses an unknown amount lives in this one table-style file, so it is easy to tune.
/// Order of precedence: (1) text cues in the line ("to taste", "for frying", "to garnish"), (2) catalog category defaults.
/// A catalog `defaultGrams` is not an estimate: the calculator already treats it as the real amount.
/// Optional lines are never estimated (the caller skips them). Unknown categories stay at 0 and are reported as "not counted".
enum EstimateRules {
    // MARK: tunable numbers (grams unless noted)
    static let saltToTaste = 0.5
    static let pepperToTaste = 0.3
    static let spiceToTaste = 0.5
    static let garnish = 3.0                 // herbs, sesame seeds, scallions
    static let fatForCooking = 5.0           // oil or butter for frying, greasing, drizzling
    static let sprayOil = 1.0                // cooking spray
    static let spice = 1.0                   // spice / seasoning / flavoring by category
    static let herb = 3.0                    // produce named cilantro, parsley, mint, basil, dill, chives, scallion
    static let fat = 5.0                     // oil / butter / ghee by name
    static let sauce = 15.0                  // sauce / condiment
    static let cheeseOrSolidDairy = 20.0     // cheese, paneer, yogurt ...
    static let liquidDairyMl = 60.0          // milk, cream
    static let nutOrSeed = 10.0
    static let sweetener = 5.0               // sweetener / syrup
    static let produce = 50.0
    static let fruit = 50.0
    static let grainDry = 50.0               // rice, pasta, oats, noodles (dry weight)
    static let breadCountFallback = 45.0     // when the catalog has no gramsPerCount for bread / tortilla (1 piece)
    static let proteinPowder = 30.0          // one scoop

    private static let herbWords = ["cilantro", "coriander leaves", "parsley", "mint", "basil", "dill", "chives", "scallion", "green onion", "spring onion"]
    private static let garnishCarriers = herbWords + ["sesame", "seeds"]
    private static let fatWords = ["oil", "butter", "ghee", "margarine", "lard"]
    private static let cheeseWords = ["cheese", "paneer", "feta", "parmesan", "mozzarella", "cheddar", "halloumi", "ricotta", "mascarpone", "yogurt", "yoghurt", "curd", "labneh", "skyr"]
    private static let liquidDairyWords = ["milk", "cream", "half_and_half", "half and half", "kefir", "creamer"]
    private static let grainWords = ["rice", "pasta", "spaghetti", "penne", "macaroni", "noodle", "oats", "quinoa", "couscous", "orzo", "barley"]
    private static let breadWords = ["bread", "tortilla", "wrap", "naan", "roti", "pita", "bun", "bagel", "flatbread"]

    private static func has(_ text: String, _ words: [String]) -> Bool { words.contains { text.contains($0) } }

    /// Best guess for a line with no usable amount, or nil when the rules have nothing sensible to say.
    static func estimate(text: String, key: String?, info: IngredientInfo?) -> AmountEstimate? {
        guard let info else { return nil }
        let k = (key ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
        let name = info.name.lowercased()
        let id = k + " " + name                      // what the ingredient is
        let t = text.lowercased()
        let cat = info.category

        // (1) text cues -------------------------------------------------------------------------------------------
        if t.contains("to taste") || t.contains("pinch") || t.contains("dash") {
            if has(id, ["salt"]) { return AmountEstimate(grams: saltToTaste, reason: "salt to taste") }
            if has(id, ["pepper"]) && cat == "spice" { return AmountEstimate(grams: pepperToTaste, reason: "pepper to taste") }
            if cat == "spice" || cat == "flavoring" { return AmountEstimate(grams: spiceToTaste, reason: "seasoning to taste") }
        }
        if t.contains("garnish") || t.contains("to serve") || t.contains("for serving") {
            if has(id, garnishCarriers) { return AmountEstimate(grams: garnish, reason: "garnish") }
        }
        if has(id, fatWords) || id.contains("spray") {
            if t.contains("spray") || id.contains("spray") { return AmountEstimate(grams: sprayOil, reason: "cooking spray") }
            if t.contains("for frying") || t.contains("for cooking") || t.contains("for greasing") || t.contains("drizzle") || t.contains("for the pan") {
                return AmountEstimate(grams: fatForCooking, reason: "oil or butter for the pan")
            }
        }

        // (2) catalog category defaults ---------------------------------------------------------------------------
        switch cat {
        case "spice", "flavoring": return AmountEstimate(grams: spice, reason: "typical seasoning amount")
        case "sauce": return AmountEstimate(grams: sauce, reason: "typical sauce / condiment amount")
        case "nut": return AmountEstimate(grams: nutOrSeed, reason: "typical handful of nuts or seeds")
        case "sweetener": return AmountEstimate(grams: sweetener, reason: "typical sweetener amount")
        case "protein_powder": return AmountEstimate(grams: proteinPowder, reason: "one scoop")
        case "fruit": return AmountEstimate(grams: fruit, reason: "typical fruit amount")
        case "milk", "plant_milk", "ultra_filtered": return AmountEstimate(grams: liquidDairyMl * (info.gramsPerMl ?? 1.0), reason: "about 60 ml")
        case "dairy":
            if has(id, cheeseWords) { return AmountEstimate(grams: cheeseOrSolidDairy, reason: "typical cheese / dairy amount") }
            if has(id, liquidDairyWords) { return AmountEstimate(grams: liquidDairyMl * (info.gramsPerMl ?? 1.03), reason: "about 60 ml") }
            return AmountEstimate(grams: cheeseOrSolidDairy, reason: "typical dairy amount")
        case "produce":
            if has(id, herbWords) { return AmountEstimate(grams: herb, reason: "typical herb amount") }
            return AmountEstimate(grams: produce, reason: "typical vegetable amount")
        default: break
        }
        if has(id, fatWords) { return AmountEstimate(grams: fat, reason: "typical oil / butter amount") }
        if has(id, breadWords) { return AmountEstimate(grams: info.gramsPerCount ?? breadCountFallback, reason: "one piece") }
        if has(id, grainWords) { return AmountEstimate(grams: grainDry, reason: "typical dry grain / pasta amount") }
        return nil                                    // mix_in_choice, unknown categories: stays "not counted"
    }
}
