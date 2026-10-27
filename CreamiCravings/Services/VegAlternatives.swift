import Foundation

struct VegOption {
    var alt: VegAlt
    var grams: Double
    var nutrition: Nutrition          // for the whole recipe
    var deltaPerServing: Nutrition    // versus the default alternative
    var isDefault: Bool
}

struct VegLineAlt {
    var lineKey: String
    var original: Ing
    var roleId: String
    var roleLabel: String
    var options: [VegOption]
    var defaultKey: String
    var chosenKey: String
    var chosen: VegOption? { options.first { $0.alt.key == chosenKey } }
}

struct VegResolution {
    var recipe: Recipe                // the vegetarian version with the chosen alternatives applied
    var lines: [String: VegLineAlt]   // by line key
}

enum VegAlternatives {
    static func round5(_ g: Double) -> Double { max(5, (g / 5).rounded() * 5) }

    /// Builds the vegetarian version of `recipe`, swapping in ranked alternatives (see SPEC "Ranked vegetarian alternatives").
    static func resolve(_ recipe: Recipe, catalog: Catalog, choices: [String: String], preferEasy: Bool) -> VegResolution {
        guard let adapt = recipe.vegAdaptation else { return VegResolution(recipe: recipe, lines: [:]) }
        var r = recipe.vegVersion()
        guard let data = catalog.vegAlts else { return VegResolution(recipe: r, lines: [:]) }
        let calc = NutritionCalculator(catalog: catalog)
        let servings = Double(max(1, recipe.servings ?? 1))
        var macros = r.macros
        var nameAlt: VegAlt?
        var steps = r.instructions
        var prep: [String] = []
        var out: [String: VegLineAlt] = [:]

        for (lk, ing) in recipe.allLines {
            guard let swap = adapt.swaps.first(where: { $0.replaces == ing.text }),
                  let (roleId, role) = data.role(forKey: ing.key, text: ing.text, recipeName: recipe.name), !role.alternatives.isEmpty else { continue }
            let origInfo = catalog.info(ing.key)
            let origGrams = calc.grams(ing, origInfo)
            // Book meat weights are raw: the role's meatPer100g wins, the catalog entry is the fallback.
            let meat = role.meatPer100g ?? origInfo?.per100g
            guard origGrams > 0, let meat, meat.protein > 0 else { continue }
            let keyed = ing.key.map { k in data.keyToRole[k] != nil || data.roles.values.contains { $0.matchKeys.contains(k) } } ?? false
            guard keyed || (origInfo?.vegetarian == .no && (origInfo?.per100g.protein ?? 0) >= 10) else { continue }

            let authoredGrams = calc.grams(swap.with, catalog.info(swap.with.key))
            let defaultIdx = role.alternatives.firstIndex { $0.key == swap.with.key || ($0.aliasKeys.contains(swap.with.key ?? "")) }
            let defaultAlt = defaultIdx.map { role.alternatives[$0] }
            // Every alternative, the default included, is compared at protein-matched grams (original meat grams x meat protein / alt protein).
            func matchedGrams(_ per100: Nutrition) -> Double? { per100.protein > 0 ? round5(origGrams * meat.protein / per100.protein) : nil }
            let defaultPer100 = defaultAlt?.per100g ?? catalog.info(swap.with.key)?.per100g
            let defaultMatchedNut: Nutrition = defaultPer100.flatMap { p in matchedGrams(p).map { p * ($0 / 100) } }
                ?? (defaultPer100 ?? .zero) * (authoredGrams / 100)
            let easy = role.alternatives.first { $0.availability == "everywhere" }
            let fallbackKey = defaultAlt?.key ?? role.alternatives[0].key
            let chosenKey: String
            if let k = choices[lk], role.alternatives.contains(where: { $0.key == k }) { chosenKey = k }
            else if preferEasy, let e = easy { chosenKey = e.key }
            else { chosenKey = fallbackKey }

            var options: [VegOption] = []
            for alt in role.alternatives {
                let isDef = alt.key == defaultAlt?.key
                let g = matchedGrams(alt.per100g) ?? authoredGrams
                let nut = alt.per100g * (g / 100)
                options.append(VegOption(alt: alt, grams: isDef ? authoredGrams : g, nutrition: nut,
                                         deltaPerServing: isDef ? .zero : (nut - defaultMatchedNut) * (1 / servings), isDefault: isDef))
            }
            out[lk] = VegLineAlt(lineKey: lk, original: ing, roleId: roleId, roleLabel: role.label, options: options,
                                 defaultKey: defaultAlt?.key ?? "", chosenKey: chosenKey)
            if nameAlt == nil, let o = options.first(where: { $0.alt.key == chosenKey }) { nameAlt = o.alt }

            guard let opt = options.first(where: { $0.alt.key == chosenKey }) else { continue }
            if let p = opt.alt.prep, !p.isEmpty { prep.append("\(opt.alt.name): \(p)") }
            if chosenKey == defaultAlt?.key { continue }

            let newIng = Ing(text: "\(Int(opt.grams)) g \(opt.alt.name)", key: opt.alt.key, grams: opt.grams, optional: swap.with.optional)
            if let i = r.base.firstIndex(where: { $0.text == swap.with.text }), lk.hasPrefix("b") { r.base[i] = newIng }
            else if let i = r.mixIns.firstIndex(where: { $0.text == swap.with.text }) { r.mixIns[i] = newIng }
            if let m = macros { macros = m + NutritionCalculator.proportional(opt.nutrition - defaultMatchedNut, printed: m, catalog: defaultMatchedNut) }

            var names = [defaultAlt?.name, catalog.ingredients[swap.with.key ?? ""]?.name, stripQuantity(swap.with.text)].compactMap { $0 }
            names = Array(Set(names.filter { $0.count >= 3 })).sorted { $0.count > $1.count }
            steps = steps.map { step in names.reduce(step) { s, n in s.replacingOccurrences(of: n, with: opt.alt.name, options: .caseInsensitive) } }
        }
        if !prep.isEmpty { steps.insert("Prep: " + prep.joined(separator: " "), at: 0) }
        r.instructions = steps
        r.macros = macros
        if let alt = nameAlt {
            let short = shortName(alt)
            r.name = replaceMeatWords(in: r.name, with: short)
            r.base = r.base.map { retitled($0, short) }
            r.mixIns = r.mixIns.map { retitled($0, short) }
        }
        return VegResolution(recipe: r, lines: out)
    }

