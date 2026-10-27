import Foundation
import Observation

@MainActor @Observable
final class UserStore {
    var data: UserData {
        didSet { if data != oldValue { scheduleSave() } }
    }
    private let fileURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// `fileURL == nil` keeps everything in memory (previews, tests).
    init(fileURL: URL? = UserStore.defaultURL()) {
        self.fileURL = fileURL
        self.data = fileURL.map { UserStore.loadData(at: $0) } ?? UserData()
    }

    nonisolated static func defaultURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let app = dir.appendingPathComponent("CreamiCravings", isDirectory: true)
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app.appendingPathComponent("userdata.json")
    }

    /// Missing or corrupt file gives fresh data; the corrupt file is kept as .corrupt.
    nonisolated static func loadData(at url: URL) -> UserData {
        guard let raw = try? Data(contentsOf: url) else { return UserData() }
        if let d = decode(raw) { return d }
        try? FileManager.default.removeItem(at: url.appendingPathExtension("corrupt"))
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        return UserData()
    }

    nonisolated static func decode(_ raw: Data) -> UserData? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(UserData.self, from: raw)
    }

    nonisolated static func encode(_ d: UserData) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(d)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    func flush() {
        guard let url = fileURL, let bytes = UserStore.encode(data) else { return }
        try? bytes.write(to: url, options: .atomic)
    }

    // MARK: cached display values (cards, filters, sorting)

    struct Display {
        var displayed: Nutrition      // whole recipe/pint, in the active calorie source
        var estimated: Bool
        var title: String             // veg title when the veg version is shown
        var vegTitle: Bool
    }

    private final class DisplayCache { var items: [String: (sig: Int, value: Display)] = [:] }
    @ObservationIgnored private let displayCache = DisplayCache()

    /// Everything that can change a recipe's displayed numbers or title, hashed straight from the stored choices
    /// (cheap; the heavy config and goal resolution only run on a cache miss). Goal versions are not part of it:
    /// cards, filters and sorts always use the recipe as written.
    private func signature(_ r: Recipe) -> Int {
        var h = Hasher()
        h.combine(data.recipeMilk[r.id] ?? data.defaultMilkId); h.combine(data.recipePowder[r.id] ?? data.defaultPowderId)
        h.combine(data.isVegetarian); h.combine(data.showOriginal.contains(r.id)); h.combine(data.vegChoice[r.id] ?? [:]); h.combine(data.preferEasyAlternatives)
        h.combine(data.swaps[r.id] ?? [:]); h.combine(data.pints[r.id]); h.combine(calorieSource(for: r.id).rawValue)
        h.combine(data.optionalOn[r.id] ?? []); h.combine(data.nutritionOverrides)
        h.combine(data.useEstimates); h.combine(data.lineGrams[r.id] ?? [:])
        return h.finalize()
    }

    /// Cached displayed macros + title for a recipe; recomputed only when its relevant choices change.
    func display(for r: Recipe, catalog: Catalog) -> Display {
        let sig = signature(r)
        if let hit = displayCache.items[r.id], hit.sig == sig { return hit.value }
        let cfg = config(for: r, catalog: catalog, applyGoal: false)
        let calc = NutritionCalculator(catalog: catalog)
        let res = calc.compute(r, cfg)
        var title = r.name
        if cfg.vegActive { title = VegAlternatives.resolve(r, catalog: catalog, choices: cfg.vegChoices, preferEasy: cfg.preferEasy).recipe.name }
        let v = Display(displayed: res.displayed, estimated: res.estimated, title: title, vegTitle: title != r.name)
        displayCache.items[r.id] = (sig, v)
        return v
    }

    /// Fills the display cache in small chunks so the first sort/filter by calories is instant and the UI never stalls.
    func warmCache(_ recipes: [Recipe], catalog: Catalog) async {
        for (i, r) in recipes.enumerated() {
            _ = display(for: r, catalog: catalog)
            if i % 40 == 39 { await Task.yield() }
        }
    }

    // MARK: accessors

    // MARK: saved (per goal), rating, goal version

    func isSaved(_ id: String) -> Bool { data.saved[id] != nil }
    func savedGoal(_ id: String) -> Goal? { data.saved[id] }
    func save(_ id: String, for goal: Goal) { data.saved[id] = goal }
    func unsave(_ id: String) { data.saved[id] = nil }

    func rating(_ id: String) -> Int { data.ratings[id] ?? 0 }
    /// Setting the same rating again clears it.
    func setRating(_ id: String, _ stars: Int) {
        if stars <= 0 || data.ratings[id] == stars { data.ratings[id] = nil } else { data.ratings[id] = min(5, stars) }
    }

    /// The version (Cut / Maintain / Bulk) shown for a recipe: its own choice, else the global goal.
    func versionGoal(_ id: String) -> Goal { data.recipeGoal[id] ?? data.goal }
    func setVersion(_ id: String, _ goal: Goal) { data.recipeGoal[id] = (goal == data.goal) ? nil : goal }
    func setChange(_ recipeId: String, _ changeId: String, _ on: Bool) {
        var m = data.goalToggles[recipeId] ?? [:]
        m[changeId] = on
        data.goalToggles[recipeId] = m
    }

    /// The goal version's changes and resulting config for the recipe (Maintain: no changes).
    func goalResolution(_ r: Recipe, catalog: Catalog) -> GoalResolution {
        let base = config(for: r, catalog: catalog, applyGoal: false)
        return GoalVersion.resolve(r, catalog: catalog, base: base, goal: versionGoal(r.id),
                                   toggles: data.goalToggles[r.id] ?? [:], vegetarianUser: data.isVegetarian)
    }

    func allLiquids(_ catalog: Catalog) -> [BaseLiquid] {
        data.customLiquids.map { var l = $0; l.family = "custom"; return l } + catalog.liquids
    }

    func milk(for recipeId: String, catalog: Catalog) -> BaseLiquid? {
        let id = data.recipeMilk[recipeId] ?? data.defaultMilkId
        guard let id else { return nil }
        return (data.customLiquids + catalog.liquids).first { $0.id == id }
    }

    func allPowders(_ catalog: Catalog) -> [ProteinPowder] {
        data.customPowders.map { var p = $0; p.type = "custom"; return p } + catalog.powders
    }

    func powder(for recipeId: String, catalog: Catalog) -> ProteinPowder? {
        guard let id = data.recipePowder[recipeId] ?? data.defaultPowderId else { return nil }
        return (data.customPowders + catalog.powders).first { $0.id == id }
    }

    /// True when the vegetarian version of this recipe is the one in use.
    func vegActive(_ r: Recipe) -> Bool {
        data.isVegetarian && r.vegAdaptation != nil && r.vegetarian != true && !data.showOriginal.contains(r.id)
    }

    /// The recipe as shown: vegetarian version first, then the protein upgrade (title, lines, steps, macros).
    func effectiveRecipe(_ r: Recipe, catalog: Catalog) -> Recipe {
        ProteinUpgrades.effective(r, catalog: catalog, vegActive: vegActive(r), vegChoices: data.vegChoice[r.id] ?? [:],
                                  preferEasy: data.preferEasyAlternatives, upgradeKey: data.upgradeChoice[r.id])
    }

    /// The "Protein upgrade" card data (wings / crispy bites), built on the vegetarian version of the recipe.
    func upgradeCard(_ r: Recipe, catalog: Catalog) -> UpgradeCardData? {
        guard r.proteinUpgrade != nil else { return nil }
        let base = ProteinUpgrades.effective(r, catalog: catalog, vegActive: vegActive(r), vegChoices: data.vegChoice[r.id] ?? [:],
                                             preferEasy: data.preferEasyAlternatives, upgradeKey: nil)
        return ProteinUpgrades.card(for: base, catalog: catalog, choice: data.upgradeChoice[r.id])
    }

    func upgradeChoice(_ id: String) -> String? { data.upgradeChoice[id] }
    func setUpgrade(_ id: String, _ key: String?) { data.upgradeChoice[id] = key }

    func vegResolution(_ r: Recipe, catalog: Catalog) -> VegResolution {
        VegAlternatives.resolve(r, catalog: catalog, choices: data.vegChoice[r.id] ?? [:], preferEasy: data.preferEasyAlternatives)
    }

    func calorieSource(for id: String) -> CalorieSource { data.recipeCalorieSource[id] ?? data.defaultCalorieSource }

    /// The user's choices for a recipe. `applyGoal` adds the Cut / Bulk version last (detail, shopping list, cook mode);
    /// cards, filters and sorts pass false and use the recipe as written.
    func config(for r: Recipe, catalog: Catalog, applyGoal: Bool = true) -> RecipeConfig {
        var base = RecipeConfig(milk: milk(for: r.id, catalog: catalog), powder: powder(for: r.id, catalog: catalog), vegActive: vegActive(r), vegChoices: data.vegChoice[r.id] ?? [:], preferEasy: data.preferEasyAlternatives, upgradeKey: applyGoal ? data.upgradeChoice[r.id] : nil, swaps: data.swaps[r.id] ?? [:],
                     pints: max(1, min(5, data.pints[r.id] ?? 1)), source: calorieSource(for: r.id),
                     overrides: data.nutritionOverrides, optionalOn: data.optionalOn[r.id] ?? [],
                     missing: data.pantryMissing)
        base.useEstimates = data.useEstimates
        base.userGrams = data.lineGrams[r.id] ?? [:]
        guard applyGoal, versionGoal(r.id) != .maintain else { return base }
        return GoalVersion.resolve(r, catalog: catalog, base: base, goal: versionGoal(r.id),
                                   toggles: data.goalToggles[r.id] ?? [:], vegetarianUser: data.isVegetarian).cfg
    }

    /// The user's own amount for a line with no amount in the recipe; nil or 0 removes it.
    func setLineGrams(_ recipeId: String, line: String, grams: Double?) {
        var m = data.lineGrams[recipeId] ?? [:]
        if let g = grams, g > 0 { m[line] = g } else { m[line] = nil }
        data.lineGrams[recipeId] = m.isEmpty ? nil : m
    }

    func setSwap(_ recipeId: String, line: String, index: Int?) {
        var m = data.swaps[recipeId] ?? [:]
        m[line] = index
        data.swaps[recipeId] = m.isEmpty ? nil : m
    }

    func setMissing(_ key: String, _ missing: Bool) {
        if missing { data.pantryMissing.insert(key) } else { data.pantryMissing.remove(key) }
    }

    func toggleOptional(_ recipeId: String, line: String) {
        var s = data.optionalOn[recipeId] ?? []
        if s.contains(line) { s.remove(line) } else { s.insert(line) }
        data.optionalOn[recipeId] = s.isEmpty ? nil : s
    }

    func logMade(recipeId: String, rating: Int, note: String) {
        data.madeLog.insert(MadeEntry(recipeId: recipeId, rating: rating, note: note), at: 0)
    }

    @discardableResult
    func startTimer(for r: Recipe, now: Date = Date()) -> FreezeTimer {
        let t = FreezeTimer(recipeId: r.id, start: now, readyAt: now.addingTimeInterval(r.timerHours * 3600))
        data.freezer.append(t)
        return t
    }
}
