import Foundation

/// One change a goal version makes to a recipe; each can be switched off in the "Changes for ..." card.
struct GoalChange: Identifiable, Hashable {
    enum Kind: String { case swap, fat, portion, addon }
    var id: String                 // "cut:swap:b2", "cut:portion", "bulk:addon:nuts"
    var kind: Kind
    var title: String
    var detail: String?
    var defaultOn: Bool
    var enabled: Bool
}

struct GoalResolution {
    var goal: Goal
    var changes: [GoalChange]
    var cfg: RecipeConfig          // the user's config with the enabled changes applied
    var portion: Double            // 1 when no portion change is on
    var portionLabel: String?      // "Cut portion: 0.8 serving"
}

/// Rule-based Cut / Bulk versions of a recipe. Deterministic, catalog-driven, applied after the vegetarian version,
/// the milk / powder pickers and the user's own swaps (a line the user already swapped is left alone).
enum GoalVersion {
    static let cutTargets: [String: Double] = ["meal": 450, "dessert": 250, "drink": 250, "creami": 350]
    static let bulkTargets: [String: Double] = ["meal": 750, "dessert": 450, "drink": 450, "creami": 600]
    static let cookingFats: Set<String> = ["olive_oil", "vegetable_oil", "butter", "ghee", "coconut_oil"]
    static let leanPattern = ["fat_free", "skim", "light", "low_fat", "reduced", "nonfat", "lite", "lean"]

    private static func sameFamily(_ a: String, _ b: String) -> Bool {
        a == b || (["milk", "ultra_filtered"].contains(a) && ["milk", "ultra_filtered"].contains(b))
    }
    private static func section(_ r: Recipe) -> String { r.section.isEmpty ? "creami" : r.section }

    /// Original-as-written classification from the displayed per-serving macros.
    static func original(of r: Recipe, perServing n: Nutrition) -> Goal { Goal.original(n, bookTitle: r.source.title) }

