import Foundation

enum ShoppingList {
    /// Items for one recipe, with the user's milk, swaps and pints applied. Pantry staples are skipped.
    static func items(for r: Recipe, cfg: RecipeConfig, catalog: Catalog) -> [ShoppingItem] {
        let result = NutritionCalculator(catalog: catalog).compute(r, cfg)
        var out: [ShoppingItem] = []
        for l in result.lines where l.included {
            let key = l.effectiveKey
            let info = catalog.info(key) ?? (l.swap == nil && l.milk == nil && l.powder == nil ? l.info : nil)
            if info?.pantryStaple == true, !(key.map { cfg.missing.contains($0) } ?? false) { continue }
            let name = (l.swap != nil || l.milk != nil || l.powder != nil) ? l.displayName : (info?.name ?? l.ing.text)
            out.append(ShoppingItem(key: key, text: name, category: info?.category ?? l.info?.category ?? "other",
                                    grams: l.scaledGrams > 0 ? l.scaledGrams : nil, estimated: l.amount == .estimated))
        }
        return out
    }

    /// Merges by key (or by text when keyless), summing grams where known.
    static func merge(_ new: [ShoppingItem], into list: inout [ShoppingItem]) {
        for n in new {
            if let i = list.firstIndex(where: { !$0.checked && (n.key != nil ? $0.key == n.key : $0.key == nil && $0.text == n.text) }) {
                switch (list[i].grams, n.grams) {
                case let (a?, b?): list[i].grams = a + b
                case (nil, let b?): list[i].grams = b
                default: break
                }
                if n.estimated { list[i].estimated = true }
            } else {
                list.append(n)
            }
        }
    }

    static func label(_ i: ShoppingItem) -> String {
        if let g = i.grams { return i.estimated ? "\(i.text) (≈ \(Int(g.rounded())) g, est.)" : "\(i.text) (\(Int(g.rounded())) g)" }
        return i.text
    }

    static func grouped(_ list: [ShoppingItem]) -> [(category: String, items: [ShoppingItem])] {
        let groups = Dictionary(grouping: list, by: { $0.category })
        let order = IngCategory.order + groups.keys.filter { !IngCategory.order.contains($0) }.sorted()
        return order.compactMap { c in groups[c].map { (c, $0) } }
    }

    static func shareText(_ list: [ShoppingItem]) -> String {
        var lines = ["Macro Kitchen shopping list"]
        for g in grouped(list) {
            lines.append("")
            lines.append(IngCategory.title(g.category))
            for i in g.items { lines.append("\(i.checked ? "[x]" : "[ ]") \(label(i))") }
        }
        return lines.joined(separator: "\n")
    }
}
