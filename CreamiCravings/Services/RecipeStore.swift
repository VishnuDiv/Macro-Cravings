import Foundation
import Observation

/// Kinds of base for the "Base liquid" filter.
enum BaseKind: String, CaseIterable, Identifiable, Codable {
    case ultraFiltered, proteinShake, milk, cream, plant, yogurt, fruit, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultraFiltered: return "Fat-free ultra-filtered milk"
        case .proteinShake: return "Protein shake"
        case .milk: return "Regular milk"
        case .cream: return "Heavy cream"
        case .plant: return "Plant milk"
        case .yogurt: return "Yogurt / cottage cheese"
        case .fruit: return "Fruit / juice"
        case .other: return "Other"
        }
    }
}

/// Ingredient catalog plus helpers that tolerate missing entries.
struct Catalog {
    var ingredients: [String: IngredientInfo] = [:]
    var liquids: [BaseLiquid] = []
    var powders: [ProteinPowder] = []
    var sourceBrands: [String: String] = [:]
    var guides: [Guide] = []
    var paneer: PaneerModel?
    var vegAlts: VegAlternativesData? {
        didSet { vegInfo = Catalog.buildVegInfo(vegAlts) }
    }
    /// Catalog-style entries synthesized from veg alternatives, so their nutrition and names resolve.
    private(set) var vegInfo: [String: IngredientInfo] = [:]

    static func buildVegInfo(_ d: VegAlternativesData?) -> [String: IngredientInfo] {
        var out: [String: IngredientInfo] = [:]
        for role in (d?.roles ?? [:]).values {
            for a in role.alternatives where out[a.key] == nil { out[a.key] = IngredientInfo(name: a.name, category: "other", per100g: a.per100g) }
        }
        return out
    }

    func info(_ key: String?) -> IngredientInfo? {
        guard let key else { return nil }
        return ingredients[key] ?? vegInfo[key]
    }

    func isShake(_ ing: Ing) -> Bool {
        if let i = info(ing.key) { return i.category == "protein_shake" }
        return (ing.key ?? "").hasPrefix("protein_shake")
    }

    func isLiquidBase(_ ing: Ing) -> Bool {
        if let i = info(ing.key) { return IngCategory.liquidBase.contains(i.category) }
        let k = ing.key ?? ""
        return k.contains("milk") && !k.contains("powder") || k.hasPrefix("protein_shake")
    }

    /// Line key (e.g. "b0") of the base liquid line, if any.
    func liquidLineKey(_ r: Recipe) -> String? {
        for (i, ing) in r.base.enumerated() where isLiquidBase(ing) { return Recipe.lineKey(base: true, index: i) }
        return nil
    }

    func isPowderLine(_ ing: Ing) -> Bool {
        if let i = info(ing.key), i.category == "protein_powder" { return true }
        let k = ing.key ?? ""
        return k.hasPrefix("protein_powder") || k == "casein_powder" || k == "collagen_powder"
    }

    /// Line key of the protein powder line, if the recipe has one.
    func powderLineKey(_ r: Recipe) -> String? {
        r.allLines.first { isPowderLine($0.ing) }?.key
    }

    func baseKind(_ r: Recipe) -> (BaseKind, String?) {
        for ing in r.base {
            let k = ing.key ?? ""
            let cat = info(ing.key)?.category ?? ""
            if isShake(ing) {
                let flavor = k.hasPrefix("protein_shake_") ? String(k.dropFirst("protein_shake_".count)) : nil
                return (.proteinShake, flavor)
            }
            if k.contains("ultra_filtered") { return (.ultraFiltered, nil) }
            if cat == "plant_milk" || k.contains("almond_milk") || k.contains("oat_milk") || k.contains("soy_milk") || k.contains("coconut_milk") { return (.plant, nil) }
            if k.contains("heavy_cream") || k.contains("half_and_half") || k == "cream" { return (.cream, nil) }
            if k.contains("yogurt") || k.contains("cottage") { return (.yogurt, nil) }
            if cat == "milk" || (k.contains("milk") && !k.contains("powder")) { return (.milk, nil) }
            if cat == "fruit" || k.contains("juice") { return (.fruit, nil) }
        }
        return (.other, nil)
    }
}

/// Precomputed per-recipe lookups (search text, base kind, keys, allergens, brands).
struct RecipeIndex {
    var haystack: String
    var baseKind: BaseKind
    var shakeFlavor: String?
    var keys: Set<String>
    var requiredKeys: [String]
    var allergens: Set<String>
    var brands: Set<String>
    var hasAffiliate: Bool
    var vegAsWritten: Bool
    var hasVegVersion: Bool
    var noEgg: Bool
    var chips: Set<String>
    var highFiber: Bool
}

struct LoadedData {
    var recipes: [Recipe] = []
    var catalog = Catalog()
}

@MainActor @Observable
final class RecipeStore {
    private(set) var recipes: [Recipe] = []
    private(set) var catalog = Catalog()
    private(set) var index: [String: RecipeIndex] = [:]
    private(set) var recipeByID: [String: Recipe] = [:]
    private(set) var isLoaded = false
    private(set) var hasDrinks = false
    private(set) var bookTitles: [String] = []     // books that have meals

