import Foundation

struct PlanTargets: Equatable {
    var kcal: Double
    var protein: Double
}

/// One planned slot with its numbers (per serving x portion).
struct PlannedSlot: Identifiable {
    var slot: MealSlotPlan
    var recipe: Recipe?
    var macros: Nutrition          // for the planned portion
    var id: String { slot.id }
}

/// Deterministic meal planner. Fills breakfast / lunch / dinner / snack (+ optional dessert) from vegetarian-safe recipes, in each
/// recipe's goal version, scaling portions (0.75x - 1.5x; 2x only for snacks and desserts under 250 kcal) so the day lands near the
/// targets: kcal within 7% and protein 95% - 125% of the target (up to 135% on a cut). Main meals are complete meals only (no sauces,
/// doughs, bases or plain rice). The same seed always gives the same day.
@MainActor
final class MealPlanner {
    let store: RecipeStore
    let user: UserStore
    private var macroCache: [String: Nutrition] = [:]
    private var vegCache: [String: Bool] = [:]
    private var poolCache: [String: [Recipe]] = [:]

    nonisolated static let portionSteps: [Double] = [0.75, 1, 1.25, 1.5]
    static let kcalTolerance = 0.07
    static let proteinFloor = 0.95
    static func proteinCeiling(for goal: Goal) -> Double { goal == .cut ? 1.35 : 1.25 }
    static func isMainSlot(_ s: PlanSlotName) -> Bool { s == .breakfast || s == .lunch || s == .dinner }
    /// Allowed portions: 0.75x - 1.5x, plus 2x for a snack or dessert that is under 250 kcal a serving.
    static func portions(for slot: PlanSlotName, kcal: Double) -> [Double] {
        (slot == .snack || slot == .dessert) && kcal < 250 ? portionSteps + [2] : portionSteps
    }
    private static let componentName = try! NSRegularExpression(pattern: #"\b(base|crust|dough|batter|sauce|dressing|dip|spread|seasoning|marinade|rice\b(?! bowl)|sushi rice|stock)\b"#, options: .caseInsensitive)
    /// A sauce, dough, base or plain rice rather than a complete meal (a meal bowl is fine).
    static func isComponent(_ r: Recipe) -> Bool {
        if r.course == "side" || r.course == "sauce" { return true }
        let n = r.name
        guard componentName.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) != nil else { return false }
        return !(r.tags.contains { $0.localizedCaseInsensitiveContains("bowl") })
    }

    init(store: RecipeStore, user: UserStore) { self.store = store; self.user = user }

    // MARK: recipe facts

    /// True when the planned (vegetarian) version of the recipe has no meat or fish line.
    func isVegSafe(_ r: Recipe) -> Bool {
        if let c = vegCache[r.id] { return c }
        var ok = true
        if r.vegetarian == false && r.vegAdaptation == nil { ok = false }
        if ok {
            let eff = ProteinUpgrades.effective(r, catalog: store.catalog, vegActive: r.vegAdaptation != nil && r.vegetarian != true,
                                                vegChoices: [:], preferEasy: true, upgradeKey: nil)
            ok = !eff.allIngredients.contains { store.catalog.info($0.key)?.vegetarian == .no }
        }
        vegCache[r.id] = ok
        return ok
    }

    /// Macros of ONE serving (one pint for Creami) in the recipe's goal version: veg version, goal changes and portion included.
    func macros(of r: Recipe, goal: Goal) -> Nutrition {
        let key = "\(r.id)|\(goal.rawValue)"
        if let n = macroCache[key] { return n }
        var base = user.config(for: r, catalog: store.catalog, applyGoal: false)
        base.vegActive = r.vegAdaptation != nil && r.vegetarian != true
        let cfg = GoalVersion.resolve(r, catalog: store.catalog, base: base, goal: goal, toggles: [:], vegetarianUser: true).cfg
        let n = NutritionCalculator(catalog: store.catalog).compute(r, cfg).displayed * (1 / r.perServingDivisor)
        macroCache[key] = n
        return n
    }

