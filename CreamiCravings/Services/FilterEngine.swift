import Foundation

struct FilterContext {
    var favorites: Set<String> = []
    var missing: Set<String> = []
    var madeLog: [MadeEntry] = []
    var ratings: [String: Int] = [:]          // the user's own 1...5 star ratings
    /// Displayed macros for a recipe (user's default milk, source setting).
    var displayed: (Recipe) -> Nutrition = { $0.macros ?? .zero }
}

enum FilterEngine {
    /// Lowercase, diacritic-free text for searching.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func tokens(_ q: String) -> [String] {
        normalize(q).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func matches(query: [String], haystack: String) -> Bool {
        query.allSatisfy { haystack.contains($0) }
    }

    static func canMakeNow(_ idx: RecipeIndex, missing: Set<String>) -> Bool {
        !idx.requiredKeys.contains { missing.contains($0) }
    }

    static func canMakeWithSwaps(_ r: Recipe, _ idx: RecipeIndex, missing: Set<String>, catalog: Catalog) -> Bool {
        for ing in r.allIngredients where !ing.optional {
            guard let k = ing.key, missing.contains(k) else { continue }
            guard let info = catalog.info(k) else { return false }
            let ok = info.swaps.contains { s in
                guard let sk = s.key else { return true }
                return !missing.contains(sk)
            }
            if !ok { return false }
        }
        return true
    }

