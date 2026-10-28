import Foundation

/// Shopping items for a planned day: each slot's recipe in its goal version, scaled to the planned portion of one serving.
@MainActor
enum PlanShopping {
    static func items(for plan: DayPlan, store: RecipeStore, user: UserStore) -> [ShoppingItem] {
        var out: [ShoppingItem] = []
        for s in plan.slots {
            guard let id = s.recipeId, let r = store.recipeByID[id] else { continue }
            var base = user.config(for: r, catalog: store.catalog, applyGoal: false)
            base.vegActive = r.vegAdaptation != nil && r.vegetarian != true
            let cfg = GoalVersion.resolve(r, catalog: store.catalog, base: base, goal: s.goal, toggles: [:], vegetarianUser: true).cfg
            let factor = s.portion / r.perServingDivisor
            var items = ShoppingList.items(for: r, cfg: cfg, catalog: store.catalog)
            for i in items.indices { if let g = items[i].grams { items[i].grams = g * factor } }
            ShoppingList.merge(items, into: &out)
        }
        return out
    }
}
