import Foundation

struct RecipeSource: Codable, Hashable {
    var kind: String          // "book" | "web"
    var title: String?
    var page: Int?
    var site: String?
    var url: String?
    var alsoIn: String?            // same recipe in another book, e.g. "The Ultimate Guide to Lean Bulking p.33"

    var isBook: Bool { kind == "book" }

    enum CodingKeys: String, CodingKey { case kind, title, page, site, url, alsoIn }
    init(kind: String = "web", title: String? = nil, page: Int? = nil, site: String? = nil, url: String? = nil) {
        self.kind = kind; self.title = title; self.page = page; self.site = site; self.url = url
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "web"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        page = (try? c.decodeIfPresent(Int.self, forKey: .page)) ?? nil
        site = (try? c.decodeIfPresent(String.self, forKey: .site)) ?? nil
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        alsoIn = (try? c.decodeIfPresent(String.self, forKey: .alsoIn)) ?? nil
    }
}

struct ProTip: Codable, Hashable {
    var title: String
    var text: String
    enum CodingKeys: String, CodingKey { case title, text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Pro tip"
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

struct Evidence: Codable, Hashable {
    var verdict: String            // proven | promising | unverified
    var rating: Double?
    var ratingCount: Int?
    var summary: String?
    var commonFixes: [String]

    enum CodingKeys: String, CodingKey { case verdict, rating, ratingCount, summary, commonFixes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = (try? c.decodeIfPresent(String.self, forKey: .verdict)) ?? "unverified"
        rating = (try? c.decodeIfPresent(Double.self, forKey: .rating)) ?? nil
        ratingCount = (try? c.decodeIfPresent(Int.self, forKey: .ratingCount)) ?? nil
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        commonFixes = (try? c.decodeIfPresent([String].self, forKey: .commonFixes)) ?? []
    }
}

struct VegSwap: Codable, Hashable {
    var replaces: String
    var with: Ing
    var note: String?

    enum CodingKeys: String, CodingKey { case replaces, with, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        replaces = try c.decode(String.self, forKey: .replaces)
        with = try c.decode(Ing.self, forKey: .with)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }
}

struct VegAdaptation: Codable, Hashable {
    var summary: String
    var swaps: [VegSwap]
    var steps: [String]
    var macrosPerServing: Nutrition?

    enum CodingKeys: String, CodingKey { case summary, swaps, steps, macrosPerServing }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        steps = (try? c.decodeIfPresent([String].self, forKey: .steps)) ?? []
        macrosPerServing = (try? c.decodeIfPresent(Nutrition.self, forKey: .macrosPerServing)) ?? nil
        swaps = decodeLenientArray(from: c, key: .swaps)
    }
}

/// The air-fryer version of a fried recipe: swapped lines (oil, coatings), new steps and per-serving macros.
struct AirFry: Codable, Hashable {
    var summary: String
    var swaps: [VegSwap]
    var steps: [String]
    var macrosPerServing: Nutrition?   // nil = calculated from the ingredient lines
    var textureNote: String?

    enum CodingKeys: String, CodingKey { case summary, swaps, steps, macrosPerServing, textureNote }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        steps = (try? c.decodeIfPresent([String].self, forKey: .steps)) ?? []
        macrosPerServing = (try? c.decodeIfPresent(Nutrition.self, forKey: .macrosPerServing)) ?? nil
        textureNote = (try? c.decodeIfPresent(String.self, forKey: .textureNote)) ?? nil
        swaps = decodeLenientArray(from: c, key: .swaps)
    }
}

