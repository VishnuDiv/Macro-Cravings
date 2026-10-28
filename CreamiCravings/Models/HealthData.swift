import Foundation

/// The two halves of the app. The choice persists.
enum AppMode: String, Codable, CaseIterable, Identifiable {
    case food, health
    var id: String { rawValue }
    var title: String { self == .food ? "Food" : "Health" }
}

// MARK: meal plan

enum PlanSlotName: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack, dessert
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Share of the day's calories the generator aims each slot at (dessert is optional and defaults to none).
    var kcalShare: Double {
        switch self { case .breakfast: return 0.25; case .lunch: return 0.30; case .dinner: return 0.30; case .snack: return 0.15; case .dessert: return 0 }
    }
    var symbol: String {
        switch self { case .breakfast: return "sunrise"; case .lunch: return "fork.knife"; case .dinner: return "moon.stars"; case .snack: return "takeoutbag.and.cup.and.straw"; case .dessert: return "birthday.cake" }
    }
}

struct MealSlotPlan: Codable, Hashable, Identifiable {
    var id: String { slot.rawValue }
    var slot: PlanSlotName
    var recipeId: String?
    var portion: Double = 1            // 0.5x ... 2x of one serving (one pint for Creami)
    var goal: Goal = .maintain         // the goal version of the recipe that is planned
    var locked = false

    enum CodingKeys: String, CodingKey { case slot, recipeId, portion, goal, locked }
    init(slot: PlanSlotName, recipeId: String? = nil, portion: Double = 1, goal: Goal = .maintain, locked: Bool = false) {
        self.slot = slot; self.recipeId = recipeId; self.portion = portion; self.goal = goal; self.locked = locked
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slot = (try? c.decode(PlanSlotName.self, forKey: .slot)) ?? .snack
        recipeId = (try? c.decodeIfPresent(String.self, forKey: .recipeId)) ?? nil
        portion = (try? c.decode(Double.self, forKey: .portion)) ?? 1
        goal = (try? c.decode(Goal.self, forKey: .goal)) ?? .maintain
        locked = (try? c.decode(Bool.self, forKey: .locked)) ?? false
    }
}

struct DayPlan: Codable, Hashable {
    var slots: [MealSlotPlan] = []
    var seed: Int = 1
    enum CodingKeys: String, CodingKey { case slots, seed }
    init(slots: [MealSlotPlan] = [], seed: Int = 1) { self.slots = slots; self.seed = seed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = decodeLenientArray(from: c, key: .slots)
        seed = (try? c.decode(Int.self, forKey: .seed)) ?? 1
    }
}

// MARK: skin and hair profiles

struct SkinProfile: Codable, Hashable {
    var skinType: String?              // oily | dry | combination | normal | sensitive
    var concerns: Set<String> = []     // acne, oil, dryness, dark_spots, texture, redness, aging, dark_circles
    var sun: String?                   // low | moderate | high
    var isComplete: Bool { skinType != nil }
    init() {}
    enum CodingKeys: String, CodingKey { case skinType, concerns, sun }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skinType = (try? c.decodeIfPresent(String.self, forKey: .skinType)) ?? nil
        concerns = (try? c.decode(Set<String>.self, forKey: .concerns)) ?? []
        sun = (try? c.decodeIfPresent(String.self, forKey: .sun)) ?? nil
    }
}

struct HairProfile: Codable, Hashable {
    var hairType: String?              // straight | wavy | curly | coily
    var thickness: String?             // fine | medium | thick
    var length: String?                // short | medium | long
    var faceShape: String?             // oval | round | square | oblong | heart | diamond
    var concerns: Set<String> = []     // receding_hairline, thinning_crown, shedding, dandruff, dryness, frizz
    var norwood: Int?                  // 1...7, self-assessed
    var isComplete: Bool { hairType != nil && faceShape != nil }
    init() {}
    enum CodingKeys: String, CodingKey { case hairType, thickness, length, faceShape, concerns, norwood }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hairType = (try? c.decodeIfPresent(String.self, forKey: .hairType)) ?? nil
        thickness = (try? c.decodeIfPresent(String.self, forKey: .thickness)) ?? nil
        length = (try? c.decodeIfPresent(String.self, forKey: .length)) ?? nil
        faceShape = (try? c.decodeIfPresent(String.self, forKey: .faceShape)) ?? nil
        concerns = (try? c.decode(Set<String>.self, forKey: .concerns)) ?? []
        norwood = (try? c.decodeIfPresent(Int.self, forKey: .norwood)) ?? nil
    }
}

