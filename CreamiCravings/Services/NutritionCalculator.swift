import Foundation

/// Everything the calculator needs to know about the user's choices for one recipe.
struct RecipeConfig {
    var milk: BaseLiquid?
    var powder: ProteinPowder?
    var vegActive = false          // use the recipe's vegetarian version
    var vegChoices: [String: String] = [:]   // lineKey -> chosen alternative key
    var preferEasy = true
    var upgradeKey: String?        // protein upgrade alternative (wings / crispy bites), nil = as written
    var swaps: [String: Int] = [:]
    var pints: Int = 1
    var source: CalorieSource = .book
    var overrides: [String: NutritionOverride] = [:]
    var optionalOn: Set<String> = []
    var missing: Set<String> = []
    // Goal version (Cut / Bulk), applied last: see GoalVersion.swift
    var goalSwaps: [String: Int] = [:]       // lineKey -> catalog swap index chosen by the goal version
    var lineScale: [String: Double] = [:]    // lineKey -> grams multiplier (halved cooking fat)
    var extras: [Ing] = []                   // optional add-ons, whole-recipe amounts, not scaled by the portion
    var portion: Double = 1                  // "eat 0.8 serving" multiplier on the displayed macros
    var useEstimates = true                  // guess amounts for lines that have none (Calculated numbers and goal deltas only)
    var userGrams: [String: Double] = [:]    // lineKey -> grams typed by the user for a line with no amount
}

