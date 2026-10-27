import Foundation

/// An optional "Add protein" line for low-protein overnight oats. Amounts are whole-recipe (per-serving amount x servings).
struct BoostLine: Hashable {
    var id: String
    var ing: Ing
    var nutrition: Nutrition?        // set when the catalog cannot describe it (the user's chosen powder)
}

struct BoostOption: Identifiable {
    var id: String
    var title: String                // "+150 g nonfat Greek yogurt"
    var note: String?
    var deltaPerServing: Nutrition   // protein / calories one serving gains
}

/// Vegetarian protein boosts (dairy is fine; nothing from meat, fish or collagen). All off by default, combinable, persisted per recipe.
enum ProteinBoosts {
    static let proteinCeiling = 20.0         // only overnight oats below this many grams of protein per serving qualify

    struct Def { var id: String; var key: String; var gramsPerServing: Double; var title: String; var line: String }
    static let defs: [Def] = [
        Def(id: "powder", key: "protein_powder_vanilla", gramsPerServing: 30, title: "+1 scoop protein powder (30 g)", line: "protein powder"),
        Def(id: "greek_yogurt", key: "greek_yogurt", gramsPerServing: 150, title: "+150 g nonfat Greek yogurt", line: "nonfat Greek yogurt"),
        Def(id: "skyr", key: "skyr_plain", gramsPerServing: 150, title: "+150 g skyr", line: "skyr"),
        Def(id: "cottage_cheese", key: "cottage_cheese", gramsPerServing: 100, title: "+100 g cottage cheese, blended", line: "cottage cheese (blended)"),
    ]
    static let powderNote = "Add ~30 ml extra milk; casein or a whey/casein blend sets creamier than isolate."

    /// Eligible: flagged by the build (overnight oats) and under 20 g protein per serving as written.
    static func isEligible(_ r: Recipe, proteinPerServing: Double) -> Bool { r.proteinBoost == true && proteinPerServing < proteinCeiling }

    private static func servings(_ r: Recipe) -> Double { Double(max(1, r.servings ?? 1)) }

    /// The line a selected boost adds to the recipe.
    static func line(_ d: Def, recipe r: Recipe, catalog: Catalog, powder: ProteinPowder?) -> BoostLine {
        let s = servings(r)
        if d.id == "powder" {
            let scoop = powder?.scoopGrams ?? d.gramsPerServing
            let name = powder?.name ?? (catalog.info(d.key)?.name ?? "protein powder")
            let ing = Ing(text: "\(Int(scoop)) g \(name) per serving (boost)", key: powder?.ingredientKey ?? d.key, grams: scoop * s)
            return BoostLine(id: d.id, ing: ing, nutrition: powder.map { $0.perScoop * s })
        }
        // the yogurt boosts are 0% Greek yogurt when the catalog has it
        let key = (d.id == "greek_yogurt" && catalog.info("greek_yogurt_nonfat") != nil) ? "greek_yogurt_nonfat" : d.key
        let ing = Ing(text: "\(Int(d.gramsPerServing)) g \(d.line) per serving (boost)", key: key, grams: d.gramsPerServing * s)
        return BoostLine(id: d.id, ing: ing, nutrition: nil)
    }

    static func lines(for r: Recipe, selected: Set<String>, catalog: Catalog, powder: ProteinPowder?) -> [BoostLine] {
        guard r.proteinBoost == true else { return [] }
        return defs.filter { selected.contains($0.id) }.map { line($0, recipe: r, catalog: catalog, powder: powder) }
    }

    /// The four options with their per-serving gain; the scoop uses the chosen powder and says "+1 more scoop" when the recipe already has one.
    static func options(for r: Recipe, catalog: Catalog, powder: ProteinPowder?) -> [BoostOption] {
        let hasPowderLine = catalog.powderLineKey(r) != nil
        return defs.map { d in
            let l = line(d, recipe: r, catalog: catalog, powder: powder)
            let s = servings(r)
            let whole: Nutrition = l.nutrition ?? (catalog.info(l.ing.key)?.per100g ?? .zero) * ((l.ing.grams ?? 0) / 100)
            var title = d.title
            if d.id == "powder" {
                let scoop = Int(powder?.scoopGrams ?? d.gramsPerServing)
                title = hasPowderLine ? "+1 more scoop (\(scoop) g)" : "+1 scoop protein powder (\(scoop) g)"
            }
            return BoostOption(id: d.id, title: title, note: d.id == "powder" ? powderNote : nil, deltaPerServing: whole * (1 / s))
        }
    }

    /// Cook-mode step: stir the boosts in before refrigerating (placed before the step that mentions the fridge, else at the end).
    static func addStep(to steps: [String], names: [String]) -> [String] {
        guard !names.isEmpty else { return steps }
        let text = "Stir in the boost\(names.count == 1 ? "" : "s") before refrigerating: \(names.joined(separator: ", "))."
        var out = steps
        let i = steps.firstIndex { s in ["refrigerat", "fridge", "chill", "overnight"].contains { s.lowercased().contains($0) } } ?? steps.count
        out.insert(text, at: i)
        return out
    }
}