struct Recipe: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var source: RecipeSource
    var photo: String?
    var photoURL: String?          // remote photo of a web recipe when there is no bundled one
    var videoURL: String?
    var macros: Nutrition?
    var pintSize: String
    var prepMinutes: Int?
    var freezeHours: Int
    var base: [Ing]
    var mixIns: [Ing]
    var instructions: [String]
    var proTip: ProTip?
    var tags: [String]
    var section: String            // "creami" | "dessert"
    var dessertType: String?
    var creamiType: String?        // Creami only: ice_cream | lite_ice_cream | sorbet | gelato | frozen_yogurt | milkshake | smoothie_bowl | italian_ice | frozen_drink
    var method: String?
    var servings: Int?
    var cookMinutes: Int?
    var chillHours: Double?
    var evidence: Evidence?
    var servingLabel: String?      // "piece" when a serving is one piece
    var course: String?
    var cuisine: String?
    var bookCategory: String?
    var vegetarian: Bool?          // nil = not stated (Creami recipes)
    var containsEgg: Bool?
    var vegAdaptation: VegAdaptation?
    var airFry: AirFry?            // air-fryer version of a fried recipe
    var alreadyAirFried: Bool?     // cooked in the air fryer or oven as written (no fried version needed)
    var proteinUpgrade: ProteinUpgradeRef?
    var proteinBoost: Bool?        // overnight oats under 20 g protein: offers the optional "Add protein" boosts

    /// "serving" or "piece" (per-piece recipes such as nuggets and falafel).
    var servingNoun: String { servingLabel == "piece" ? "piece" : "serving" }

    private static let meatWords = try? NSRegularExpression(
        pattern: "\\b(chicken|beef|steak|pork|(?<!veggie )bacon|turkey|ham|(?<!veggie )sausages?|shrimp|prawns?|salmon|tuna|fish)\\b", options: [.caseInsensitive])

    /// The pro tip for the user's diet. In vegetarian mode, sentences that mention meat or fish are dropped; nil when nothing is left.
    func proTip(vegMode: Bool) -> ProTip? {
        guard let tip = proTip, !tip.text.isEmpty else { return nil }
        guard vegMode, let rx = Recipe.meatWords else { return tip }
        let sentences = tip.text.components(separatedBy: CharacterSet(charactersIn: "\n")).flatMap { line -> [String] in
            var out: [String] = [], cur = ""
            for ch in line {
                cur.append(ch)
                if ".!?".contains(ch) { out.append(cur); cur = "" }
            }
            if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
            return out
        }
        let kept = sentences.filter { s in rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return nil }
        var t = tip; t.text = kept.joined(separator: " ")
        return t
    }

    var isDessert: Bool { section == "dessert" }
    /// Everything except Ninja Creami pints is measured in servings.
    var usesServings: Bool { section != "creami" }
    /// Divide whole-recipe macros by this for the per-serving view (desserts only).
    var perServingDivisor: Double { usesServings ? Double(max(1, servings ?? 1)) : 1 }
    /// Hours until the timer fires (freeze for Creami, chill/bake for desserts).
    var timerHours: Double {
        guard usesServings else { return Double(freezeHours) }
        if section == "meal" || section == "drink" {
            if let m = cookMinutes, m > 0 { return Double(m) / 60 }
            if let c = chillHours, c > 0 { return c }
            return 0.25
        }
        if let c = chillHours, c > 0 { return c }
        if let m = cookMinutes, m > 0 { return Double(m) / 60 }
        return 1
    }
    /// Timer button label, or nil when the recipe has no time to run.
    var timerLabel: String? {
        if !usesServings { return "Freeze" }
        if section == "dessert" {
            if let c = chillHours, c > 0 { return "Chill" }
            return (cookMinutes ?? 0) > 0 ? "Timer" : nil
        }
        return (cookMinutes ?? 0) > 0 || (chillHours ?? 0) > 0 ? "Timer" : nil
    }
    var readyVerb: String { usesServings ? "ready to eat" : "ready to spin" }

    enum CodingKeys: String, CodingKey {
        case id, name, source, photo, photoURL, videoURL, macros, pintSize, prepMinutes, freezeHours
        case base, mixIns, instructions, proTip, tags
        case proteinUpgrade, proteinBoost, servingLabel, course, cuisine, bookCategory, vegetarian, containsEgg, vegAdaptation, airFry, alreadyAirFried
        case section, dessertType, creamiType, method, servings, cookMinutes, chillHours, evidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nm = try c.decode(String.self, forKey: .name)
        name = nm
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? nm.lowercased()
        source = (try? c.decodeIfPresent(RecipeSource.self, forKey: .source)) ?? RecipeSource()
        photo = (try? c.decodeIfPresent(String.self, forKey: .photo)) ?? nil
        photoURL = (try? c.decodeIfPresent(String.self, forKey: .photoURL)) ?? nil
        videoURL = (try? c.decodeIfPresent(String.self, forKey: .videoURL)) ?? nil
        macros = (try? c.decodeIfPresent(Nutrition.self, forKey: .macros)) ?? nil
        pintSize = (try? c.decodeIfPresent(String.self, forKey: .pintSize)) ?? "standard"
        prepMinutes = (try? c.decodeIfPresent(Int.self, forKey: .prepMinutes)) ?? nil
        freezeHours = (try? c.decodeIfPresent(Int.self, forKey: .freezeHours)) ?? 16
        base = (try? c.decodeIfPresent([Ing].self, forKey: .base)) ?? []
        mixIns = (try? c.decodeIfPresent([Ing].self, forKey: .mixIns)) ?? []
        instructions = (try? c.decodeIfPresent([String].self, forKey: .instructions)) ?? []
        proTip = (try? c.decodeIfPresent(ProTip.self, forKey: .proTip)) ?? nil
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        section = (try? c.decodeIfPresent(String.self, forKey: .section)) ?? "creami"
        if !Recipe.sections.contains(section) { section = "creami" }
        dessertType = (try? c.decodeIfPresent(String.self, forKey: .dessertType)) ?? nil
        creamiType = (try? c.decodeIfPresent(String.self, forKey: .creamiType)) ?? nil
        method = (try? c.decodeIfPresent(String.self, forKey: .method)) ?? nil
        servings = (try? c.decodeIfPresent(Int.self, forKey: .servings)) ?? nil
        cookMinutes = (try? c.decodeIfPresent(Int.self, forKey: .cookMinutes)) ?? nil
        chillHours = (try? c.decodeIfPresent(Double.self, forKey: .chillHours)) ?? nil
        evidence = (try? c.decodeIfPresent(Evidence.self, forKey: .evidence)) ?? nil
        servingLabel = (try? c.decodeIfPresent(String.self, forKey: .servingLabel)) ?? nil
        proteinUpgrade = (try? c.decodeIfPresent(ProteinUpgradeRef.self, forKey: .proteinUpgrade)) ?? nil
        proteinBoost = (try? c.decodeIfPresent(Bool.self, forKey: .proteinBoost)) ?? nil
        cuisine = (try? c.decodeIfPresent(String.self, forKey: .cuisine)) ?? nil
        course = (try? c.decodeIfPresent(String.self, forKey: .course)) ?? nil
        bookCategory = (try? c.decodeIfPresent(String.self, forKey: .bookCategory)) ?? nil
        vegetarian = (try? c.decodeIfPresent(Bool.self, forKey: .vegetarian)) ?? nil
        containsEgg = (try? c.decodeIfPresent(Bool.self, forKey: .containsEgg)) ?? nil
        vegAdaptation = (try? c.decodeIfPresent(VegAdaptation.self, forKey: .vegAdaptation)) ?? nil
        airFry = (try? c.decodeIfPresent(AirFry.self, forKey: .airFry)) ?? nil
        alreadyAirFried = (try? c.decodeIfPresent(Bool.self, forKey: .alreadyAirFried)) ?? nil
    }

    /// Stable key for a line, used by swaps: "b0", "m2".
    static func lineKey(base: Bool, index: Int) -> String { (base ? "b" : "m") + String(index) }

    var allLines: [(key: String, ing: Ing)] {
        base.enumerated().map { (Recipe.lineKey(base: true, index: $0.offset), $0.element) }
            + mixIns.enumerated().map { (Recipe.lineKey(base: false, index: $0.offset), $0.element) }
    }

    var allIngredients: [Ing] { base + mixIns }

    static let sections = ["creami", "dessert", "meal", "drink"]
    static let courses = ["breakfast", "lunch", "dinner", "snack", "side", "sauce"]

    /// The vegetarian version of the recipe: swapped lines, steps and macros (per serving × servings).
    func vegVersion() -> Recipe {
        guard let v = vegAdaptation else { return self }
        var r = self
        func rep(_ lines: [Ing]) -> [Ing] { lines.map { ing in v.swaps.first { $0.replaces == ing.text }?.with ?? ing } }
        r.base = rep(base); r.mixIns = rep(mixIns)
        if !v.steps.isEmpty { r.instructions = v.steps }
        if let m = v.macrosPerServing { r.macros = m * Double(max(1, servings ?? 1)) }
        r.vegetarian = true
        return r
    }

    /// The air-fryer version, applied on top of whatever version is current (vegetarian first): oil and coating lines swapped, new
    /// lines (`replaces` = "") appended to the base, air-fry steps and macros (per serving x servings). Macros nil = calculated.
    func airFryVersion() -> Recipe {
        guard let a = airFry, !a.steps.isEmpty else { return self }
        var r = self
        func rep(_ lines: [Ing]) -> [Ing] { lines.map { ing in a.swaps.first { !$0.replaces.isEmpty && $0.replaces == ing.text }?.with ?? ing } }
        r.base = rep(base) + a.swaps.filter { $0.replaces.isEmpty }.map(\.with)
        r.mixIns = rep(mixIns)
        r.instructions = a.steps
        if let m = a.macrosPerServing { r.macros = m * Double(max(1, servings ?? 1)) }
        if !r.tags.contains("air-fryer") { r.tags.append("air-fryer") }
        return r
    }

    /// In the Filters "Air fryer" option: has an air-fryer version, or is air-fried / baked as written.
    var isAirFryerRecipe: Bool { airFry != nil || alreadyAirFried == true || tags.contains("air-fryer") }

    static let cuisines = ["pizza", "wings", "indian", "indo-chinese", "chinese", "thai", "korean", "japanese", "mexican", "italian", "american", "mediterranean", "other"]

    /// Meal quick-chips: id, title.
    static let mealChips: [(id: String, title: String)] = [
        ("pizza", "Pizza"), ("wings", "Wings"), ("tofu", "Tofu"), ("paneer", "Paneer"), ("pasta", "Pasta"), ("noodles", "Noodles"), ("indian", "Indian"),
        ("indo-chinese", "Indo-Chinese"), ("chinese", "Chinese"), ("thai", "Thai"), ("korean", "Korean"), ("ramen", "Ramen"), ("sushi", "Sushi"),
        ("spicy", "Spicy"), ("breakfast", "Breakfast"), ("cookies", "Cookies"), ("high-fiber", "High Fiber"),
    ]
    static let highFiberGrams = 8.0

    /// Which meal chips this recipe matches (cuisine, tag, course or ingredient key as fits each chip).
    func mealChipMatches(keys: Set<String>) -> Set<String> {
        var out = Set<String>()
        let n = name.lowercased()
        let c = (cuisine ?? "").lowercased()
        func has(_ t: String) -> Bool { tags.contains(t) }
        if c == "pizza" || has("pizza") || n.contains("pizza") { out.insert("pizza") }
        if c == "wings" || has("wings") || n.contains("wing") { out.insert("wings") }
        if keys.contains(where: { $0.contains("tofu") }) { out.insert("tofu") }
        if keys.contains(where: { $0.contains("paneer") }) { out.insert("paneer") }
        let spacedKeys = keys.map { $0.replacingOccurrences(of: "_", with: " ") }
        let nameWords = Set(n.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let pastaWords = ["pasta", "spaghetti", "penne", "macaroni", "rigatoni", "fusilli", "linguine", "fettuccine", "lasagna", "gnocchi"]
        let pastaNames = ["pasta", "spaghetti", "penne", "lasagna", "alfredo", "carbonara", "bolognese", "macaroni"]
        if c == "italian" || has("pasta") || spacedKeys.contains(where: { k in pastaWords.contains { k.contains($0) } })
            || pastaNames.contains(where: { n.contains($0) }) || nameWords.contains("mac") { out.insert("pasta") }
        let noodleWords = ["noodle", "ramen", "udon", "soba", "lo mein", "chow mein", "rice noodle", "pad thai", "hakka"]
        if has("noodles") || has("noodle") || has("ramen") || spacedKeys.contains(where: { k in noodleWords.contains { k.contains($0) } })
            || noodleWords.contains(where: { n.contains($0) }) { out.insert("noodles") }
        for k in ["indian", "indo-chinese", "chinese", "thai", "korean"] where c == k { out.insert(k) }
        if has("ramen") || n.contains("ramen") { out.insert("ramen") }
        if has("sushi") || ["sushi", "maki", "nigiri", "temaki", "onigiri", "inari", "uramaki", "gunkan", "musubi"].contains(where: { n.contains($0) }) { out.insert("sushi") }
        if has("spicy") { out.insert("spicy") }
        if course == "breakfast" { out.insert("breakfast") }
        if has("cookies") || has("cookie") || dessertType == "cookie" { out.insert("cookies") }
        if isHighFiber { out.insert("high-fiber") }
        return out
    }

    /// Fiber >= 8 g per serving (printed macros), or the high-fiber tag.
    var isHighFiber: Bool {
        if tags.contains("high-fiber") { return true }
        guard let m = macros else { return false }
        return m.fiber / perServingDivisor >= Recipe.highFiberGrams
    }

    static let creamiTypes: [(id: String, title: String)] = [
        ("ice_cream", "Ice cream"), ("lite_ice_cream", "Lite ice cream"), ("sorbet", "Sorbet"), ("gelato", "Gelato"), ("frozen_yogurt", "Frozen yogurt"),
        ("milkshake", "Milkshake"), ("smoothie_bowl", "Smoothie bowl"), ("italian_ice", "Italian ice"), ("frozen_drink", "Frozen drink")]
    var creamiTypeTitle: String? { creamiType.flatMap { t in Recipe.creamiTypes.first { $0.id == t }?.title } }
    static let dessertTypes = ["cheesecake", "brownie", "cookie", "mousse", "pudding", "bar", "cake", "other"]
    static let verdicts = ["proven", "promising", "unverified"]

    static let vocabulary = ["healthy", "high-protein", "low-calorie", "indulgent", "keto", "low-sugar", "sorbet", "fruit", "gelato",
                             "frozen-yogurt", "milkshake", "lite-ice-cream", "dairy-free", "vegan", "copycat", "chocolate", "vanilla",
                             "peanut-butter", "coffee", "cookies", "caramel", "mint", "cheesecake", "cake", "seasonal", "boozy", "nut-free",
                             "high-calorie", "meal-prep", "air-fryer", "quick", "spicy", "high-fiber", "ramen", "pizza", "wings"]
}