    /// The title of the planned version, as the recipe cards show it: the vegetarian version ("Tofu Chow Mein"), then the chosen protein upgrade.
    func displayTitle(of r: Recipe) -> String {
        let vegActive = r.vegAdaptation != nil && r.vegetarian != true
        guard vegActive || user.data.upgradeChoice[r.id] != nil else { return r.name }
        let name = ProteinUpgrades.effective(r, catalog: store.catalog, vegActive: vegActive, vegChoices: user.data.vegChoice[r.id] ?? [:],
                                             preferEasy: user.data.preferEasyAlternatives, upgradeKey: user.data.upgradeChoice[r.id]).name
        return vegActive ? VegAlternatives.meatFreeTitle(name, of: r) : name
    }

    // MARK: pools

    /// Recipes that may fill a slot (course mapping), best protein density first, capped for speed.
    func pool(for slot: PlanSlotName) -> [Recipe] {
        if let p = poolCache[slot.rawValue] { return p }
        func fits(_ r: Recipe) -> Bool {
            switch slot {
            case .breakfast: return r.section == "meal" && r.course == "breakfast" && !MealPlanner.isComponent(r)
            case .lunch, .dinner: return r.section == "meal" && (r.course == "lunch" || r.course == "dinner") && !MealPlanner.isComponent(r)
            case .snack: return (r.section == "meal" && r.course == "snack") || r.section == "drink" || r.section == "creami"
            case .dessert: return r.section == "dessert" || r.section == "creami"
            }
        }
        func density(_ r: Recipe) -> Double {
            let d = user.display(for: r, catalog: store.catalog).displayed * (1 / r.perServingDivisor)
            return d.calories > 0 ? d.protein / d.calories : 0
        }
        let all = store.recipes.filter { fits($0) && $0.macros != nil && isVegSafe($0) }
        let ranked = all.sorted { density($0) != density($1) ? density($0) > density($1) : $0.id < $1.id }
        let p = Array(ranked.prefix(300))
        poolCache[slot.rawValue] = p
        return p
    }

    // MARK: scoring

    private func hash(_ s: String, _ seed: Int) -> Double {
        var h: UInt64 = 1469598103934665603 ^ UInt64(truncatingIfNeeded: seed)
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        h ^= h >> 29; h = h &* 0xBF58476D1CE4E5B9; h ^= h >> 32
        return Double(h % 10_000) / 10_000
    }

    /// Best allowed portion for a recipe to deliver `budget` kcal, and how far off it lands (fraction of the budget).
    static func bestPortion(kcal: Double, budget: Double, steps: [Double] = MealPlanner.portionSteps) -> (portion: Double, error: Double) {
        guard kcal > 0, budget > 0 else { return (1, 1) }
        var best = (portion: 1.0, error: Double.infinity)
        for p in steps {
            let e = abs(kcal * p - budget) / budget
            if e < best.error { best = (p, e) }
        }
        return best
    }

    // MARK: generation

    func totals(_ plan: DayPlan) -> Nutrition {
        plan.slots.reduce(Nutrition.zero) { acc, s in
            guard let id = s.recipeId, let r = store.recipeByID[id] else { return acc }
            return acc + macros(of: r, goal: s.goal) * s.portion
        }
    }

    /// kcal error (fraction) and protein ratio of a plan against the targets.
    func fit(_ plan: DayPlan, _ t: PlanTargets) -> (kcalError: Double, proteinRatio: Double) {
        let n = totals(plan)
        return (abs(n.calories - t.kcal) / t.kcal, n.protein / t.protein)
    }

    private struct Cand { var recipe: Recipe; var kcal: Double; var protein: Double; var score: Double; var steps: [Double] }

