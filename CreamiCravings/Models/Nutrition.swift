import Foundation

/// Macro set. Decodes tolerantly: any missing/null field becomes 0.
struct Nutrition: Codable, Equatable, Hashable {
    var calories: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0
    var sugar: Double = 0
    var fiber: Double = 0
    /// Bit set of fields that were null/absent in the source data (shown as "–"). Arithmetic keeps the LEFT operand's flags.
    var missing: UInt8 = 0

    static let fieldBits: [String: UInt8] = ["calories": 1, "protein": 2, "carbs": 4, "fat": 8, "sugar": 16, "fiber": 32]
    func isMissing(_ field: String) -> Bool { missing & (Nutrition.fieldBits[field] ?? 0) != 0 }

    static let zero = Nutrition()

    init(calories: Double = 0, protein: Double = 0, carbs: Double = 0, fat: Double = 0, sugar: Double = 0, fiber: Double = 0) {
        self.calories = calories; self.protein = protein; self.carbs = carbs
        self.fat = fat; self.sugar = sugar; self.fiber = fiber
    }

    enum CodingKeys: String, CodingKey { case calories, protein, carbs, fat, sugar, fiber }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ bit: UInt8) -> Double {
            if let v = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil { return v }
            missing |= bit
            return 0
        }
        calories = read(.calories, 1); protein = read(.protein, 2); carbs = read(.carbs, 4)
        fat = read(.fat, 8); sugar = read(.sugar, 16); fiber = read(.fiber, 32)
    }

    static func + (a: Nutrition, b: Nutrition) -> Nutrition {
        Nutrition(calories: a.calories + b.calories, protein: a.protein + b.protein, carbs: a.carbs + b.carbs,
                  fat: a.fat + b.fat, sugar: a.sugar + b.sugar, fiber: a.fiber + b.fiber).keeping(a.missing)
    }
    static func - (a: Nutrition, b: Nutrition) -> Nutrition {
        Nutrition(calories: a.calories - b.calories, protein: a.protein - b.protein, carbs: a.carbs - b.carbs,
                  fat: a.fat - b.fat, sugar: a.sugar - b.sugar, fiber: a.fiber - b.fiber).keeping(a.missing)
    }
    static func * (a: Nutrition, k: Double) -> Nutrition {
        Nutrition(calories: a.calories * k, protein: a.protein * k, carbs: a.carbs * k,
                  fat: a.fat * k, sugar: a.sugar * k, fiber: a.fiber * k).keeping(a.missing)
    }
    private func keeping(_ m: UInt8) -> Nutrition { var n = self; n.missing = m; return n }
    static func += (a: inout Nutrition, b: Nutrition) { a = a + b }

    var proteinPer100kcal: Double { calories > 0 ? protein / calories * 100 : 0 }
}