/// A product the user owns, mapped onto a routine step.
struct SkinProduct: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var brand = ""
    var step: String                   // cleanser, treatment, moisturizer, spf ...
    var activeId: String?              // retinoid, aha, bha, vitamin_c, benzoyl_peroxide, niacinamide ...
    var period = "pm"                  // am | pm | both
    var frequency = "daily"            // daily | 2-3x | weekly | alternate
    var startedAt = Date()
    var weekdays: Set<Int> = []        // 1...7 (Sunday = 1) the product is used on; empty = every day
}

/// A hair or scalp intervention added to the Today checklist (ketoconazole 2x a week, minoxidil daily ...).
struct HairRoutineItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var interventionId: String?
    var schedule = "daily"             // daily | every-2-days | 2x-week | weekly (see Cadence)
    var startedAt = Date()
    var note = ""
    init(title: String, interventionId: String? = nil, schedule: String = "daily", startedAt: Date = Date(), note: String = "") {
        self.title = title; self.interventionId = interventionId; self.schedule = schedule; self.startedAt = startedAt; self.note = note
    }
    enum CodingKeys: String, CodingKey { case id, title, interventionId, schedule, startedAt, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Item"
        interventionId = (try? c.decodeIfPresent(String.self, forKey: .interventionId)) ?? nil
        schedule = (try? c.decode(String.self, forKey: .schedule)) ?? "daily"
        startedAt = (try? c.decode(Date.self, forKey: .startedAt)) ?? Date()
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
    }
}

struct ExtraCheckItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String                  // "Water", "Vitamin D" ...
}

// MARK: progress photo schedule

enum PhotoSeries: String, Codable, CaseIterable, Identifiable {
    case faceFront, faceLeft, faceRight, hairline, templeLeft, templeRight, crown, hairOverall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .faceFront: return "Face (front)"; case .faceLeft: return "Face (left)"; case .faceRight: return "Face (right)"
        case .hairline: return "Hairline"; case .templeLeft: return "Left temple"; case .templeRight: return "Right temple"
        case .crown: return "Crown (top)"; case .hairOverall: return "Hair overall"
        }
    }
    var isSkin: Bool { [.faceFront, .faceLeft, .faceRight].contains(self) }
    var tip: String {
        switch self {
        case .hairline: return "Front view, forehead visible, hair pulled back, head tilted slightly down."
        case .crown: return "Hold the phone above your head, same height each time."
        case .templeLeft, .templeRight: return "Pull hair back and turn about 45 degrees."
        default: return "Same spot, same window light, no filters."
        }
    }
}

struct PhotoSchedule: Codable, Hashable {
    var frequency = "weekly"           // daily | every2 | weekly | custom
    var customDays = 3
    var hour = 9
    var minute = 0
    var enabled = false
    var intervalDays: Int {
        switch frequency { case "daily": return 1; case "every2": return 2; case "weekly": return 7; default: return max(1, customDays) }
    }
    init() {}
    enum CodingKeys: String, CodingKey { case frequency, customDays, hour, minute, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = (try? c.decode(String.self, forKey: .frequency)) ?? "weekly"
        customDays = (try? c.decode(Int.self, forKey: .customDays)) ?? 3
        hour = (try? c.decode(Int.self, forKey: .hour)) ?? 9
        minute = (try? c.decode(Int.self, forKey: .minute)) ?? 0
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
    }
}

/// Daily calorie and protein targets: the user's own numbers, else the defaults of the goal (Cut 1,900 / 160, Maintain 2,300 / 150, Bulk 2,800 / 170).
enum DailyTargets {
    static func defaults(for goal: Goal) -> (kcal: Int, protein: Int) {
        switch goal { case .cut: return (1900, 160); case .maintain: return (2300, 150); case .bulk: return (2800, 170) }
    }
    /// Protein helper: 0.8 to 1 g per lb of body weight.
    static func proteinRange(weightLb: Double) -> ClosedRange<Int> { Int((weightLb * 0.8).rounded())...Int((weightLb * 1.0).rounded()) }
}

extension UserData {
    var dailyKcal: Int { targetCalories ?? DailyTargets.defaults(for: goal).kcal }
    var dailyProtein: Int { targetProtein ?? DailyTargets.defaults(for: goal).protein }
}
