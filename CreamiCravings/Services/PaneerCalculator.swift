import Foundation

struct PaneerResult {
    var yieldGrams: Double
    var total: Nutrition        // whole batch
    var per100g: Nutrition
}

enum PaneerCalculator {
    private static func frac(_ v: Double) -> Double { v > 1 ? v / 100 : v }

    /// Yield g = (P × proteinRecovery + F × fatRecovery + C × lactoseRecovery + ash) / (1 − moisture).
    /// P, F, C are the grams of protein, fat and carbs in the milk. Calories use 4/9/4 kcal per g.
    static func estimate(milk: BaseLiquid, liters: Double, model: PaneerModel) -> PaneerResult {
        let o = model.overrides[milk.id]
        let pr = frac(o?.proteinRecovery ?? model.proteinRecovery)
        let fr = frac(o?.fatRecovery ?? model.fatRecovery)
        let lr = frac(o?.lactoseRecovery ?? model.lactoseRecovery)
        let moisture = min(0.95, frac(o?.moisturePct ?? model.moisturePct))
        let k = liters * 1000 / milk.servingMl
        let p = milk.perServing.protein * k * pr
        let f = milk.perServing.fat * k * fr
        let c = milk.perServing.carbs * k * lr
        let ash = model.ashGramsPerLiter * liters
        let grams = (p + f + c + ash) / (1 - moisture)
        let total = Nutrition(calories: 4 * p + 9 * f + 4 * c, protein: p, carbs: c, fat: f, sugar: c, fiber: 0)
        return PaneerResult(yieldGrams: grams, total: total, per100g: grams > 0 ? total * (100 / grams) : .zero)
    }

    /// Comparison rows for 1 L across milks, best protein per 100 kcal first.
    static func comparison(milks: [BaseLiquid], model: PaneerModel) -> [(milk: BaseLiquid, result: PaneerResult)] {
        milks.map { ($0, estimate(milk: $0, liters: 1, model: model)) }
            .sorted { $0.1.per100g.proteinPer100kcal > $1.1.per100g.proteinPer100kcal }
    }

    static func eligible(_ liquids: [BaseLiquid]) -> [BaseLiquid] {
        liquids.filter { $0.family == "milk" || $0.family == "ultra_filtered" || $0.family == "custom" }
    }
}
