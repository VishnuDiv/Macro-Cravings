import Foundation

/// Everything the calculator needs to know about the user's choices for one recipe.
struct RecipeConfig {
    var milk: BaseLiquid?
    var powder: ProteinPowder?
    var vegActive = false          // use the recipe's vegetarian version
    var vegChoices: [String: String] = [:]   // lineKey -> chosen alternative key
    var preferEasy = true
    var swaps: [String: Int] = [:]
    var pints: Int = 1
    var source: CalorieSource = .book
    var overrides: [String: NutritionOverride] = [:]
    var optionalOn: Set<String> = []
    var missing: Set<String> = []
}

struct LineResult: Identifiable {
    var id: String { lineKey }
    var lineKey: String
    var ing: Ing
    var isBase: Bool
    var included: Bool
    var info: IngredientInfo?
    var grams: Double                  // after swap, one pint
    var scaledGrams: Double            // times pints
    var nutrition: Nutrition           // effective, one pint
    var swapIndex: Int?
    var swap: SwapOption?
    var swapNotRecalculated: Bool
    var milk: BaseLiquid?              // milk applied to this line
    var powder: ProteinPowder?         // powder applied to this line
    var isPowderLine: Bool
    var overrideLabel: String?
    var isMilkLine: Bool
    var missing: Bool
    var noData: Bool                   // grams unknown or no catalog entry

    var displayName: String {
        if let swap { return swap.name }
        if let milk { return milk.name }
        if let powder { return powder.name }
        return ing.text
    }
    /// Key to use for shopping/pantry (swap or milk replace the original).
    var effectiveKey: String? { if let swap { return swap.key }; return milk?.ingredientKey ?? powder?.ingredientKey ?? ing.key }
}

struct RecipeNutrition {
    var lines: [LineResult]
    var calculated: Nutrition          // pints applied
    var book: Nutrition?               // pints applied; nil when recipe has no macros
    var displayed: Nutrition
    var usedSource: CalorieSource
    var estimated: Bool
    var uncounted: Int
    var pints: Int
}

struct NutritionCalculator {
    var catalog: Catalog

    func grams(_ ing: Ing, _ info: IngredientInfo?) -> Double {
        if let g = ing.grams { return g }
        if let ml = ing.ml { return ml * (info?.gramsPerMl ?? 1.0) }
        if let c = ing.count, let gpc = info?.gramsPerCount { return c * gpc }
        return info?.defaultGrams ?? 0
    }

    func per100(_ key: String?, _ info: IngredientInfo?, _ overrides: [String: NutritionOverride]) -> Nutrition {
        if let key, let o = overrides[key] { return o.per100g }
        return info?.per100g ?? .zero
    }

    func milkNutrition(_ ing: Ing, _ info: IngredientInfo?, _ milk: BaseLiquid) -> Nutrition {
        if catalog.isShake(ing), milk.family == "protein_shake" {
            return milk.perServing * (ing.count ?? 1)
        }
        let volume: Double
        if let ml = ing.ml { volume = ml }
        else if let g = ing.grams { volume = g / (info?.gramsPerMl ?? milk.gramsPerMl) }
        else if let c = ing.count { volume = c * milk.servingMl }
        else { volume = milk.servingMl }
        return milk.perServing * (volume / milk.servingMl)
    }