    init() {}

    func apply(_ d: LoadedData) {
        recipes = d.recipes
        catalog = d.catalog
        recipeByID = Dictionary(d.recipes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        index = RecipeStore.buildIndex(d.recipes, d.catalog)
        hasDrinks = d.recipes.contains { $0.section == "drink" }
        bookTitles = Set(d.recipes.filter { $0.section == "meal" && $0.source.isBook }.compactMap { $0.source.title }).sorted()
        isLoaded = true
    }

    func loadAsync() async {
        let d = await Task.detached(priority: .userInitiated) { RecipeStore.loadData() }.value
        apply(d)
    }

    var affiliateBrands: [String] {
        Set(catalog.ingredients.values.compactMap { $0.affiliate?.brand }).sorted()
    }
    var webSiteCount: Int { Set(recipes.compactMap { $0.source.isBook ? nil : $0.source.site }).count }

    // MARK: loading

    nonisolated static func findResource(_ name: String, ext: String, in dir: URL?, bundle: Bundle) -> URL? {
        if let dir {
            let u = dir.appendingPathComponent(name + "." + ext)
            return FileManager.default.fileExists(atPath: u.path) ? u : nil
        }
        for sub in [nil, "Resources", "Photos", "Resources/Photos"] as [String?] {
            if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: sub) { return u }
        }
        return nil
    }

    /// Reads recipes + catalog. `dir` overrides the bundle (used by the logic checks).
    nonisolated static func loadData(dir: URL? = nil, bundle: Bundle = .main) -> LoadedData {
        var out = LoadedData()
        if let u = findResource("recipes", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.recipes = decodeRecipes(data)
        }
        if let u = findResource("ingredients", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u),
           let m = try? JSONDecoder().decode([String: IngredientInfo].self, from: data) {
            out.catalog.ingredients = m
        }
        if let u = findResource("base_liquids", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.catalog.liquids = decodeLenient([BaseLiquid].self, data)
        }
        if let u = findResource("protein_powders", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.catalog.powders = decodeLenient([ProteinPowder].self, data)
        }
        if let u = findResource("source_powder_brands", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u),
           let m = try? JSONDecoder().decode([String: String].self, from: data) {
            out.catalog.sourceBrands = m
        }
        if let u = findResource("guides", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.catalog.guides = decodeLenient([Guide].self, data)
        }
        if let u = findResource("paneer_model", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.catalog.paneer = try? JSONDecoder().decode(PaneerModel.self, from: data)
        }
        if let u = findResource("veg_alternatives", ext: "json", in: dir, bundle: bundle), let data = try? Data(contentsOf: u) {
            out.catalog.vegAlts = try? JSONDecoder().decode(VegAlternativesData.self, from: data)
        }
        return out
    }

    /// Decodes an array, skipping elements that fail.
    nonisolated static func decodeLenient<T: Decodable>(_ type: [T].Type, _ data: Data) -> [T] {
        guard let boxes = try? JSONDecoder().decode([LenientBox<T>].self, from: data) else { return [] }
        return boxes.compactMap { $0.v }
    }

    nonisolated static func decodeRecipes(_ data: Data) -> [Recipe] { decodeLenient([Recipe].self, data) }

    nonisolated static func buildIndex(_ recipes: [Recipe], _ cat: Catalog) -> [String: RecipeIndex] {
        var out: [String: RecipeIndex] = [:]
        for r in recipes {
            let ings = r.allIngredients
            var keys = Set<String>(), allergens = Set<String>(), brands = Set<String>()
            for i in ings {
                guard let k = i.key else { continue }
                keys.insert(k)
                if let info = cat.info(k) {
                    allergens.formUnion(info.allergens)
                    if let a = info.affiliate { brands.insert(a.brand) }
                }
            }
            let hay = ([r.name] + ings.map { $0.text } + r.tags + [r.source.site ?? "", r.source.title ?? "", r.dessertType ?? "", r.method ?? "", r.isDessert ? "dessert" : "", r.course ?? "", r.cuisine ?? "", r.bookCategory ?? "", (r.vegAdaptation?.swaps.map { $0.with.text }.joined(separator: " ") ?? ""), r.section == "meal" ? "meal" : ""])
                .joined(separator: " ")
            let (kind, flavor) = cat.baseKind(r)
            out[r.id] = RecipeIndex(
                haystack: FilterEngine.normalize(hay), baseKind: kind, shakeFlavor: flavor, keys: keys,
                requiredKeys: ings.filter { !$0.optional }.compactMap { $0.key },
                allergens: allergens, brands: brands, hasAffiliate: !brands.isEmpty,
                vegAsWritten: r.vegetarian ?? !keys.contains { cat.info($0)?.vegetarian == .no },
                hasVegVersion: r.vegAdaptation != nil,
                noEgg: r.containsEgg.map { !$0 } ?? !allergens.contains("egg"),
                chips: r.mealChipMatches(keys: keys), highFiber: r.isHighFiber)
        }
        return out
    }
}