    @MainActor static func apply(store: RecipeStore, recipes: [Recipe], query: String, state f: FilterState, ctx: FilterContext) -> [Recipe] {
        let q = tokens(query)
        let catalog = store.catalog
        var made: [String: Date] = [:]
        var ratings: [String: [Int]] = [:]
        for e in ctx.madeLog {
            if let d = made[e.recipeId] { made[e.recipeId] = max(d, e.date) } else { made[e.recipeId] = e.date }
            if e.rating > 0 { ratings[e.recipeId, default: []].append(e.rating) }
        }

        var cache: [String: Nutrition] = [:]
        func macros(_ r: Recipe) -> Nutrition {
            if let n = cache[r.id] { return n }
            let n = ctx.displayed(r); cache[r.id] = n; return n
        }

        let out = recipes.filter { r in
            guard let idx = store.index[r.id] else { return false }
            if !q.isEmpty && !matches(query: q, haystack: idx.haystack) { return false }
            if let s = f.section, r.section != s { return false }
            if !f.dessertTypes.isEmpty && !f.dessertTypes.contains(r.dessertType ?? "other") { return false }
            if !f.verdicts.isEmpty && !f.verdicts.contains(r.evidence?.verdict ?? "unverified") { return false }
            if !f.courses.isEmpty && !f.courses.contains(r.course ?? "") { return false }
            if !f.books.isEmpty && !f.books.contains(r.source.title ?? "") { return false }
            if !f.mealChips.isEmpty && f.mealChips.isDisjoint(with: idx.chips) { return false }
            if f.highFiber && !idx.highFiber { return false }
            if f.hasUpgrade && !idx.hasUpgrade { return false }
            if f.vegan && !idx.vegan { return false }
            if f.vegAsWritten && !idx.vegAsWritten { return false }
            if f.hasVegVersion && !idx.hasVegVersion { return false }
            if f.noEgg && !idx.noEgg { return false }
            if f.favoritesOnly && !ctx.favorites.contains(r.id) { return false }
            if !f.sources.isEmpty && !f.sources.contains(r.source.kind) { return false }
            if !f.tags.isEmpty && f.tags.isDisjoint(with: r.tags) { return false }
            if f.hideAffiliate && idx.hasAffiliate { return false }
            if !f.excludedBrands.isEmpty && !f.excludedBrands.isDisjoint(with: idx.brands) { return false }
            if !f.baseKinds.isEmpty && !f.baseKinds.contains(idx.baseKind.rawValue) { return false }
            if !f.shakeFlavors.isEmpty {
                guard idx.baseKind == .proteinShake, let fl = idx.shakeFlavor, f.shakeFlavors.contains(fl) else { return false }
            }
            if !f.containsKeys.isEmpty && f.containsKeys.isDisjoint(with: idx.keys) { return false }
            if !f.excludesKeys.isEmpty && !f.excludesKeys.isDisjoint(with: idx.keys) { return false }
            if !f.allergens.isEmpty && !f.allergens.isDisjoint(with: idx.allergens) { return false }
            if f.hasVideo && (r.videoURL ?? "").isEmpty { return false }
            if f.madeBefore && made[r.id] == nil { return false }
            if f.canMakeNow && !canMakeNow(idx, missing: ctx.missing) { return false }
            if f.canMakeWithSwaps && !canMakeWithSwaps(r, idx, missing: ctx.missing, catalog: catalog) { return false }
            if f.maxCalories < FilterState.maxCaloriesCeiling || f.minProtein > 0 {
                let m = macros(r)
                if f.maxCalories < FilterState.maxCaloriesCeiling && m.calories > f.maxCalories { return false }
                if f.minProtein > 0 && m.protein < f.minProtein { return false }
            }
            if f.proteinDensity > 0 {
                // protein per 100 kcal >= density; recipes without printed macros are excluded while this is on
                guard r.macros != nil else { return false }
                let m = macros(r)
                if m.calories <= 0 || m.protein * 100 < f.proteinDensity * m.calories { return false }
            }
            if f.cutOnly && !Goal.isCutFriendly(macros(r)) { return false }
            if f.bulkOnly && !Goal.isBulkFriendly(macros(r), bookTitle: r.source.title) { return false }
            return true
        }

        func byName(_ a: Recipe, _ b: Recipe) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func featuredRank(_ r: Recipe) -> Int {
            if r.source.isBook && r.photo != nil { return 0 }
            if r.evidence?.verdict == "proven" || r.macros != nil { return 1 }
            return 2
        }
        switch f.sort {
        case .quickest:
            // total time = prep + cook (chill and freeze excluded); unknown times last
            func total(_ r: Recipe) -> Int? { (r.prepMinutes == nil && r.cookMinutes == nil) ? nil : (r.prepMinutes ?? 0) + (r.cookMinutes ?? 0) }
            return out.sorted {
                switch (total($0), total($1)) {
                case let (a?, b?): return a != b ? a < b : byName($0, $1)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName($0, $1)
                }
            }
        case .featured:
            return out.sorted { featuredRank($0) != featuredRank($1) ? featuredRank($0) < featuredRank($1) : byName($0, $1) }
        case .highFiber:
            return out.sorted { macros($0).fiber != macros($1).fiber ? macros($0).fiber > macros($1).fiber : byName($0, $1) }
        case .healthiest:
            return out.sorted {
                let a = macros($0), b = macros($1)
                if a.proteinPer100kcal != b.proteinPer100kcal { return a.proteinPer100kcal > b.proteinPer100kcal }
                return a.fiber != b.fiber ? a.fiber > b.fiber : byName($0, $1)
            }
        case .name: return out.sorted(by: byName)
        case .caloriesAsc: return out.sorted { macros($0).calories != macros($1).calories ? macros($0).calories < macros($1).calories : byName($0, $1) }
        case .proteinDesc: return out.sorted { macros($0).protein != macros($1).protein ? macros($0).protein > macros($1).protein : byName($0, $1) }
        case .proteinPer100Desc:
            return out.sorted { macros($0).proteinPer100kcal != macros($1).proteinPer100kcal ? macros($0).proteinPer100kcal > macros($1).proteinPer100kcal : byName($0, $1) }
        case .recentlyMade:
            return out.sorted {
                switch (made[$0.id], made[$1.id]) {
                case let (a?, b?): return a != b ? a > b : byName($0, $1)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName($0, $1)
                }
            }
        case .rating:
            // the user's own star rating wins; the made-log average is the fallback
            func avg(_ r: Recipe) -> Double {
                if let own = ctx.ratings[r.id], own > 0 { return Double(own) }
                let v = ratings[r.id] ?? []; return v.isEmpty ? 0 : Double(v.reduce(0, +)) / Double(v.count)
            }
            return out.sorted { avg($0) != avg($1) ? avg($0) > avg($1) : byName($0, $1) }
        }
    }
}
