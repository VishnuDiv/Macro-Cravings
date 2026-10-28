import Foundation

struct UpgradeOption {
    var key: String?                 // nil = the original base
    var alt: VegAlt?
    var label: String                // "Original" / "Tofu"
    var grams: Double                // as listed in the recipe (dry weight for soy chunks)
    var nutrition: Nutrition         // whole recipe amount
    var deltaPerServing: Nutrition   // versus the original base at the same weight
}

struct UpgradeCardData {
    var roleLabel: String
    var baseName: String             // "Cauliflower"
    var lineIndex: Int
    var weight: Double               // grams of the base line
    var options: [UpgradeOption]
    var chosenKey: String?
    var chosen: UpgradeOption? { options.first { $0.key == chosenKey } }
}

/// Wings / crispy bites protein upgrade: replaces the vegetable base (cauliflower, chickpeas, ...) with tofu, paneer, seitan or soy
/// chunks at the same weight. Applied after the vegetarian version and before the Cut / Bulk goal changes.
enum ProteinUpgrades {
    private static let baseWords: [String: [String]] = [
        "cauliflower": ["cauliflower florets", "cauliflower", "florets", "gobi"],
        "broccoli": ["broccoli florets", "broccoli", "florets"],
        "chickpeas": ["chickpeas", "chickpea", "garbanzo beans"],
        "mushrooms": ["mushrooms", "mushroom"],
    ]

    static func role(for r: Recipe, catalog: Catalog) -> (role: UpgradeRole, lineIndex: Int)? {
        guard let ref = r.proteinUpgrade, let role = catalog.vegAlts?.upgrades[ref.role], r.base.indices.contains(ref.lineIndex),
              !role.alternatives.isEmpty else { return nil }
        return (role, ref.lineIndex)
    }

    /// Vegetarian version first, then the air-fryer version, then the protein upgrade.
    static func effective(_ recipe: Recipe, catalog: Catalog, vegActive: Bool, vegChoices: [String: String], preferEasy: Bool, upgradeKey: String?, airFry: Bool = false) -> Recipe {
        var veg = vegActive ? VegAlternatives.resolve(recipe, catalog: catalog, choices: vegChoices, preferEasy: preferEasy).recipe : recipe
        if airFry { veg = veg.airFryVersion() }
        guard let key = upgradeKey else { return veg }
        return apply(veg, catalog: catalog, choice: key)
    }

    private static func isSoyChunks(_ a: VegAlt) -> Bool { a.key.contains("soy_chunks") }

    /// Amount of the alternative for a base of `weight` grams: the same weight, except soy chunks (dry weight = weight / 3).
    static func altGrams(_ alt: VegAlt, weight: Double) -> Double { isSoyChunks(alt) ? (weight / 3).rounded() : weight.rounded() }

    static func card(for r: Recipe, catalog: Catalog, choice: String?) -> UpgradeCardData? {
        guard let (role, idx) = role(for: r, catalog: catalog) else { return nil }
        let calc = NutritionCalculator(catalog: catalog)
        let line = r.base[idx]
        let weight = calc.grams(line, catalog.info(line.key))
        guard weight > 0 else { return nil }
        let servings = Double(max(1, r.servings ?? 1))
        let baseNut = role.basePer100g * (weight / 100)
        var opts = [UpgradeOption(key: nil, alt: nil, label: "Original", grams: weight, nutrition: baseNut, deltaPerServing: .zero)]
        for alt in role.alternatives {
            let g = altGrams(alt, weight: weight)
            let nut = alt.per100g * (g / 100)
            opts.append(UpgradeOption(key: alt.key, alt: alt, label: VegAlternatives.shortName(alt), grams: g, nutrition: nut,
                                      deltaPerServing: (nut - baseNut) * (1 / servings)))
        }
        return UpgradeCardData(roleLabel: role.label, baseName: baseName(of: line), lineIndex: idx, weight: weight, options: opts,
                               chosenKey: role.alternatives.contains { $0.key == choice } ? choice : nil)
    }

    /// "Cauliflower", "Chickpeas", ... from the line's key or text.
    static func baseName(of line: Ing) -> String {
        let k = (line.key ?? "").replacingOccurrences(of: "_florets", with: "")
        for name in baseWords.keys where k.contains(name.prefix(7)) { return name.capitalized }
        return (line.key ?? "base").replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static func detailText(_ alt: VegAlt) -> String {
        switch alt.key {
        case "tofu_extra_firm": return "pressed, torn into wing-size pieces"
        case "paneer_low_fat": return "cubed, patted dry"
        case "seitan": return "torn into wing-size pieces"
        default: return isSoyChunks(alt) ? "rehydrated" : ""
        }
    }

    static func apply(_ r: Recipe, catalog: Catalog, choice: String) -> Recipe {
        guard let c = card(for: r, catalog: catalog, choice: choice), let opt = c.chosen, let alt = opt.alt,
              let (role, _) = role(for: r, catalog: catalog) else { return r }
        var out = r
        let short = VegAlternatives.shortName(alt)
        let g = Int(opt.grams)
        let lower = alt.name.prefix(1).lowercased() + alt.name.dropFirst()
        var text: String
        if isSoyChunks(alt) {
            text = "\(g) g dry soy chunks (rehydrated, about \(Int(c.weight)) g soaked)"
        } else {
            let d = detailText(alt)
            text = "\(g) g \(lower)" + (d.isEmpty ? "" : " (\(d))")
        }
        out.base[c.lineIndex] = Ing(text: text, key: alt.key, grams: opt.grams, optional: r.base[c.lineIndex].optional)
        if let m = r.macros { let b = role.basePer100g * (c.weight / 100); out.macros = m + NutritionCalculator.proportional(opt.nutrition - b, printed: m, catalog: b) }   // original - base(weight) + alt
        let words = baseWords.first { (k, _) in (r.base[c.lineIndex].key ?? "").contains(k.prefix(7)) }?.value ?? []
        out.name = replace(words, in: r.name, with: short)
        var steps = r.instructions.map { replace(words, in: $0, with: short.lowercased()) }
        if let p = alt.prep, !p.isEmpty {
            steps.insert("Prep (\(alt.name)): \(p). Use these times instead of the \(c.baseName.lowercased()) times below.", at: 0)
        }
        out.instructions = steps
        return out
    }

    /// Whole-word, case-insensitive replacement; "<base> florets" collapses to "<short> pieces".
    static func replace(_ words: [String], in text: String, with short: String) -> String {
        var t = text
        for w in words {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
            guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let isFloret = w == "florets" || w.hasSuffix("florets")
            let ns = t as NSString
            var out = "", last = 0
            for m in rx.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let word = ns.substring(with: m.range)
                var rep = isFloret ? (w == "florets" ? "pieces" : short + " pieces") : short
                if let f = word.first, f.isUppercase { rep = rep.prefix(1).uppercased() + rep.dropFirst() }
                else { rep = rep.prefix(1).lowercased() + rep.dropFirst() }
                out += rep
                last = m.range.location + m.range.length
            }
            t = out + ns.substring(from: last)
        }
        return t
    }
}