    static func resolve(_ recipe: Recipe, catalog: Catalog, base: RecipeConfig, goal: Goal, toggles: [String: Bool], vegetarianUser: Bool) -> GoalResolution {
        var cfg = base
        cfg.goalSwaps = [:]; cfg.lineScale = [:]; cfg.extras = []; cfg.portion = 1
        guard goal != .maintain else { return GoalResolution(goal: goal, changes: [], cfg: cfg, portion: 1, portionLabel: nil) }

        let calc = NutritionCalculator(catalog: catalog)
        let eff = ProteinUpgrades.effective(recipe, catalog: catalog, vegActive: base.vegActive, vegChoices: base.vegChoices, preferEasy: base.preferEasy, upgradeKey: base.upgradeKey)
        let liquidKey = catalog.liquidLineKey(eff), powderKey = catalog.powderLineKey(eff)
        let divisor = recipe.perServingDivisor
        let prefix = goal == .cut ? "cut" : "bulk"
        var changes: [GoalChange] = []

        func isOn(_ id: String, _ defaultOn: Bool) -> Bool { toggles[id] ?? defaultOn }

        // a. swaps from the catalog
        for (lk, ing) in eff.allLines {
            if ing.optional && !base.optionalOn.contains(lk) { continue }
            if base.swaps[lk] != nil { continue }                                     // the user chose this line
            if lk == liquidKey && base.milk != nil { continue }
            if lk == powderKey && base.powder != nil { continue }
            guard let info = catalog.info(ing.key), !info.swaps.isEmpty, !info.pantryStaple, info.per100g.calories > 0 else { continue }
            let g = calc.effectiveGrams(ing, lineKey: lk, cfg: base)
            guard g >= 5 else { continue }

            var best: (idx: Int, score: Double, saved: Double, protein: Double, swap: SwapOption)?
            for (i, s) in info.swaps.enumerated() {
                guard let sk = s.key, let sinfo = catalog.info(sk), sameFamily(sinfo.category, info.category),
                      !vegetarianUser || sinfo.vegetarian != .no else { continue }
                let oldK = info.per100g.calories * g / 100, newK = sinfo.per100g.calories * g * s.ratio / 100
                let dProtein = (sinfo.per100g.protein * g * s.ratio - info.per100g.protein * g) / 100
                if goal == .cut {
                    guard newK <= 0.8 * oldK else { continue }           // at least 20% fewer calories for this line (ratio included)
                    let score = (oldK - newK) / (max(0, -dProtein) + 1)             // calories saved per gram of protein lost
                    if best == nil || score > best!.score { best = (i, score, newK - oldK, dProtein, s) }
                } else {
                    guard leanPattern.contains(where: { (ing.key ?? "").contains($0) || info.name.lowercased().contains($0) }),
                          newK >= 1.15 * oldK else { continue }
                    let score = -(newK - oldK)                                         // the gentlest step up
                    if best == nil || score > best!.score { best = (i, score, newK - oldK, dProtein, s) }
                }
            }
            if let b = best {
                let id = "\(prefix):swap:\(lk)"
                let on = isOn(id, true)
                let sign: (Double) -> String = { ($0 >= 0 ? "+" : "−") + "\(Int(abs($0).rounded()))" }
                changes.append(GoalChange(id: id, kind: .swap, title: "\(info.name) → \(b.swap.name)",
                                          detail: "\(sign(b.saved)) kcal, \(sign(b.protein)) g protein", defaultOn: true, enabled: on))
                if on { cfg.goalSwaps[lk] = b.idx }
            }
        }

        // b. cooking fat (Cut, meals only): halve oil, butter and ghee that was not swapped
        if goal == .cut && recipe.section == "meal" {
            for (lk, ing) in eff.allLines where cfg.goalSwaps[lk] == nil && base.swaps[lk] == nil {
                guard let k = ing.key, cookingFats.contains(k), !(ing.optional && !base.optionalOn.contains(lk)) else { continue }
                let g = calc.effectiveGrams(ing, lineKey: lk, cfg: base)
                guard g >= 5 else { continue }
                let id = "cut:fat:\(lk)"
                let on = isOn(id, true)
                changes.append(GoalChange(id: id, kind: .fat, title: "Halve the \(catalog.info(k)?.name.lowercased() ?? "fat") (\(Int(g.rounded())) g → \(Int((g / 2).rounded())) g)",
                                          detail: "or use cooking spray", defaultOn: true, enabled: on))
                if on { cfg.lineScale[lk] = 0.5 }
            }
        }

        // c. portion
        let kcalPerServing = calc.compute(recipe, cfg).displayedFull.calories / divisor
        var portion = 1.0
        var label: String?
        let noun = recipe.servingNoun == "piece" ? "piece" : (section(recipe) == "creami" ? "pint" : "serving")
        if goal == .cut, let target = cutTargets[section(recipe)], kcalPerServing > target {
            let n = max(0.1, (target / kcalPerServing / 0.05).rounded(.down) * 0.05)
            let id = "cut:portion", on = isOn(id, true)
            let text = FilterFormat.portion(n)
            changes.append(GoalChange(id: id, kind: .portion, title: "Cut portion: \(text) \(noun)", detail: "about \(Int(target)) kcal", defaultOn: true, enabled: on))
            if on { portion = n; label = "Cut portion: \(text) \(noun)" }
        }
        if goal == .bulk, let target = bulkTargets[section(recipe)], kcalPerServing > 0, kcalPerServing < target {
            let n = min(2.0, (target / kcalPerServing / 0.25).rounded(.up) * 0.25)
            if n > 1 {
                let id = "bulk:portion", on = isOn(id, true)
                let text = FilterFormat.portion(n)
                changes.append(GoalChange(id: id, kind: .portion, title: "Bulk portion: \(text) \(noun)s",
                                          detail: "about \(Int(target)) kcal", defaultOn: true, enabled: on))
                if on { portion = n; label = "Bulk portion: \(text) \(noun)\(n == 1 ? "" : "s")" }
            }
        }
        cfg.portion = portion

        // d. Bulk add-on (one, matching the recipe; off by default)
        if goal == .bulk, let add = addOn(for: recipe, catalog: catalog) {
            let id = "bulk:addon:\(add.key)", on = isOn(id, false)
            let servings = Double(max(1, recipe.servings ?? 1))
            let whole = Ing(text: add.text + " per serving", key: add.key, grams: add.grams * servings, optional: false)
            let info = catalog.info(add.key)
            let kcal = (info?.per100g.calories ?? 0) * add.grams / 100
            changes.append(GoalChange(id: id, kind: .addon, title: add.text, detail: kcal > 0 ? "+\(Int(kcal.rounded())) kcal per serving" : nil, defaultOn: false, enabled: on))
            if on { cfg.extras = [whole] }
        }
        return GoalResolution(goal: goal, changes: changes, cfg: cfg, portion: portion, portionLabel: label)
    }

    struct AddOn { var key: String; var text: String; var grams: Double }

    /// The single add-on that suits the cuisine / course, if the catalog has its ingredient.
    static func addOn(for r: Recipe, catalog: Catalog) -> AddOn? {
        let cuisine = (r.cuisine ?? "").lowercased(), course = r.course ?? ""
        var pick: AddOn
        if cuisine == "mexican" { pick = AddOn(key: "tortilla_wrap", text: "+1 extra tortilla (side)", grams: 45) }
        else if cuisine == "indian" || cuisine == "indo-chinese" { pick = AddOn(key: "naan", text: "+1 roti / flatbread (side, about 60 g)", grams: 60) }
        else if cuisine == "mediterranean" || cuisine == "italian" { pick = AddOn(key: "olive_oil", text: "+10 g olive oil drizzle", grams: 10) }
        else if ["lunch", "dinner", "side", "sauce"].contains(course) && r.section == "meal" { pick = AddOn(key: "rice_cooked", text: "+150 g cooked rice (side)", grams: 150) }
        else { pick = AddOn(key: "nuts", text: "+30 g mixed nuts", grams: 30) }
        return catalog.info(pick.key) != nil ? pick : nil
    }
}

enum FilterFormat {
    /// 0.8 -> "0.8", 1.5 -> "1.5", 2 -> "2", 0.35 -> "0.35".
    static func portion(_ n: Double) -> String {
        let r = (n * 100).rounded() / 100
        return r == r.rounded() ? String(Int(r)) : String(format: r * 10 == (r * 10).rounded() ? "%.1f" : "%.2f", r)
    }
}
