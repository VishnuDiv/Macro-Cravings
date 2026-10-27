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

    /// Everything that can change a recipe's displayed numbers or title, hashed.
    private func signature(_ r: Recipe, _ cfg: RecipeConfig) -> Int {
        var h = Hasher()
        h.combine(cfg.milk?.id); h.combine(cfg.powder?.id); h.combine(cfg.vegActive); h.combine(cfg.vegChoices); h.combine(cfg.preferEasy)
        h.combine(cfg.swaps); h.combine(cfg.pints); h.combine(cfg.source.rawValue); h.combine(cfg.optionalOn); h.combine(cfg.overrides)
        return h.finalize()
    }

    /// Cached displayed macros + title for a recipe; recomputed only when its relevant choices change.
    func display(for r: Recipe, catalog: Catalog) -> Display {
        let cfg = config(for: r, catalog: catalog)
        let sig = signature(r, cfg)
        if let hit = displayCache.items[r.id], hit.sig == sig { return hit.value }
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

    func isFavorite(_ id: String) -> Bool { data.favorites.contains(id) }
    func toggleFavorite(_ id: String) {
        if data.favorites.contains(id) { data.favorites.remove(id) } else { data.favorites.insert(id) }
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

    func effectiveRecipe(_ r: Recipe, catalog: Catalog) -> Recipe {
        vegActive(r) ? VegAlternatives.resolve(r, catalog: catalog, choices: data.vegChoice[r.id] ?? [:], preferEasy: data.preferEasyAlternatives).recipe : r
    }

    func vegResolution(_ r: Recipe, catalog: Catalog) -> VegResolution {
        VegAlternatives.resolve(r, catalog: catalog, choices: data.vegChoice[r.id] ?? [:], preferEasy: data.preferEasyAlternatives)
    }

    func calorieSource(for id: String) -> CalorieSource { data.recipeCalorieSource[id] ?? data.defaultCalorieSource }

    func config(for r: Recipe, catalog: Catalog) -> RecipeConfig {
        RecipeConfig(milk: milk(for: r.id, catalog: catalog), powder: powder(for: r.id, catalog: catalog), vegActive: vegActive(r), vegChoices: data.vegChoice[r.id] ?? [:], preferEasy: data.preferEasyAlternatives, swaps: data.swaps[r.id] ?? [:],
                     pints: max(1, min(5, data.pints[r.id] ?? 1)), source: calorieSource(for: r.id),
                     overrides: data.nutritionOverrides, optionalOn: data.optionalOn[r.id] ?? [],
                     missing: data.pantryMissing)
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
