import Foundation

enum CalorieSource: String, Codable, CaseIterable, Identifiable {
    case book, calculated
    var id: String { rawValue }
    var title: String { self == .book ? "Book" : "Calculated" }
}

/// The user's nutrition goal. It never hides recipes: it changes the default sort, adds badges and offers a filter.
enum Goal: String, Codable, CaseIterable, Identifiable {
    case cut, maintain, bulk
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { self == .cut ? "arrow.down.circle" : (self == .bulk ? "arrow.up.circle" : "equal.circle") }
    /// What "Featured" sorts as under this goal.
    var defaultSort: SortOption { self == .cut ? .healthiest : (self == .bulk ? .proteinDesc : .featured) }

    /// What the recipe is as written (per serving; per pint for Creami): Cut, Bulk or Maintain.
    static func original(_ n: Nutrition, bookTitle: String?) -> Goal {
        if isCutFriendly(n) { return .cut }
        if isBulkFriendly(n, bookTitle: bookTitle) { return .bulk }
        return .maintain
    }
    var letter: String { self == .cut ? "C" : (self == .bulk ? "B" : "M") }

    static let bulkBook = "The Ultimate Guide to Lean Bulking"

    /// Cut-friendly: protein density >= 10 g per 100 kcal (protein x 10 >= kcal) and kcal <= 550. Per serving (per pint for Creami).
    static func isCutFriendly(_ n: Nutrition) -> Bool { n.calories > 0 && n.protein * 10 >= n.calories && n.calories <= 550 }
    /// Bulk-friendly: kcal >= 600 and protein >= 35 g, or a recipe from the Lean Bulking book.
    static func isBulkFriendly(_ n: Nutrition, bookTitle: String?) -> Bool {
        (n.calories >= 600 && n.protein >= 35) || bookTitle == bulkBook
    }
}

enum SortOption: String, Codable, CaseIterable, Identifiable {
    case featured, quickest, name, caloriesAsc, proteinDesc, proteinPer100Desc, recentlyMade, rating, highFiber, healthiest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .featured: return "Featured"
        case .quickest: return "Quickest"
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
    var estimated = false          // the grams are a guess (shown as "≈ 20 g (est.)")
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
    var proteinDensity: Double = 0           // g protein per 100 kcal, 0 = off
    var cutOnly = false
    var hasUpgrade = false
    var vegan = false
    var bulkOnly = false

    static let proteinDensitySteps: [Double] = [0, 5, 7.5, 10, 12.5, 15]
    static let maxCaloriesCeiling: Double = 1500

    /// Number of active filters (sort and section excluded); one per pill.
    var activeCount: Int { activePills().count }

    struct Pill: Identifiable, Hashable {
        var id: String          // "kind:value", understood by remove(pill:)
        var label: String
    }

    private static func pretty(_ s: String) -> String { s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized }
    private static func number(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(d) }

    /// One pill per active filter, in a stable order, for the active-filter row. `keyName` resolves ingredient keys to names.
    func activePills(keyName: (String) -> String = { FilterState.pretty($0) }) -> [Pill] {
        var out: [Pill] = []
        func add(_ kind: String, _ value: String, _ label: String) { out.append(Pill(id: kind + ":" + value, label: label)) }
        if favoritesOnly { add("flag", "favoritesOnly", "Saved") }
        for s in sources.sorted() { add("source", s, s == "book" ? "Book" : "Web") }
        if vegan { add("flag", "vegan", "Vegan") }
        if hasUpgrade { add("flag", "hasUpgrade", "Has protein upgrade") }
        if cutOnly { add("flag", "cutOnly", "Cut-friendly") }
        if bulkOnly { add("flag", "bulkOnly", "Bulk-friendly") }
        if proteinDensity > 0 { add("flag", "proteinDensity", "≥ \(FilterState.number(proteinDensity)) g P/100 kcal") }
        for c in courses.sorted() { add("course", c, FilterState.pretty(c)) }
        for c in mealChips.sorted() { add("chip", c, Recipe.mealChips.first { $0.id == c }?.title ?? FilterState.pretty(c)) }
        for b in books.sorted() { add("book", b, b.replacingOccurrences(of: "The Ultimate ", with: "")) }
        for d in dessertTypes.sorted() { add("dessertType", d, FilterState.pretty(d)) }
        for v in verdicts.sorted() { add("verdict", v, FilterState.pretty(v)) }
        for t in tags.sorted() { add("tag", t, FilterState.pretty(t)) }
        if hideAffiliate { add("flag", "hideAffiliate", "No affiliate products") }
        for b in excludedBrands.sorted() { add("brand", b, "No \(b)") }
        for k in baseKinds.sorted() { add("base", k, BaseKind(rawValue: k)?.title ?? FilterState.pretty(k)) }
        for k in shakeFlavors.sorted() { add("shake", k, "\(FilterState.pretty(k)) shake") }
        for k in containsKeys.sorted() { add("contains", k, "Has \(keyName(k))") }
        for k in excludesKeys.sorted() { add("excludes", k, "No \(keyName(k))") }
        for a in allergens.sorted() { add("allergen", a, "No \(FilterState.pretty(a))") }
        if vegAsWritten { add("flag", "vegAsWritten", "Vegetarian as written") }
        if hasVegVersion { add("flag", "hasVegVersion", "Has veg version") }
        if noEgg { add("flag", "noEgg", "No egg") }
        if highFiber { add("flag", "highFiber", "High fiber") }
        if maxCalories < FilterState.maxCaloriesCeiling { add("flag", "maxCalories", "Max \(Int(maxCalories)) kcal") }
        if minProtein > 0 { add("flag", "minProtein", "Min \(Int(minProtein)) g protein") }
        if canMakeNow { add("flag", "canMakeNow", "Can make now") }
        if canMakeWithSwaps { add("flag", "canMakeWithSwaps", "Can make with swaps") }
        if hasVideo { add("flag", "hasVideo", "Has video") }
        if madeBefore { add("flag", "madeBefore", "Made before") }
        return out
    }

