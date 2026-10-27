import Foundation

enum CalorieSource: String, Codable, CaseIterable, Identifiable {
    case book, calculated
    var id: String { rawValue }
    var title: String { self == .book ? "Book" : "Calculated" }
}

enum SortOption: String, Codable, CaseIterable, Identifiable {
    case featured, name, caloriesAsc, proteinDesc, proteinPer100Desc, recentlyMade, rating, highFiber, healthiest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .featured: return "Featured"
        case .name: return "Name"
        case .caloriesAsc: return "Calories (low first)"
        case .proteinDesc: return "Protein (high first)"
        case .proteinPer100Desc: return "Protein per 100 kcal"
        case .recentlyMade: return "Recently made"
        case .rating: return "Rating"
        case .highFiber: return "Fiber (high first)"
        case .healthiest: return "Healthiest"
        }
    }
}

struct NutritionOverride: Codable, Hashable {
    var per100g: Nutrition
    var sourceLabel: String      // "OFF" | "Label"
    var productName: String
}

struct MadeEntry: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var recipeId: String
    var date: Date = Date()
    var rating: Int = 0
    var note: String = ""
}

struct FreezeTimer: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var recipeId: String
    var start: Date
    var readyAt: Date
    func isReady(at now: Date = Date()) -> Bool { readyAt <= now }
}

struct ShoppingItem: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var key: String?
    var text: String
    var category: String = "other"
    var grams: Double?
    var checked: Bool = false
}

struct FilterState: Codable, Equatable {
    var sources: Set<String> = []            // "book", "web"
    var tags: Set<String> = []
    var hideAffiliate = false
    var excludedBrands: Set<String> = []
    var baseKinds: Set<String> = []          // BaseKind raw values
    var shakeFlavors: Set<String> = []
    var containsKeys: Set<String> = []
    var excludesKeys: Set<String> = []
    var allergens: Set<String> = []
    var maxCalories: Double = 1500           // 1500 = no limit
    var minProtein: Double = 0               // 0 = no limit
    var canMakeNow = false
    var canMakeWithSwaps = false
    var favoritesOnly = false
    var hasVideo = false
    var madeBefore = false
    var sort: SortOption = .featured
    var mealChips: Set<String> = []
    var highFiber = false
    var courses: Set<String> = []
    var books: Set<String> = []             // source book titles
    var vegAsWritten = false
    var hasVegVersion = false
    var noEgg = false
    var section: String? = "creami"        // nil = both
    var dessertTypes: Set<String> = []
    var verdicts: Set<String> = []

    static let maxCaloriesCeiling: Double = 1500

    /// Number of active filters (sort excluded).
    var activeCount: Int {
        var n = 0
        if !sources.isEmpty { n += 1 }
        n += tags.count
        if hideAffiliate { n += 1 }
        n += excludedBrands.count
        n += baseKinds.count + shakeFlavors.count
        n += containsKeys.count + excludesKeys.count
        n += allergens.count + dessertTypes.count + verdicts.count + courses.count + books.count
        n += mealChips.count
        for b in [vegAsWritten, hasVegVersion, noEgg, highFiber] where b { n += 1 }
        if maxCalories < FilterState.maxCaloriesCeiling { n += 1 }
        if minProtein > 0 { n += 1 }
        for b in [canMakeNow, canMakeWithSwaps, favoritesOnly, hasVideo, madeBefore] where b { n += 1 }
        return n
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = (try? c.decode(Set<String>.self, forKey: .sources)) ?? []
        tags = (try? c.decode(Set<String>.self, forKey: .tags)) ?? []
        hideAffiliate = (try? c.decode(Bool.self, forKey: .hideAffiliate)) ?? false
        excludedBrands = (try? c.decode(Set<String>.self, forKey: .excludedBrands)) ?? []
        baseKinds = (try? c.decode(Set<String>.self, forKey: .baseKinds)) ?? []
        shakeFlavors = (try? c.decode(Set<String>.self, forKey: .shakeFlavors)) ?? []
        containsKeys = (try? c.decode(Set<String>.self, forKey: .containsKeys)) ?? []
        excludesKeys = (try? c.decode(Set<String>.self, forKey: .excludesKeys)) ?? []
        allergens = (try? c.decode(Set<String>.self, forKey: .allergens)) ?? []
        maxCalories = (try? c.decode(Double.self, forKey: .maxCalories)) ?? 1500
        minProtein = (try? c.decode(Double.self, forKey: .minProtein)) ?? 0
        canMakeNow = (try? c.decode(Bool.self, forKey: .canMakeNow)) ?? false
        canMakeWithSwaps = (try? c.decode(Bool.self, forKey: .canMakeWithSwaps)) ?? false
        favoritesOnly = (try? c.decode(Bool.self, forKey: .favoritesOnly)) ?? false
        hasVideo = (try? c.decode(Bool.self, forKey: .hasVideo)) ?? false
        madeBefore = (try? c.decode(Bool.self, forKey: .madeBefore)) ?? false
        sort = (try? c.decode(SortOption.self, forKey: .sort)) ?? .featured
        mealChips = (try? c.decode(Set<String>.self, forKey: .mealChips)) ?? []
        highFiber = (try? c.decode(Bool.self, forKey: .highFiber)) ?? false
        if c.contains(.section) { section = (try? c.decodeIfPresent(String.self, forKey: .section)) ?? nil } else { section = "creami" }
        dessertTypes = (try? c.decode(Set<String>.self, forKey: .dessertTypes)) ?? []
        courses = (try? c.decode(Set<String>.self, forKey: .courses)) ?? []
        books = (try? c.decode(Set<String>.self, forKey: .books)) ?? []
        vegAsWritten = (try? c.decode(Bool.self, forKey: .vegAsWritten)) ?? false
        hasVegVersion = (try? c.decode(Bool.self, forKey: .hasVegVersion)) ?? false
        noEgg = (try? c.decode(Bool.self, forKey: .noEgg)) ?? false
        verdicts = (try? c.decode(Set<String>.self, forKey: .verdicts)) ?? []
    }
}