    private static let meatRegex = try? NSRegularExpression(
        pattern: "\\b(steak|beef|chicken|pork|bacon|sausages?|shrimp|prawns?|fish|turkey|ham|lamb|tuna|salmon)\\b", options: [.caseInsensitive])

    /// Short display name of an alternative: "Extra-firm tofu" -> "Tofu"; bacon and sausage alternatives keep "Veggie".
    static func shortName(_ alt: VegAlt) -> String {
        let n = alt.name.lowercased(), k = alt.key.lowercased()
        func has(_ w: String) -> Bool { n.contains(w) || k.contains(w) }
        if has("bacon") { return "Veggie bacon" }
        if has("sausage") { return "Veggie sausage" }
        if has("pepperoni") { return "Veggie pepperoni" }
        if has("tofu") { return "Tofu" }
        if has("seitan") { return "Seitan" }
        if has("paneer") { return "Paneer" }
        if has("tempeh") { return "Tempeh" }
        if has("soy") && has("chunk") { return "Soy chunks" }
        if has("soy") { return "Soy" }
        if has("jackfruit") { return "Jackfruit" }
        if has("mushroom") { return "Mushroom" }
        if has("chickpea") { return "Chickpea" }
        if has("plant") || has("impossible") || has("beyond") || has("vegan") || has("quorn") || has("mycoprotein") { return "Plant-based" }
        return alt.name.split(separator: " ").first.map { String($0).capitalized } ?? alt.name
    }

    static func replaceMeatWords(in text: String, with short: String) -> String {
        guard let rx = meatRegex else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let word = ns.substring(with: m.range)
            out += (word.first?.isLowercase ?? false) ? short.prefix(1).lowercased() + short.dropFirst() : short
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// "Seasoned Beef: 30 ml soy sauce" -> "Seasoned Tofu: 30 ml soy sauce" (only the label before the first colon changes).
    private static func retitled(_ ing: Ing, _ short: String) -> Ing {
        guard let c = ing.text.firstIndex(of: ":"), ing.text.distance(from: ing.text.startIndex, to: c) <= 40 else { return ing }
        var out = ing
        out.text = replaceMeatWords(in: String(ing.text[..<c]), with: short) + ing.text[c...]
        return out
    }

    /// "250 g extra-firm tofu" -> "extra-firm tofu".
    static func stripQuantity(_ text: String) -> String {
        let units: Set<String> = ["g", "kg", "ml", "l", "oz", "lb", "cup", "cups", "tbsp", "tsp", "of"]
        var words = text.split(separator: " ").map(String.init)
        while let w = words.first, (w.first.map { $0.isNumber || "½⅓⅔¼¾".contains($0) } ?? false) || units.contains(w.lowercased()) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