    /// Removes exactly the filter a pill stands for; every other filter stays.
    mutating func remove(pill id: String) {
        guard let colon = id.firstIndex(of: ":") else { return }
        let kind = String(id[..<colon]), v = String(id[id.index(after: colon)...])
        switch kind {
        case "source": sources.remove(v)
        case "course": courses.remove(v)
        case "chip": mealChips.remove(v)
        case "book": books.remove(v)
        case "dessertType": dessertTypes.remove(v)
        case "verdict": verdicts.remove(v)
        case "tag": tags.remove(v)
        case "brand": excludedBrands.remove(v)
        case "base": baseKinds.remove(v)
        case "shake": shakeFlavors.remove(v)
        case "contains": containsKeys.remove(v)
        case "excludes": excludesKeys.remove(v)
        case "allergen": allergens.remove(v)
        case "flag":
            switch v {
            case "favoritesOnly": favoritesOnly = false
            case "cutOnly": cutOnly = false
            case "hasUpgrade": hasUpgrade = false
            case "vegan": vegan = false
            case "bulkOnly": bulkOnly = false
            case "proteinDensity": proteinDensity = 0
            case "hideAffiliate": hideAffiliate = false
            case "vegAsWritten": vegAsWritten = false
            case "hasVegVersion": hasVegVersion = false
            case "noEgg": noEgg = false
            case "highFiber": highFiber = false
            case "maxCalories": maxCalories = FilterState.maxCaloriesCeiling
            case "minProtein": minProtein = 0
            case "canMakeNow": canMakeNow = false
            case "canMakeWithSwaps": canMakeWithSwaps = false
            case "hasVideo": hasVideo = false
            case "madeBefore": madeBefore = false
            default: break
            }
        default: break
        }
    }

    /// Clears every filter but keeps the section and the sort.
    mutating func clearFilters() {
        let keepSection = section, keepSort = sort
        self = FilterState()
        section = keepSection; sort = keepSort
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
        proteinDensity = (try? c.decode(Double.self, forKey: .proteinDensity)) ?? 0
        cutOnly = (try? c.decode(Bool.self, forKey: .cutOnly)) ?? false
        hasUpgrade = (try? c.decode(Bool.self, forKey: .hasUpgrade)) ?? false
        vegan = (try? c.decode(Bool.self, forKey: .vegan)) ?? false
        bulkOnly = (try? c.decode(Bool.self, forKey: .bulkOnly)) ?? false
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
    var goal: Goal = .maintain
    var saved: [String: Goal] = [:]                 // recipeId -> goal it was saved for (replaces the old star)
    var savedMigrated = true                        // false only while decoding an old file
    var ratings: [String: Int] = [:]                // recipeId -> 1...5 stars
    var recipeGoal: [String: Goal] = [:]            // per-recipe version (Cut / Maintain / Bulk); default = the global goal
    var useEstimates = true                         // guess amounts for lines that have none
    var lineGrams: [String: [String: Double]] = [:] // recipeId -> lineKey -> grams typed by the user
    var proteinBoosts: [String: Set<String>] = [:]  // recipeId -> chosen "Add protein" boost ids
    var upgradeChoice: [String: String] = [:]       // recipeId -> protein upgrade alternative key (absent = original)
    var goalToggles: [String: [String: Bool]] = [:] // recipeId -> change id -> on/off (overrides the default)
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
        goal = (try? c.decode(Goal.self, forKey: .goal)) ?? .maintain
        saved = (try? c.decode([String: Goal].self, forKey: .saved)) ?? [:]
        ratings = (try? c.decode([String: Int].self, forKey: .ratings)) ?? [:]
        recipeGoal = (try? c.decode([String: Goal].self, forKey: .recipeGoal)) ?? [:]
        useEstimates = (try? c.decode(Bool.self, forKey: .useEstimates)) ?? true
        lineGrams = (try? c.decode([String: [String: Double]].self, forKey: .lineGrams)) ?? [:]
        proteinBoosts = (try? c.decode([String: Set<String>].self, forKey: .proteinBoosts)) ?? [:]
        upgradeChoice = (try? c.decode([String: String].self, forKey: .upgradeChoice)) ?? [:]
        goalToggles = (try? c.decode([String: [String: Bool]].self, forKey: .goalToggles)) ?? [:]
        // One-time migration: old stars become "Saved for Maintain", and are kept.
        if !((try? c.decode(Bool.self, forKey: .savedMigrated)) ?? false) {
            for id in favorites where saved[id] == nil { saved[id] = .maintain }
            favorites = []
        }
        savedMigrated = true
        notificationsAsked = (try? c.decode(Bool.self, forKey: .notificationsAsked)) ?? false
    }
}
