import Foundation

struct BenefitReason: Hashable {
    var title: String        // ingredient name or rule label
    var why: String
}

struct BenefitResult: Identifiable, Hashable {
    var benefit: Benefit
    var score: Double
    var reasons: [BenefitReason]
    var id: String { benefit.rawValue }
}

/// "Good for" tags for a recipe: rule weights plus 1 for each contributing ingredient, ranked best first.
enum BenefitEngine {
    private static func compare(_ op: String, _ value: Double, _ limit: Double) -> Bool {
        switch op { case ">=": return value >= limit; case "<=": return value <= limit; case ">": return value > limit; case "<": return value < limit; case "==": return value == limit; default: return true }
    }
    private static func conditions(_ j: JSONAny?, _ value: Double) -> Bool {
        guard let j else { return true }
        return j.object.allSatisfy { compare($0.key, value, $0.value.number ?? 0) }
    }

    /// `perServing` are the recipe's macros for one serving (nil: the nutrient rules cannot be checked and are skipped).
    static func compute(_ r: Recipe, perServing: Nutrition?, catalog: Catalog) -> [BenefitResult] {
        guard let fb = catalog.foodBenefits else { return [] }
        let calc = NutritionCalculator(catalog: catalog)
        let servings = r.perServingDivisor
        var scores: [Benefit: Double] = [:]
        var reasons: [Benefit: [BenefitReason]] = [:]
        func add(_ b: String, _ s: Double, _ reason: BenefitReason) {
            guard let benefit = Benefit(rawValue: b) else { return }
            scores[benefit, default: 0] += s
            if !reasons[benefit, default: []].contains(reason) { reasons[benefit, default: []].append(reason) }
        }

        // ingredients that count: non-optional, with a catalog entry here, and enough grams per serving
        struct Counted { var name: String; var entry: BenefitEntry; var grams: Double }
        var counted: [Counted] = []
        for ing in r.allIngredients where !ing.optional {
            guard let key = ing.key, let entry = fb.ingredientBenefits[key] else { continue }
            let info = catalog.info(key)
            let g = calc.grams(ing, info) / servings
            let minimum = entry.minGrams ?? ((info?.category == "spice") ? fb.spiceMinGrams : fb.defaultMinGrams)
            guard g >= minimum else { continue }
            counted.append(Counted(name: info?.name ?? key.replacingOccurrences(of: "_", with: " ").capitalized, entry: entry, grams: g))
        }
        for c in counted { for b in c.entry.benefits { add(b, 1, BenefitReason(title: c.name, why: c.entry.why)) } }

        for rule in fb.rules {
            var ok = true
            var fiber = 0.0, protein = 0.0
            if let n = perServing {
                fiber = n.fiber; protein = n.protein
                ok = ok && conditions(rule.when["fiber_g"], n.fiber) && conditions(rule.when["protein_g"], n.protein)
                    && conditions(rule.when["sugar_g"], n.sugar) && conditions(rule.when["kcal"], n.calories)
                    && conditions(rule.when["proteinPer100kcal"], n.calories > 0 ? n.protein / n.calories * 100 : 0)
            } else if ["fiber_g", "protein_g", "sugar_g", "kcal", "proteinPer100kcal"].contains(where: { rule.when[$0] != nil }) {
                ok = false
            }
            // satFatShare is skipped: the catalog has no saturated fat
            if let t = rule.when["hasTag"]?.string { ok = ok && counted.contains { $0.entry.tags.contains(t) } }
            if let tags = rule.when["allTags"]?.strings, !tags.isEmpty { ok = ok && tags.allSatisfy { t in counted.contains { $0.entry.tags.contains(t) } } }
            for (tag, cond) in rule.when["tagGrams"]?.object ?? [:] {
                let grams = counted.filter { $0.entry.tags.contains(tag) }.reduce(0.0) { $0 + $1.grams }
                ok = ok && conditions(cond, grams)
            }
            if let cond = rule.when["distinctPlantTagged"] {
                ok = ok && conditions(cond, Double(counted.filter { $0.entry.tags.contains("plant") }.count))
            }
            guard ok else { continue }
            let why = rule.why.replacingOccurrences(of: "{fiber}", with: String(Int(fiber.rounded())))
                .replacingOccurrences(of: "{protein}", with: String(Int(protein.rounded())))
                .replacingOccurrences(of: "{count}", with: String(counted.filter { $0.entry.tags.contains("plant") }.count))
            for b in rule.benefits { add(b, rule.weight, BenefitReason(title: rule.id.replacingOccurrences(of: "_", with: " ").capitalized, why: why)) }
        }
        return scores.map { BenefitResult(benefit: $0.key, score: $0.value, reasons: reasons[$0.key] ?? []) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.benefit.rawValue < $1.benefit.rawValue }
    }
}