    /// A full day. Locked slots in `existing` are kept; `avoid` holds recipe ids planned in the previous days. For each open slot the
    /// best-scoring recipes are kept as candidates, then a deterministic search over (recipe, portion) picks the combination that lands
    /// kcal within 7% and protein in the 95% - 125% window (135% on a cut), preferring 1x portions.
    func generateDay(seed: Int, targets t: PlanTargets, goal: Goal, existing: DayPlan? = nil, avoid: Set<String> = [],
                     includeDessert: Bool = false, focus: Benefit? = nil) -> DayPlan {
        var slots: [PlanSlotName] = [.breakfast, .lunch, .dinner, .snack]
        if includeDessert || existing?.slots.contains(where: { $0.slot == .dessert }) == true { slots.append(.dessert) }
        let share = slots.reduce(0.0) { $0 + ($1 == .dessert ? 0.08 : $1.kcalShare) }
        func budget(_ s: PlanSlotName) -> Double { t.kcal * (s == .dessert ? 0.08 : s.kcalShare) / share }
        let ceiling = MealPlanner.proteinCeiling(for: goal)
        let targetDensity = t.protein / t.kcal * 100

        var locked: [PlanSlotName: MealSlotPlan] = [:]
        for s in existing?.slots ?? [] where s.locked && s.recipeId != nil { locked[s.slot] = s }
        let lockedIds = Set(locked.values.compactMap(\.recipeId))
        let open = slots.filter { locked[$0] == nil }

        func candidates(_ s: PlanSlotName) -> [Cand] {
            let list: [Cand] = pool(for: s).compactMap { r in
                guard !avoid.contains(r.id), !lockedIds.contains(r.id) else { return nil }
                let m = macros(of: r, goal: goal)
                guard m.calories > 0, !(MealPlanner.isMainSlot(s) && m.calories < 250) else { return nil }
                let steps = MealPlanner.portions(for: s, kcal: m.calories)
                let err = MealPlanner.bestPortion(kcal: m.calories, budget: budget(s), steps: steps).error
                guard err <= 0.5 else { return nil }
                var sc = 1 - abs((m.protein / m.calories * 100) / (targetDensity * 1.1) - 1)    // protein density near what the day needs
                sc -= err * 0.8
                if user.isSaved(r.id) { sc += 0.4 }
                if user.rating(r.id) >= 4 { sc += 0.4 }
                if let f = focus, (store.index[r.id]?.benefits.first { $0.benefit == f }?.score ?? 0) > 0 { sc += 0.6 }
                if (s == .lunch && r.course == "dinner") || (s == .dinner && r.course == "lunch") { sc -= 0.05 }
                sc += hash(r.id + s.rawValue, seed) * 0.5                                         // seeded variety
                return Cand(recipe: r, kcal: m.calories, protein: m.protein, score: sc, steps: steps)
            }
            return Array(list.sorted { $0.score != $1.score ? $0.score > $1.score : $0.recipe.id < $1.recipe.id }.prefix(16))
        }
        let cands = Dictionary(uniqueKeysWithValues: open.map { ($0, candidates($0)) })

        let lockedTotals = locked.values.reduce(Nutrition.zero) { acc, s in
            guard let id = s.recipeId, let r = store.recipeByID[id] else { return acc }
            return acc + macros(of: r, goal: s.goal) * s.portion
        }
        typealias Pick = (idx: Int, portion: Double)
        func objective(_ picks: [PlanSlotName: Pick]) -> Double {
            var k = lockedTotals.calories, p = lockedTotals.protein, dev = 0.0, sc = 0.0
            for (s, pk) in picks {
                let c = cands[s]![pk.idx]
                k += c.kcal * pk.portion; p += c.protein * pk.portion; dev += abs(pk.portion - 1); sc += c.score
            }
            let kerr = abs(k - t.kcal) / t.kcal, pr = p / t.protein
            var o = kerr * 4 + 12 * max(0, kerr - 0.04)
            o += 12 * max(0, 0.97 - pr) + 12 * max(0, pr - (ceiling - 0.03))
            o += 0.3 * abs(pr - (goal == .cut ? 1.1 : 1.08))
            o += 0.12 * dev - 0.15 * sc
            return o
        }
        var picks: [PlanSlotName: Pick] = [:]
        var usedIds = lockedIds
        for s in open {
            guard let c = cands[s]?.first(where: { !usedIds.contains($0.recipe.id) }), let idx = cands[s]?.firstIndex(where: { $0.recipe.id == c.recipe.id }) else { continue }
            usedIds.insert(c.recipe.id)
            picks[s] = (idx, MealPlanner.bestPortion(kcal: c.kcal, budget: budget(s), steps: c.steps).portion)
        }
        for _ in 0..<6 {
            var changed = false
            for s in open where picks[s] != nil {
                let others = Set(picks.filter { $0.key != s }.map { cands[$0.key]![$0.value.idx].recipe.id })
                var bestPick = picks[s]!, bestObj = objective(picks)
                for (i, c) in cands[s]!.enumerated() where !others.contains(c.recipe.id) {
                    for p in c.steps {
                        var trial = picks; trial[s] = (i, p)
                        let o = objective(trial)
                        if o < bestObj - 1e-12 { bestObj = o; bestPick = (i, p) }
                    }
                }
                if bestPick.idx != picks[s]!.idx || bestPick.portion != picks[s]!.portion { picks[s] = bestPick; changed = true }
            }
            if !changed { break }
        }
        let out: [MealSlotPlan] = slots.compactMap { s in
            if let l = locked[s] { return l }
            guard let pk = picks[s] else { return nil }
            return MealSlotPlan(slot: s, recipeId: cands[s]![pk.idx].recipe.id, portion: pk.portion, goal: goal)
        }
        return DayPlan(slots: out, seed: seed)
    }