    func compute(_ recipe: Recipe, _ cfg: RecipeConfig) -> RecipeNutrition {
        let r = cfg.vegActive ? VegAlternatives.resolve(recipe, catalog: catalog, choices: cfg.vegChoices, preferEasy: cfg.preferEasy).recipe : recipe
        let liquidKey = catalog.liquidLineKey(r)
        let powderKey = catalog.powderLineKey(r)
        var lines: [LineResult] = []
        var calc = Nutrition.zero
        var delta = Nutrition.zero
        var uncounted = 0
        let pints = max(1, cfg.pints)

        for (idx, pair) in r.allLines.enumerated() {
            let (lk, ing) = pair
            let isBase = idx < r.base.count
            let info = catalog.info(ing.key)
            let included = !ing.optional || cfg.optionalOn.contains(lk)
            let g0 = grams(ing, info)
            let plain = (info?.per100g ?? .zero) * (g0 / 100)
            let origEff = per100(ing.key, info, cfg.overrides) * (g0 / 100)

            var g = g0
            var eff = origEff
            var swapOpt: SwapOption?
            var swapIdx: Int?
            var notRecalc = false
            var milkUsed: BaseLiquid?
            var powderUsed: ProteinPowder?

            if let si = cfg.swaps[lk], let info, info.swaps.indices.contains(si) {
                let s = info.swaps[si]
                swapOpt = s; swapIdx = si
                g = g0 * s.ratio
                if let sk = s.key, let sinfo = catalog.info(sk) {
                    eff = per100(sk, sinfo, cfg.overrides) * (g / 100)
                } else {
                    eff = origEff; notRecalc = true
                }
            } else if lk == liquidKey, let m = cfg.milk, m.ingredientKey != ing.key {
                eff = milkNutrition(ing, info, m)
                milkUsed = m
            } else if lk == powderKey, let p = cfg.powder, p.ingredientKey != ing.key {
                let pg = ing.grams ?? ing.count.map { $0 * p.scoopGrams } ?? info?.defaultGrams ?? 0
                g = pg
                eff = p.perScoop * (pg / p.scoopGrams)
                powderUsed = p
            }

            if included {
                calc += eff
                delta += eff - (ing.optional ? .zero : plain)
                if g <= 0 || info == nil { uncounted += 1 }
            }
            lines.append(LineResult(
                lineKey: lk, ing: ing, isBase: isBase, included: included, info: info, grams: g, scaledGrams: g * Double(pints),
                nutrition: eff, swapIndex: swapIdx, swap: swapOpt, swapNotRecalculated: notRecalc, milk: milkUsed, powder: powderUsed, isPowderLine: lk == powderKey,
                overrideLabel: ing.key.flatMap { cfg.overrides[$0]?.sourceLabel }, isMilkLine: lk == liquidKey,
                missing: ing.key.map { cfg.missing.contains($0) } ?? false, noData: g0 <= 0 || info == nil))
        }

        let k = Double(pints)
        let calcScaled = calc * k
        var bookScaled: Nutrition?
        if let m = r.macros { bookScaled = (m + delta) * k }
        var used = cfg.source
        var estimated = false
        if used == .book && bookScaled == nil { used = .calculated; estimated = true }
        return RecipeNutrition(lines: lines, calculated: calcScaled, book: bookScaled,
                               displayed: used == .book ? (bookScaled ?? calcScaled) : calcScaled,
                               usedSource: used, estimated: estimated, uncounted: uncounted, pints: pints)
    }

    /// Change in displayed macros (one pint basis, same source as cfg) if `swapIndex` were applied to `lineKey`.
    func swapImpact(_ r: Recipe, lineKey: String, swapIndex: Int, cfg: RecipeConfig) -> (delta: Nutrition, recalculated: Bool) {
        var without = cfg; without.swaps[lineKey] = nil
        var with = cfg; with.swaps[lineKey] = swapIndex
        let a = compute(r, without), b = compute(r, with)
        let recalc = !(b.lines.first { $0.lineKey == lineKey }?.swapNotRecalculated ?? true)
        return (b.displayed - a.displayed, recalc)
    }

    /// Converts a label/serving entry to per-100 g values.
    static func per100(fromServing n: Nutrition, size: Double) -> Nutrition {
        size > 0 ? n * (100 / size) : .zero
    }

    /// "400 g × 3 → 1200 g" style amount text.
    static func amountText(_ l: LineResult) -> String {
        var t = l.ing.text
        if l.scaledGrams != l.grams, l.grams > 0 {
            t += " × \(Int(round(l.scaledGrams / l.grams))) → \(Int(round(l.scaledGrams))) g"
        }
        return t
    }
}