enum AmountKind { case known, estimated, user }

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
    var swapFromGoal = false           // the swap comes from the goal version, not the user
    var lineScale = 1.0                // goal version grams multiplier (1 = unchanged)
    var isExtra = false                // goal version add-on line
    var amount: AmountKind = .known    // known amount, an estimate, or the user's own amount
    var estimateReason: String?        // why the estimate is what it is

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
    var displayed: Nutrition           // with the portion applied
    var displayedFull: Nutrition       // same, but at a full portion (for the whole-recipe view)
    var portion: Double
    var usedSource: CalorieSource
    var estimated: Bool
    var uncounted: Int                 // lines still without any amount
    var estimatedCount = 0             // lines using an estimate or the user's own amount
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

    /// Grams the way compute() sees them: the line's own amount, else the user's typed amount, else an estimate (never for optional lines).
    func effectiveGrams(_ ing: Ing, lineKey: String, cfg: RecipeConfig) -> Double {
        let info = catalog.info(ing.key)
        let known = grams(ing, info)
        if known > 0 { return known }
        if let u = cfg.userGrams[lineKey], u > 0 { return u }
        if !ing.optional, cfg.useEstimates, let e = EstimateRules.estimate(text: ing.text, key: ing.key, info: info) { return e.grams }
        return 0
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
        let r = ProteinUpgrades.effective(recipe, catalog: catalog, vegActive: cfg.vegActive, vegChoices: cfg.vegChoices, preferEasy: cfg.preferEasy, upgradeKey: cfg.upgradeKey)
        let liquidKey = catalog.liquidLineKey(r)
        let powderKey = catalog.powderLineKey(r)
        var lines: [LineResult] = []
        var calc = Nutrition.zero
        var delta = Nutrition.zero
        var uncounted = 0
        var estimatedCount = 0
        let pints = max(1, cfg.pints)

        for (idx, pair) in r.allLines.enumerated() {
            let (lk, ing) = pair
            let isBase = idx < r.base.count
            let info = catalog.info(ing.key)
            let included = !ing.optional || cfg.optionalOn.contains(lk)
            // Amount: the line's own, else the user's typed amount, else an estimate (never for optional lines).
            let known = grams(ing, info)
            var g0 = known
            var amountKind = AmountKind.known
            var estReason: String?
            if known <= 0, let u = cfg.userGrams[lk], u > 0 {
                g0 = u; amountKind = .user
            } else if known <= 0, !ing.optional, cfg.useEstimates, let e = EstimateRules.estimate(text: ing.text, key: ing.key, info: info) {
                g0 = e.grams; amountKind = .estimated; estReason = e.reason
            }
            // The source's own totals are assumed to include this amount, so only a change (swap, goal) moves the Book numbers.
            let plain = (info?.per100g ?? .zero) * (g0 / 100)
            let origEff = per100(ing.key, info, cfg.overrides) * (g0 / 100)

            var g = g0
            var eff = origEff
            var swapOpt: SwapOption?
            var swapIdx: Int?
            var notRecalc = false
            var milkUsed: BaseLiquid?
            var powderUsed: ProteinPowder?

            let goalSwap = cfg.swaps[lk] == nil && cfg.goalSwaps[lk] != nil
            if let si = cfg.swaps[lk] ?? cfg.goalSwaps[lk], let info, info.swaps.indices.contains(si) {
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

            let scale = cfg.lineScale[lk] ?? 1
            if scale != 1 { g *= scale; eff = eff * scale }

            if included {
                calc += eff
                delta += eff - (ing.optional ? .zero : plain)
                if g <= 0 || info == nil { uncounted += 1 } else if amountKind != .known { estimatedCount += 1 }
            }
            lines.append(LineResult(
                lineKey: lk, ing: ing, isBase: isBase, included: included, info: info, grams: g, scaledGrams: g * Double(pints),
                nutrition: eff, swapIndex: swapIdx, swap: swapOpt, swapNotRecalculated: notRecalc, milk: milkUsed, powder: powderUsed, isPowderLine: lk == powderKey,
                overrideLabel: ing.key.flatMap { cfg.overrides[$0]?.sourceLabel }, isMilkLine: lk == liquidKey,
                missing: ing.key.map { cfg.missing.contains($0) } ?? false, noData: g0 <= 0 || info == nil,
                swapFromGoal: goalSwap && swapOpt != nil, lineScale: scale, amount: amountKind, estimateReason: estReason))
        }

        // Goal add-ons: whole-recipe amounts, shown as extra lines, never scaled by the portion
        var extra = Nutrition.zero
        for (i, ing) in cfg.extras.enumerated() {
            let info = catalog.info(ing.key)
            let g = grams(ing, info)
            let n = per100(ing.key, info, cfg.overrides) * (g / 100)
            extra += n
            lines.append(LineResult(
                lineKey: "x\(i)", ing: ing, isBase: false, included: true, info: info, grams: g, scaledGrams: g * Double(pints),
                nutrition: n, swapIndex: nil, swap: nil, swapNotRecalculated: false, milk: nil, powder: nil, isPowderLine: false,
                overrideLabel: nil, isMilkLine: false, missing: false, noData: g <= 0 || info == nil, isExtra: true))
        }

        let k = Double(pints)
        let p = cfg.portion
        let calcFull = calc * k + extra * k
        let calcScaled = calc * k * p + extra * k
        var bookScaled: Nutrition?, bookFull: Nutrition?
        if let m = r.macros { bookFull = (m + delta) * k + extra * k; bookScaled = (m + delta) * k * p + extra * k }
        var used = cfg.source
        var estimated = false
        if used == .book && bookScaled == nil { used = .calculated; estimated = true }
        return RecipeNutrition(lines: lines, calculated: calcScaled, book: bookScaled,
                               displayed: used == .book ? (bookScaled ?? calcScaled) : calcScaled,
                               displayedFull: used == .book ? (bookFull ?? calcFull) : calcFull,
                               portion: p, usedSource: used, estimated: estimated, uncounted: uncounted, estimatedCount: estimatedCount, pints: pints)
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
        if l.lineScale != 1, l.grams > 0 {
            t += " → \(Int(round(l.grams))) g" + (l.lineScale < 1 ? " (or use cooking spray)" : "")
        }
        if l.scaledGrams != l.grams, l.grams > 0 {
            t += " × \(Int(round(l.scaledGrams / l.grams))) → \(Int(round(l.scaledGrams))) g"
        }
        return t
    }
}