/// Everything the user owns; saved as one JSON file.
struct UserData: Codable, Equatable {
    var favorites: Set<String> = []
    var recipeMilk: [String: String] = [:]
    var defaultMilkId: String?
    var swaps: [String: [String: Int]] = [:]       // recipeId -> lineKey -> swap index
    var pints: [String: Int] = [:]
    var defaultCalorieSource: CalorieSource = .book
    var recipeCalorieSource: [String: CalorieSource] = [:]
    var optionalOn: [String: Set<String>] = [:]    // recipeId -> ticked optional line keys
    var pantryMissing: Set<String> = []
    var nutritionOverrides: [String: NutritionOverride] = [:]
    var customLiquids: [BaseLiquid] = []
    var defaultPowderId: String?
    var recipePowder: [String: String] = [:]
    var customPowders: [ProteinPowder] = []
    var madeLog: [MadeEntry] = []
    var freezer: [FreezeTimer] = []
    var shopping: [ShoppingItem] = []
    var filterState = FilterState()
    var notificationsAsked = false
    var isVegetarian = true
    var preferEasyAlternatives = true
    var vegChoice: [String: [String: String]] = [:]   // recipeId -> lineKey -> alternative key
    var avoidsEggs = false
    var showOriginal: Set<String> = []     // recipe ids viewed as written instead of the vegetarian version

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        favorites = (try? c.decode(Set<String>.self, forKey: .favorites)) ?? []
        recipeMilk = (try? c.decode([String: String].self, forKey: .recipeMilk)) ?? [:]
        defaultMilkId = (try? c.decodeIfPresent(String.self, forKey: .defaultMilkId)) ?? nil
        swaps = (try? c.decode([String: [String: Int]].self, forKey: .swaps)) ?? [:]
        pints = (try? c.decode([String: Int].self, forKey: .pints)) ?? [:]
        defaultCalorieSource = (try? c.decode(CalorieSource.self, forKey: .defaultCalorieSource)) ?? .book
        recipeCalorieSource = (try? c.decode([String: CalorieSource].self, forKey: .recipeCalorieSource)) ?? [:]
        optionalOn = (try? c.decode([String: Set<String>].self, forKey: .optionalOn)) ?? [:]
        pantryMissing = (try? c.decode(Set<String>.self, forKey: .pantryMissing)) ?? []
        nutritionOverrides = (try? c.decode([String: NutritionOverride].self, forKey: .nutritionOverrides)) ?? [:]
        customLiquids = (try? c.decode([BaseLiquid].self, forKey: .customLiquids)) ?? []
        defaultPowderId = (try? c.decodeIfPresent(String.self, forKey: .defaultPowderId)) ?? nil
        recipePowder = (try? c.decode([String: String].self, forKey: .recipePowder)) ?? [:]
        customPowders = (try? c.decode([ProteinPowder].self, forKey: .customPowders)) ?? []
        madeLog = (try? c.decode([MadeEntry].self, forKey: .madeLog)) ?? []
        freezer = (try? c.decode([FreezeTimer].self, forKey: .freezer)) ?? []
        shopping = (try? c.decode([ShoppingItem].self, forKey: .shopping)) ?? []
        filterState = (try? c.decode(FilterState.self, forKey: .filterState)) ?? FilterState()
        preferEasyAlternatives = (try? c.decode(Bool.self, forKey: .preferEasyAlternatives)) ?? true
        vegChoice = (try? c.decode([String: [String: String]].self, forKey: .vegChoice)) ?? [:]
        isVegetarian = (try? c.decode(Bool.self, forKey: .isVegetarian)) ?? true
        avoidsEggs = (try? c.decode(Bool.self, forKey: .avoidsEggs)) ?? false
        showOriginal = (try? c.decode(Set<String>.self, forKey: .showOriginal)) ?? []
        notificationsAsked = (try? c.decode(Bool.self, forKey: .notificationsAsked)) ?? false
    }
}