    /// Protein per kcal of a planned slot (9 when empty, so empty slots are never the "weakest").
    private func density(of slot: MealSlotPlan?, _ goal: Goal) -> Double {
        guard let id = slot?.recipeId, let r = store.recipeByID[id] else { return 9 }
        let m = macros(of: r, goal: goal)
        return m.calories > 0 ? m.protein / m.calories : 0
    }

    /// Up to 5 alternatives for one slot that fit what is left of the day's calories (portion 0.5x - 2x).
    func swapCandidates(for slot: PlanSlotName, in plan: DayPlan, targets t: PlanTargets, goal: Goal, avoid: Set<String> = [], limit: Int = 5)
        -> [(recipe: Recipe, portion: Double)] {
        let others = plan.slots.filter { $0.slot != slot }
        var rest = DayPlan(slots: others, seed: plan.seed)
        rest.seed = plan.seed
        let remaining = max(150, t.kcal - totals(rest).calories)
        let inPlan = Set(plan.slots.compactMap(\.recipeId))
        let scored: [(Recipe, Double, Double)] = pool(for: slot).compactMap { r in
            guard !avoid.contains(r.id), !inPlan.contains(r.id) else { return nil }
            let m = macros(of: r, goal: goal)
            guard !(MealPlanner.isMainSlot(slot) && m.calories < 250) else { return nil }
            let f = MealPlanner.bestPortion(kcal: m.calories, budget: remaining, steps: MealPlanner.portions(for: slot, kcal: m.calories))
            guard m.calories > 0, f.error <= MealPlanner.kcalTolerance else { return nil }     // lands within 7% of the remaining budget
            return (r, f.portion, m.protein / m.calories - f.error)
        }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.id < $1.0.id }
        return scored.prefix(limit).map { ($0.0, $0.1) }
    }

    /// Ids planned in the three days before `date`.
    func recentIds(before date: Date, plans: [String: DayPlan], calendar: Calendar = .current) -> Set<String> {
        var ids = Set<String>()
        for d in 1...3 {
            guard let day = calendar.date(byAdding: .day, value: -d, to: date), let p = plans[PlanKey.key(day, calendar: calendar)] else { continue }
            ids.formUnion(p.slots.compactMap(\.recipeId))
        }
        return ids
    }
}

enum PlanKey {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
