import Foundation

// Logic checks for Models/ + Services/. Args: <dir with recipes.json> <dir with ingredients.json + base_liquids.json>

var failures = 0
var passes = 0
func check(_ ok: Bool, _ msg: String) {
    if ok { passes += 1; print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg)") }
}
func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

let args = CommandLine.arguments
let recipesDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let catalogDir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
let fixtureDir = URL(fileURLWithPath: args.count > 3 ? args[3] : ".")
let dataCatalogDir = URL(fileURLWithPath: args.count > 4 ? args[4] : ".")
let builtFixtureDir = URL(fileURLWithPath: args.count > 5 ? args[5] : ".")   // build_data.py run on fixtures/data

MainActor.assumeIsolated {
    var loaded = RecipeStore.loadData(dir: recipesDir)
    let cat = RecipeStore.loadData(dir: catalogDir)
    loaded.catalog = cat.catalog
    print("recipes: \(loaded.recipes.count), catalog entries: \(loaded.catalog.ingredients.count), liquids: \(loaded.catalog.liquids.count)")
    // powders: real files when present, otherwise the fixture
    var usedPowderFixture = false
    if loaded.catalog.powders.isEmpty {
        let fx = RecipeStore.loadData(dir: fixtureDir)
        loaded.catalog.powders = fx.catalog.powders
        if loaded.catalog.sourceBrands.isEmpty { loaded.catalog.sourceBrands = fx.catalog.sourceBrands }
        usedPowderFixture = true
    }
    print("powders: \(loaded.catalog.powders.count)\(usedPowderFixture ? " (fixture)" : ""), source brands: \(loaded.catalog.sourceBrands.count)")
    let store = RecipeStore()
    store.apply(loaded)
    let calc = NutritionCalculator(catalog: store.catalog)
    func cfg(_ source: CalorieSource = .book) -> RecipeConfig { RecipeConfig(source: source) }

    // (a) all recipes decode
    print("(a) decoding")
    let rawURL = recipesDir.appendingPathComponent("recipes.json")
    let rawCount = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: rawURL))) as? [Any])?.count ?? -1
    check(rawCount > 0 && store.recipes.count == rawCount, "decoded \(store.recipes.count) of \(rawCount) recipes")
    check(store.recipes.allSatisfy { !$0.base.isEmpty && !$0.instructions.isEmpty }, "every recipe has base and instructions")
    let tolerant = RecipeStore.decodeRecipes(Data(#"[{"name":"X","macros":null,"extra":1,"base":[{"text":"a","grams":null}]},{"nope":1}]"#.utf8))
    check(tolerant.count == 1 && tolerant[0].macros == nil && tolerant[0].base.count == 1, "tolerant decode: nulls, unknown keys, bad elements")

    // (b) milk change
    print("(b) milk picker")
    let ffuf = "fat_free_ultra_filtered_milk"
    if let r = store.recipes.first(where: { $0.source.isBook && $0.base.contains { $0.key == ffuf && $0.grams == 400 } && $0.macros != nil }),
       let info = store.catalog.info(ffuf) {
        let gpm = info.gramsPerMl ?? 1.03
        let x = 40.0
        var per = info.per100g * (gpm * 240 / 100)
        per.calories += x
        let milk = BaseLiquid(id: "t", name: "Test milk", family: "milk", servingMl: 240, perServing: per, gramsPerMl: gpm, ingredientKey: nil)
        var c = cfg(); c.milk = milk
        let beforeRes = calc.compute(r, cfg())
        let before = beforeRes.displayed.calories
        let after = calc.compute(r, c).displayed.calories
        let expected = x * 400 / (240 * 1.03)
        // Book mode applies the change proportionally: x min(1, printed kcal / catalog kcal of the lines the printed numbers cover)
        let fBook = beforeRes.bookCovered.calories > 0 ? min(1, (r.macros?.calories ?? 0) / beforeRes.bookCovered.calories) : 1
        check(near(after - before, expected * fBook, 1), "\(r.name) (Book): +\(x) kcal/240ml -> \(String(format: "%.2f", after - before)) kcal (expected \(String(format: "%.2f", expected)) x \(String(format: "%.3f", fBook)))")
        c.source = .calculated
        let d2 = calc.compute(r, c).displayed.calories - calc.compute(r, cfg(.calculated)).displayed.calories
        check(near(d2, expected, 1), "calculated source gives the exact delta (\(String(format: "%.2f", d2)))")
    } else {
        check(false, "no book recipe with 400 g \(ffuf) and catalog entry")
    }

    // (b2) protein powder picker
    print("(b2) protein powder")
    let ppKey = "protein_powder_vanilla"
    if let r = store.recipes.first(where: { $0.macros != nil && $0.allIngredients.contains { $0.key == ppKey && $0.grams == 30 } }),
       let info = store.catalog.info(ppKey),
       let p = store.catalog.powders.first(where: { $0.ingredientKey != ppKey && $0.scoopGrams > 0 }) {
        var c = cfg(); c.powder = p
        let oldKcal = info.per100g.calories * 30 / 100
        let expected = p.perScoop.calories * 30 / p.scoopGrams - oldKcal
        let got = calc.compute(r, c).displayed.calories - calc.compute(r, cfg()).displayed.calories
        check(near(got, expected, 1), "\(r.name): \(p.name) -> \(String(format: "%.2f", got)) kcal (expected \(String(format: "%.2f", expected)))")
        c.source = .calculated
        let got2 = calc.compute(r, c).displayed.calories - calc.compute(r, cfg(.calculated)).displayed.calories
        check(near(got2, expected, 1), "calculated source gives same delta (\(String(format: "%.2f", got2)))")
        let line = calc.compute(r, c).lines.first { $0.isPowderLine }
        check(line?.powder?.id == p.id && line?.displayName == p.name, "powder line reports the chosen powder name (shopping uses it)")
        check(ShoppingList.items(for: r, cfg: c, catalog: store.catalog).contains { $0.text == p.name }, "shopping list uses the powder name")
    } else {
        check(false, "no recipe with 30 g \(ppKey), or no powders loaded")
    }
    check(store.catalog.isPowderLine(Ing(text: "x", key: "casein_powder")) && store.catalog.isPowderLine(Ing(text: "x", key: "collagen_powder"))
          && !store.catalog.isPowderLine(Ing(text: "x", key: "cocoa_powder")), "powder line detection by key")

    // (b3) key aliases applied by build_data.py
    print("(b3) aliases")
    let aliasURL = dataCatalogDir.appendingPathComponent("key_aliases.json")
    if let d = try? Data(contentsOf: aliasURL), let a = (try? JSONSerialization.jsonObject(with: d)) as? [String: String], !a.isEmpty {
        let keys = Set(store.recipes.flatMap { $0.allIngredients.compactMap(\.key) })
        let leftover = a.keys.filter { keys.contains($0) }
        check(leftover.isEmpty, "no recipe still uses an aliased key (\(a.count) aliases; leftover: \(leftover.sorted().prefix(5)))")
        if let target = a["pumpkin_puree"] {
            check(keys.contains(target) || !keys.contains("pumpkin_puree"), "pumpkin_puree -> \(target)")
        }
    } else {
        print("  (no key_aliases.json yet: skipped)")
    }

    // (c) swap
    print("(c) swaps")
    var swapDone = false
    outer: for r in store.recipes where r.macros != nil {
        for (lk, ing) in r.allLines {
            guard let info = store.catalog.info(ing.key) else { continue }
            for (si, s) in info.swaps.enumerated() {
                guard let sk = s.key, let sinfo = store.catalog.info(sk) else { continue }
                var c = cfg(); c.swaps[lk] = si
                let g = calc.grams(ing, info)
                let expected = sinfo.per100g.calories * g * s.ratio / 100 - info.per100g.calories * g / 100
                if abs(expected) < 1 { continue }   // want a swap that actually moves the numbers
                let baseRes = calc.compute(r, cfg())
                let fBook = baseRes.bookCovered.calories > 0 ? min(1, (r.macros?.calories ?? 0) / baseRes.bookCovered.calories) : 1
                let got = calc.compute(r, c).displayed.calories - baseRes.displayed.calories
                check(near(got, expected * fBook, 0.01), "\(r.name) (Book): \(ing.key ?? "") -> \(sk) x\(s.ratio): \(String(format: "%.2f", got)) kcal (expected \(String(format: "%.2f", expected)) x \(String(format: "%.3f", fBook)))")
                let impact = calc.swapImpact(r, lineKey: lk, swapIndex: si, cfg: cfg())
                check(near(impact.delta.calories, expected * fBook, 0.01) && impact.recalculated, "swapImpact agrees (Book, proportional)")
                // Calculated mode keeps the exact catalog delta
                let gotC = calc.compute(r, { var cc = c; cc.source = .calculated; return cc }()).displayed.calories - calc.compute(r, cfg(.calculated)).displayed.calories
                check(near(gotC, expected, 0.01), "swap in Calculated mode: exact catalog delta (\(String(format: "%.2f", gotC)) vs \(String(format: "%.2f", expected)))")
                let impactC = calc.swapImpact(r, lineKey: lk, swapIndex: si, cfg: cfg(.calculated))
                check(near(impactC.delta.calories, expected, 0.01), "swapImpact agrees (Calculated, exact)")
                swapDone = true
                break outer
            }
        }
    }
    check(swapDone, "found a recipe with a swap whose key is in the catalog")
    // swap with null key leaves macros alone
    if let r = store.recipes.first(where: { $0.allIngredients.contains { $0.key == "prime_bites_brownie" } }),
       let line = r.allLines.first(where: { $0.ing.key == "prime_bites_brownie" }),
       let si = store.catalog.info("prime_bites_brownie")?.swaps.firstIndex(where: { $0.key == nil }) {
        var c = cfg(); c.swaps[line.key] = si
        let n = calc.compute(r, c)
        check(near(n.displayed.calories, calc.compute(r, cfg()).displayed.calories, 0.001) && (n.lines.first { $0.lineKey == line.key }?.swapNotRecalculated ?? false), "null-key swap: macros unchanged, flagged not recalculated")
    }

    // (d) pints
    print("(d) pints")
    if let r = store.recipes.first(where: { $0.macros != nil }) {
        var c = cfg(); c.pints = 3
        let one = calc.compute(r, cfg()).displayed.calories
        check(near(calc.compute(r, c).displayed.calories, one * 3, 0.001), "\(r.name): 3 pints = 3 x \(Int(one)) kcal (book)")
        c.source = .calculated
        let oneC = calc.compute(r, cfg(.calculated)).displayed.calories
        check(near(calc.compute(r, c).displayed.calories, oneC * 3, 0.001), "3 pints = 3 x calculated")
    }

    // (e) search
    print("(e) search")
    let ctx = FilterContext()
    let all = store.recipes
    @MainActor func search(_ q: String) -> [Recipe] { FilterEngine.apply(store: store, recipes: all, query: q, state: { var f = FilterState(); f.section = nil; return f }(), ctx: ctx) }
    check(search("oreo mcflurry").contains { $0.name == "Oreo McFlurry" }, "'oreo mcflurry' finds Oreo McFlurry")
    check(search("McFlurry oreo").contains { $0.name == "Oreo McFlurry" }, "token order does not matter")
    let withOreo = all.filter { $0.allIngredients.contains { $0.text.lowercased().contains("oreo") } }
    for q in ["OREO", "oreo", "OrEo"] {
        let ids = Set(search(q).map(\.id))
        check(!withOreo.isEmpty && withOreo.allSatisfy { ids.contains($0.id) }, "'\(q)' matches all \(withOreo.count) recipes with Oreo ingredients")
    }
    check(FilterEngine.normalize("Crème Brûlée") == "creme brulee", "normalize folds diacritics")

    // desserts section
    print("(e2) sections")
    let dessertIDs = Set(all.filter { $0.isDessert }.map(\.id))
    var fd = FilterState(); fd.section = "dessert"
    let gotD = FilterEngine.apply(store: store, recipes: all, query: "", state: fd, ctx: ctx)
    check(gotD.allSatisfy { $0.isDessert } && Set(gotD.map(\.id)) == dessertIDs, "section=dessert returns only desserts (\(gotD.count))")
    let gotDefault = FilterEngine.apply(store: store, recipes: all, query: "", state: FilterState(), ctx: ctx)
    check(gotDefault.allSatisfy { !$0.isDessert } && gotDefault.count == all.filter { $0.section == "creami" }.count, "default view excludes desserts (\(gotDefault.count))")
    let ev = RecipeStore.decodeRecipes(Data(#"[{"name":"D","section":"dessert","servings":8,"chillHours":4,"evidence":{"verdict":"proven","rating":4.8,"commonFixes":["x"]}}]"#.utf8))
    check(ev.first?.isDessert == true && ev[0].evidence?.verdict == "proven" && ev[0].timerHours == 4 && ev[0].perServingDivisor == 8, "dessert fields decode")

    // same checks with a synthetic dessert mixed in (real data may have none yet)
    let store2 = RecipeStore()
    var l2 = loaded; l2.recipes += ev
    store2.apply(l2)
    let d2 = FilterEngine.apply(store: store2, recipes: store2.recipes, query: "", state: fd, ctx: ctx)
    check(d2.count >= 1 && d2.allSatisfy { $0.isDessert }, "section=dessert with a dessert present returns only desserts")
    let c2 = FilterEngine.apply(store: store2, recipes: store2.recipes, query: "", state: FilterState(), ctx: ctx)
    check(c2.allSatisfy { !$0.isDessert } && c2.count == all.filter { $0.section == "creami" }.count, "default view still excludes it")
    var fv = fd; fv.verdicts = ["proven"]; fv.dessertTypes = ["other"]; fv.section = "dessert"
    let vRes = FilterEngine.apply(store: store2, recipes: store2.recipes, query: "", state: fv, ctx: ctx)
    check(!vRes.isEmpty && vRes.allSatisfy { $0.isDessert && $0.evidence?.verdict == "proven" && ($0.dessertType ?? "other") == "other" }, "verdict + dessert type filters (\(vRes.count))")

    // meals, vegetarian mode, guides, paneer (fixture built by build_data.py from fixtures/data)
    print("(m) meals / vegetarian / guides")
    let fx = RecipeStore.loadData(dir: builtFixtureDir)
    let fstore = RecipeStore()
    fstore.apply(fx)
    let fcalc = NutritionCalculator(catalog: fstore.catalog)
    check(fx.recipes.count == 8, "fixture build produced 4 book + 4 web meal recipes (\(fx.recipes.count))")
    if let wrap = fx.recipes.first(where: { $0.id == "chef-chicken-wrap" }) {
        check(wrap.macros?.calories == 1000 && wrap.macros?.protein == 80, "macros = macrosPerServing x servings (500x2 kcal -> \(wrap.macros?.calories ?? -1))")
        check(wrap.vegAdaptation?.macrosPerServing?.calories == 450 && wrap.servings == 2, "vegAdaptation.macrosPerServing stays per serving (450)")
        check(wrap.section == "meal" && wrap.course == "dinner" && wrap.vegetarian == false && wrap.containsEgg == false, "meal fields decode")

        let us = UserStore(fileURL: nil)
        check(us.vegActive(wrap), "veg mode on: veg version active by default")
        let onRes = fcalc.compute(wrap, us.config(for: wrap, catalog: fstore.catalog))
        check(onRes.displayed.calories == 900 && onRes.displayed.protein == 70, "veg macros used: 450 x 2 = \(onRes.displayed.calories) kcal")
        let vegSteps = us.effectiveRecipe(wrap, catalog: fstore.catalog).instructions
        check((vegSteps == wrap.vegAdaptation?.steps || Array(vegSteps.dropFirst()) == wrap.vegAdaptation?.steps) && vegSteps != wrap.instructions, "veg steps used (alt prep may be step 0)")
        check(onRes.lines.contains { $0.ing.text == "250 g extra-firm tofu" } && !onRes.lines.contains { $0.ing.text.contains("chicken") }, "veg ingredient lines swapped in")
        let list = ShoppingList.items(for: wrap, cfg: us.config(for: wrap, catalog: fstore.catalog), catalog: fstore.catalog)
        check(list.contains { $0.text == "Extra-firm tofu" } && !list.contains { $0.text.lowercased().contains("chicken") }, "shopping list uses the veg version")

        us.data.showOriginal.insert(wrap.id)
        let offRes = fcalc.compute(wrap, us.config(for: wrap, catalog: fstore.catalog))
        check(offRes.displayed.calories == 1000 && us.effectiveRecipe(wrap, catalog: fstore.catalog).instructions == wrap.instructions, "toggle to Original: book macros and steps (\(offRes.displayed.calories) kcal)")
        us.data.showOriginal = []; us.data.isVegetarian = false
        check(!us.vegActive(wrap) && fcalc.compute(wrap, us.config(for: wrap, catalog: fstore.catalog)).displayed.calories == 1000, "veg mode off: original")
    } else { check(false, "fixture chicken wrap missing") }

    @MainActor func d0Role(_ key: String, _ text: String, _ name: String) -> String? { fstore.catalog.vegAlts?.role(forKey: key, text: text, recipeName: name)?.id }
    // photos: bundled file wins, else remote URL for web recipes
    func fxr(_ id: String) -> Recipe? { fx.recipes.first { $0.id == id } }
    check(fxr("chef-omelette")?.photo == "chef-omelette.jpg" && fxr("chef-omelette")?.photoURL == nil, "build_data: bundled Photos/<id>.jpg sets photo and ignores a remote URL")
    check(fxr("web-paneer-tikka")?.photo == nil && fxr("web-paneer-tikka")?.photoURL == "https://example.com/tikka.jpg", "build_data: web recipe without a bundled photo gets photoURL")
    check(fxr("web-carbonara")?.photo == nil && fxr("web-carbonara")?.photoURL == nil && fxr("chef-chicken-wrap")?.photo == nil, "build_data: no photo and no URL stays empty (gradient placeholder)")

    // goals, protein density, active-filter pills
    print("(g) goal / density / pills")
    func nut(_ kcal: Double, _ p: Double) -> Nutrition { Nutrition(calories: kcal, protein: p) }
    check(Goal.isCutFriendly(nut(300, 31)) && !Goal.isCutFriendly(nut(300, 25)) && !Goal.isCutFriendly(nut(600, 70)) && Goal.isCutFriendly(nut(550, 55)), "cut-friendly: 300 kcal / 31 g P yes; 300 / 25 no; 600 kcal no (> 550)")
    check(Goal.isBulkFriendly(nut(700, 40), bookTitle: nil) && !Goal.isBulkFriendly(nut(700, 30), bookTitle: nil) && !Goal.isBulkFriendly(nut(500, 50), bookTitle: nil)
          && Goal.isBulkFriendly(nut(400, 20), bookTitle: "The Ultimate Guide to Lean Bulking"), "bulk-friendly: 700 kcal / 40 g P yes; 700 / 30 no; Lean Bulking book always")
    check(Goal.cut.defaultSort == .healthiest && Goal.bulk.defaultSort == .proteinDesc && Goal.maintain.defaultSort == .featured, "goal default sorts: cut Healthiest, bulk Protein, maintain Featured")
    var gd = UserData(); gd.goal = .bulk
    check(UserStore.encode(gd).flatMap { UserStore.decode($0) }?.goal == .bulk && UserData().goal == .maintain, "goal persists; default is Maintain")

    let dRecipes = RecipeStore.decodeRecipes(Data(#"""
    [{"name":"A","id":"a","section":"meal","servings":1,"macros":{"calories":300,"protein":25,"carbs":30,"fat":8},"base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"name":"B","id":"b","section":"meal","servings":1,"macros":{"calories":300,"protein":30,"carbs":30,"fat":8},"base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"name":"C","id":"c","section":"meal","servings":1,"macros":null,"base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"name":"D","id":"d","section":"meal","servings":1,"macros":{"calories":700,"protein":40,"carbs":50,"fat":30},"base":[{"text":"x","key":"x"}],"instructions":["a","b"]}]
    """#.utf8))
    let dStore = RecipeStore()
    dStore.apply(LoadedData(recipes: dRecipes, catalog: Catalog()))
    let dctx = FilterContext(displayed: { $0.macros ?? .zero })
    @MainActor func ids(_ s: FilterState) -> [String] { FilterEngine.apply(store: dStore, recipes: dStore.recipes, query: "", state: s, ctx: dctx).map(\.id).sorted() }
    var dens = FilterState(); dens.section = nil; dens.proteinDensity = 10
    check(ids(dens) == ["b"], "density 10: 300 kcal / 25 g P excluded, 300 / 30 included, no macros excluded, 700 / 40 excluded (\(ids(dens)))")
    dens.proteinDensity = 5
    check(ids(dens) == ["a", "b", "d"], "density 5 keeps everything with macros (\(ids(dens)))")
    var cutF = FilterState(); cutF.section = nil; cutF.cutOnly = true
    var bulkF = FilterState(); bulkF.section = nil; bulkF.bulkOnly = true
    check(ids(cutF) == ["b"] && ids(bulkF) == ["d"], "Cut-friendly only and Bulk-friendly only filters")

    var many = FilterState(); many.section = "meal"; many.tags = ["healthy", "high-protein"]; many.noEgg = true; many.courses = ["dinner"]
    many.proteinDensity = 10; many.mealChips = ["paneer"]; many.maxCalories = 500; many.sources = ["book"]; many.cutOnly = true; many.sort = .rating
    let pills = many.activePills()
    check(pills.count == many.activeCount && Set(pills.map(\.id)).count == pills.count && pills.contains { $0.label == "≥ 10 g P/100 kcal" }
          && pills.contains { $0.label == "Max 500 kcal" } && pills.contains { $0.label == "No egg" } && pills.contains { $0.label == "Dinner" } && pills.contains { $0.label == "Paneer" },
          "active pills: one per filter with readable labels (\(pills.map(\.label)))")
    var one = many
    one.remove(pill: "tag:healthy")
    var expected = many; expected.tags = ["high-protein"]
    check(one == expected && one.activePills().count == pills.count - 1, "removing one pill keeps every other filter")
    var emptied = many
    for p in pills { emptied.remove(pill: p.id) }
    var bare = FilterState(); bare.section = "meal"; bare.sort = .rating
    check(emptied == bare && emptied.activeCount == 0, "removing every pill returns to the bare state (section and sort kept)")
    var cleared = many; cleared.clearFilters()
    check(cleared == bare, "Clear all keeps section and sort")
    if let enc = try? JSONEncoder().encode(many), let back = try? JSONDecoder().decode(FilterState.self, from: enc) {
        check(back == many && back.activePills() == pills, "pill list round-trips with FilterState through JSON")
    } else { check(false, "FilterState encode/decode failed") }

    // ---- "Add protein" boosts for low-protein overnight oats
    print("(pb) add protein")
    func pbi(_ n: String, _ c: String, _ k: Double, _ p: Double) -> IngredientInfo { IngredientInfo(name: n, category: c, per100g: Nutrition(calories: k, protein: p)) }
    var bcat = Catalog()
    bcat.ingredients = ["rolled_oats": pbi("Rolled oats", "other", 380, 13), "whole_milk": pbi("Whole milk", "milk", 61, 3.2),
                        "protein_powder_vanilla": pbi("Vanilla whey protein powder", "protein_powder", 387, 77.4), "greek_yogurt": pbi("Nonfat Greek yogurt", "dairy", 59, 10.2),
                        "skyr_plain": pbi("Skyr (plain, nonfat)", "dairy", 63, 11), "cottage_cheese": pbi("Cottage cheese", "dairy", 81, 10.5)]
    func oatRecipe(_ id: String, name: String = "Overnight Oats", proteinWhole: Double, flag: Bool = true, extraLine: String = "") -> Recipe {
        RecipeStore.decodeRecipes(Data(#"[{"id":"\#(id)","name":"\#(name)","section":"meal","course":"breakfast","servings":2,"proteinBoost":\#(flag),"macros":{"calories":700,"protein":\#(proteinWhole),"carbs":100,"fat":20},"base":[{"text":"100 g oats","key":"rolled_oats","grams":100},{"text":"300 g milk","key":"whole_milk","grams":300}\#(extraLine)],"instructions":["Mix everything in a jar.","Refrigerate overnight.","Eat cold."]}]"#.utf8))[0]
    }
    let boats = oatRecipe("oats12", proteinWhole: 24)                // 12 g per serving
    check(ProteinBoosts.isEligible(boats, proteinPerServing: 12) && !ProteinBoosts.isEligible(oatRecipe("oats26", proteinWhole: 52), proteinPerServing: 26)
          && !ProteinBoosts.isEligible(oatRecipe("baked", name: "Baked Oats", proteinWhole: 18, flag: false), proteinPerServing: 9), "eligible: 12 g overnight oats yes; 26 g no; an unflagged (baked) recipe no")
    let bcalc = NutritionCalculator(catalog: bcat)
    let pbu = UserStore(fileURL: nil)
    let base0 = bcalc.compute(boats, pbu.config(for: boats, catalog: bcat))
    check(base0.displayed.protein == 24 && base0.lines.allSatisfy { !$0.isBoost }, "nothing is added by default (boosts are OFF)")
    pbu.setBoost("oats12", "powder", true)
    let withVanilla = bcalc.compute(boats, pbu.config(for: boats, catalog: bcat))
    check(near(withVanilla.displayed.protein - 24, 77.4 * 0.30 * 2, 0.01) && withVanilla.lines.contains { $0.isBoost && $0.ing.key == "protein_powder_vanilla" }, "scoop with no chosen powder uses protein_powder_vanilla (30 g x 2 servings: +\(String(format: "%.1f", withVanilla.displayed.protein - 24)) g)")
    // the chosen powder from "My protein powder" is used
    let chosen = try! JSONDecoder().decode(ProteinPowder.self, from: Data(#"{"id":"mine","name":"My casein","type":"casein","scoopGrams":30,"perScoop":{"calories":120,"protein":25}}"#.utf8))
    pbu.data.customPowders = [chosen]; pbu.data.defaultPowderId = "mine"
    let withChosen = bcalc.compute(boats, pbu.config(for: boats, catalog: bcat))
    check(near(withChosen.displayed.protein - 24, 25 * 2, 0.01) && near(withChosen.displayed.calories - 700, 120 * 2, 0.01), "the scoop boost uses the chosen powder's nutrition (+25 g P, +120 kcal per serving)")
    // combined boosts sum
    pbu.setBoost("oats12", "greek_yogurt", true); pbu.setBoost("oats12", "skyr", true); pbu.setBoost("oats12", "cottage_cheese", true)
    let combo = bcalc.compute(boats, pbu.config(for: boats, catalog: bcat))
    let expectProtein = (25 + 10.2 * 1.5 + 11 * 1.5 + 10.5) * 2
    check(near(combo.displayed.protein - 24, expectProtein, 0.01) && combo.lines.filter(\.isBoost).count == 4, "combined boosts sum: +\(String(format: "%.1f", combo.displayed.protein - 24)) g (expected \(String(format: "%.1f", expectProtein)))")
    let calcSrc = bcalc.compute(boats, { var c = pbu.config(for: boats, catalog: bcat); c.source = .calculated; return c }())
    let calcBase = bcalc.compute(boats, { var c = RecipeConfig(source: .calculated); c.milk = nil; return c }())
    check(near(calcSrc.displayed.protein - calcBase.displayed.protein, expectProtein, 0.01), "Calculated macros include the boosts as well")
    // options text and labels
    let opts = ProteinBoosts.options(for: boats, catalog: bcat, powder: chosen)
    check(opts.map(\.id) == ["powder", "greek_yogurt", "skyr", "cottage_cheese"] && opts[0].title == "+1 scoop protein powder (30 g)" && near(opts[0].deltaPerServing.protein, 25, 0.01) && near(opts[1].deltaPerServing.protein, 15.3, 0.01), "options: scoop / Greek yogurt / skyr / cottage cheese with per-serving gains")
    let hasPowder = oatRecipe("oatsp", proteinWhole: 24, extraLine: #",{"text":"30 g whey","key":"protein_powder_vanilla","grams":30}"#)
    check(ProteinBoosts.options(for: hasPowder, catalog: bcat, powder: nil)[0].title == "+1 more scoop (30 g)", "'+1 more scoop' when the recipe already has a powder line")
    // cook mode step, shopping, persistence, Cut composition
    let eff = pbu.effectiveRecipe(boats, catalog: bcat)
    check(eff.instructions[1].hasPrefix("Stir in the boosts before refrigerating") && eff.instructions[2] == "Refrigerate overnight.", "cook mode: 'Stir in the boosts before refrigerating' comes before the fridge step")
    check(ShoppingList.items(for: boats, cfg: pbu.config(for: boats, catalog: bcat), catalog: bcat).contains { $0.key == "greek_yogurt" && ($0.grams ?? 0) == 300 }, "shopping list includes the boosts (150 g x 2 servings of yogurt)")
    if let back = UserStore.encode(pbu.data).flatMap({ UserStore.decode($0) }) { check(back.proteinBoosts["oats12"] == ["powder", "greek_yogurt", "skyr", "cottage_cheese"], "boost choices persist per recipe") }
    pbu.data.goal = .cut
    let cutBoost = bcalc.compute(boats, pbu.config(for: boats, catalog: bcat))
    check(cutBoost.lines.filter(\.isBoost).count == 4 && cutBoost.displayedFull.protein >= combo.displayedFull.protein - 0.01, "Cut version composes: boosts apply first, then the goal changes")
    pbu.setBoost("oats12", "powder", false)
    check(pbu.data.proteinBoosts["oats12"]?.contains("powder") == false, "a boost can be switched off again")

    do {
        let ru = UserStore(fileURL: nil)
        let elig = store.recipes.filter { r in
            r.proteinBoost == true && ProteinBoosts.isEligible(r, proteinPerServing: ru.display(for: r, catalog: store.catalog).displayed.protein / r.perServingDivisor)
        }
        print("  real data: \(store.recipes.filter { $0.proteinBoost == true }.count) flagged, \(elig.count) eligible at runtime: \(elig.map(\.name))")
    }

    // ---- vegan
    print("(vegan) vegan badge and filter")
    func vi(_ name: String, _ cat: String = "other", veg: String = "true", allergens: [String] = []) -> IngredientInfo {
        try! JSONDecoder().decode(IngredientInfo.self, from: Data(#"{"name":"\#(name)","category":"\#(cat)","vegetarian":\#(veg),"allergens":\#(String(data: try! JSONEncoder().encode(allergens), encoding: .utf8)!)}"#.utf8))
    }
    var vcat = Catalog()
    vcat.powders = [try! JSONDecoder().decode(ProteinPowder.self, from: Data(#"{"id":"w","name":"Whey","type":"whey_isolate","scoopGrams":30,"perScoop":{},"ingredientKey":"protein_powder_vanilla"}"#.utf8)),
                    try! JSONDecoder().decode(ProteinPowder.self, from: Data(#"{"id":"p","name":"Pea","type":"plant","scoopGrams":30,"perScoop":{},"ingredientKey":"protein_powder_pea"}"#.utf8))]
    vcat.ingredients = [
        "tofu_extra_firm": vi("Extra-firm tofu", allergens: ["soy"]), "soy_sauce": vi("Soy sauce", "sauce", allergens: ["soy"]), "rice_cooked": vi("Cooked rice"),
        "honey": vi("Honey"), "protein_powder_vanilla": vi("Vanilla protein powder", "protein_powder", allergens: ["dairy"]),
        "protein_powder_pea": vi("Pea protein powder", "protein_powder"), "peanut_butter": vi("Peanut butter", "nut"), "butter": vi("Butter", "dairy", allergens: ["dairy"]),
        "almond_milk": vi("Almond milk", "plant_milk"), "whole_milk": vi("Whole milk", "milk"), "mayonnaise": vi("Mayonnaise", "sauce"), "vegan_mayonnaise": vi("Vegan mayonnaise", "sauce"),
        "eggplant": vi("Eggplant", "produce"), "eggs": vi("Eggs", "dairy"), "ghee": vi("Ghee"), "gelatin": vi("Gelatin", "stabilizer"), "chicken_breast": vi("Chicken breast", veg: "false"),
        "coconut_cream": vi("Coconut cream", "dairy"), "cream_cheese": vi("Cream cheese", "dairy"), "ice_cream": vi("Ice cream", "dairy"), "butternut_squash": vi("Butternut squash", "produce"),
        "greek_yogurt": vi("Greek yogurt", "dairy"), "banana": vi("Banana", "fruit", veg: #""check""#), "tempeh": vi("Tempeh"), "vegetarian_parmesan": vi("Vegetarian parmesan", "dairy"),
    ]
    let vflags = ["tofu_extra_firm", "soy_sauce", "rice_cooked", "protein_powder_pea", "peanut_butter", "almond_milk", "vegan_mayonnaise", "eggplant", "coconut_cream", "butternut_squash", "tempeh"].map { vcat.isVegan($0) }
    let nflags = ["honey", "protein_powder_vanilla", "butter", "whole_milk", "mayonnaise", "eggs", "ghee", "gelatin", "chicken_breast", "cream_cheese", "ice_cream", "greek_yogurt", "banana", "vegetarian_parmesan"].map { vcat.isVegan($0) }
    check(vflags.allSatisfy { $0 == true } && nflags.allSatisfy { $0 == false }, "vegan rules: tofu, peanut butter, almond milk, coconut cream, pea powder yes; honey, whey, butter, milk, mayo, eggs, ghee, gelatin, cheese, 'check' items no")
    func vrecipe(_ keys: [String], tags: [String] = []) -> Recipe {
        let lines = keys.map { #"{"text":"\#($0)","key":"\#($0)"}"# }.joined(separator: ",")
        return RecipeStore.decodeRecipes(Data(#"[{"id":"v","name":"v","tags":\#(String(data: try! JSONEncoder().encode(tags), encoding: .utf8)!),"base":[\#(lines)],"instructions":["a","b"]}]"#.utf8))[0]
    }
    check(VeganRules.isVegan(vrecipe(["tofu_extra_firm", "soy_sauce", "rice_cooked"]), catalog: vcat), "a tofu stir-fry with soy sauce is vegan")
    check(!VeganRules.isVegan(vrecipe(["tofu_extra_firm", "soy_sauce", "honey"]), catalog: vcat), "the same recipe with honey is not vegan")
    check(!VeganRules.isVegan(vrecipe(["tofu_extra_firm", "protein_powder_vanilla"]), catalog: vcat), "... or with a whey line")
    check(VeganRules.isVegan(vrecipe(["tofu_extra_firm", "mystery_spice"], tags: ["vegan"]), catalog: vcat) && !VeganRules.isVegan(vrecipe(["tofu_extra_firm", "mystery_spice"]), catalog: vcat), "a recipe tagged vegan with an unknown line stays vegan (untagged does not)")
    check(!VeganRules.isVegan(vrecipe(["honey", "mystery_spice"], tags: ["vegan"]), catalog: vcat), "a tagged recipe with a resolved non-vegan line is not vegan")
    if let bowl = fx.recipes.first(where: { $0.id == "chef-chicken-bowl" }) {
        let vu = UserStore(fileURL: nil)
        check(vu.vegActive(bowl) && fstore.catalog.isVegan("tofu_extra_firm") == true, "fixture catalog: tofu is vegan")
        let withTofu = vu.effectiveRecipe(bowl, catalog: fstore.catalog)       // preferEasy default: tofu is the first 'everywhere' alternative
        check(withTofu.base[0].key == "tofu_extra_firm" && VeganRules.isVegan(withTofu, catalog: fstore.catalog), "veg version with the tofu alternative is vegan")
        vu.data.vegChoice[bowl.id] = ["b0": "paneer_low_fat"]
        let withPaneer = vu.effectiveRecipe(bowl, catalog: fstore.catalog)
        check(withPaneer.base[0].key == "paneer_low_fat" && !VeganRules.isVegan(withPaneer, catalog: fstore.catalog), "switching the alternative to paneer flips it back to vegetarian")
        var vf = FilterState(); vf.section = nil; vf.vegan = true
        check(vf.activePills().map(\.label) == ["Vegan"], "Vegan filter pill")
    }
    do {
        var bySection: [String: (vegan: Int, total: Int)] = [:]
        for r in store.recipes {
            let s = r.section
            var v = bySection[s] ?? (0, 0)
            v.total += 1
            if store.index[r.id]?.vegan == true { v.vegan += 1 }
            bySection[s] = v
        }
        print("  real data vegan (as written + default veg version): " + bySection.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.vegan)/\($0.value.total)" }.joined(separator: ", "))
        check(bySection.values.reduce(0, { $0 + $1.vegan }) > 100, "real data has a sensible number of vegan recipes")
    }

    // ---- estimated amounts
    print("(est) estimated amounts")
    func ing2(_ name: String, _ cat: String, _ kcal: Double, _ p: Double) -> IngredientInfo { IngredientInfo(name: name, category: cat, per100g: Nutrition(calories: kcal, protein: p)) }
    var ecat = Catalog()
    ecat.ingredients = [
        "salt": ing2("Salt", "spice", 0, 0), "black_pepper": ing2("Black pepper", "spice", 251, 10), "olive_oil": ing2("Olive oil", "other", 884, 0),
        "cheddar": ing2("Cheddar", "dairy", 404, 23), "cilantro": ing2("Cilantro", "produce", 23, 2), "tomato": ing2("Tomato", "produce", 18, 0.9),
        "mix_in_choice": ing2("Mix-in of your choice", "mix_in", 0, 0), "rice_dry": ing2("Rice", "other", 365, 7),
    ]
    func est(_ text: String, _ key: String) -> Double? { EstimateRules.estimate(text: text, key: key, info: ecat.info(key))?.grams }
    check(est("Salt to taste", "salt") == 0.5 && est("Black pepper to taste", "black_pepper") == 0.3, "Salt to taste = 0.5 g, pepper to taste = 0.3 g")
    check(est("Olive oil for frying", "olive_oil") == 5 && est("Olive oil spray", "olive_oil") == 1, "Olive oil for frying = 5 g, spray = 1 g")
    check(est("Shredded cheddar for topping", "cheddar") == 20, "Shredded cheddar for topping = 20 g")
    check(est("Cilantro to garnish", "cilantro") == 3 && est("Tomato, sliced", "tomato") == 50 && est("Rice", "rice_dry") == 50, "Cilantro to garnish = 3 g; tomato 50 g; rice 50 g dry")
    check(est("Mix-in of your choice", "mix_in_choice") == nil, "unknown categories stay unestimated (not counted)")
    func erecipe(_ lines: String, macros: String = "null") -> Recipe {
        RecipeStore.decodeRecipes(Data(#"[{"id":"er","name":"er","servings":1,"macros":\#(macros),"base":[\#(lines)],"instructions":["a","b"]}]"#.utf8))[0]
    }
    func el(_ text: String, _ key: String, optional: Bool = false) -> String { #"{"text":"\#(text)","key":"\#(key)","optional":\#(optional)}"# }
    let er = erecipe([el("Salt to taste", "salt"), el("Olive oil for frying", "olive_oil"), el("Shredded cheddar for topping", "cheddar"), el("Cilantro to garnish", "cilantro"), el("Chilli flakes", "tomato", optional: true)].joined(separator: ","))
    let ecalc = NutritionCalculator(catalog: ecat)
    var ecfg = RecipeConfig(source: .calculated)
    let eon = ecalc.compute(er, ecfg)
    check(eon.estimatedCount == 4 && eon.lines.prefix(4).allSatisfy { $0.amount == .estimated } && eon.lines[4].amount == .known && eon.lines[4].grams == 0, "four lines estimated; the optional line gets no estimate (\(eon.estimatedCount))")
    check(near(eon.calculated.calories, 884 * 0.05 + 404 * 0.20 + 23 * 0.03, 0.01), "calculated macros include the estimates (\(String(format: "%.1f", eon.calculated.calories)) kcal)")
    ecfg.useEstimates = false
    let eoff = ecalc.compute(er, ecfg)
    check(eoff.calculated.calories == 0 && eoff.estimatedCount == 0 && eoff.uncounted == 4, "estimates off: calculated macros revert and the lines are 'not counted' again")
    // Book numbers are the source's own: estimates do not move them
    let erb = erecipe([el("Salt to taste", "salt"), el("Olive oil for frying", "olive_oil")].joined(separator: ","), macros: #"{"calories":500,"protein":30,"carbs":40,"fat":20}"#)
    check(ecalc.compute(erb, RecipeConfig(source: .book)).displayed.calories == 500 && ecalc.compute(erb, RecipeConfig(source: .book, useEstimates: false)).displayed.calories == 500, "Book numbers stay the source's own with estimates on or off")
    // the user's own amount wins, works with estimates off, and persists
    let eu = UserStore(fileURL: nil)
    eu.setLineGrams("er", line: "b1", grams: 12)
    var ucfg = eu.config(for: er, catalog: ecat); ucfg.source = .calculated
    let ures = ecalc.compute(er, ucfg)
    check(ures.lines[1].amount == .user && ures.lines[1].grams == 12 && near(ures.lines[1].nutrition.calories, 884 * 0.12, 0.01), "a user-entered amount overrides the estimate (12 g oil)")
    eu.data.useEstimates = false
    ucfg = eu.config(for: er, catalog: ecat); ucfg.source = .calculated
    check(ecalc.compute(er, ucfg).lines[1].amount == .user, "the user's own amount stays when estimates are off")
    if let back = UserStore.encode(eu.data).flatMap({ UserStore.decode($0) }) { check(back.lineGrams["er"]?["b1"] == 12 && back.useEstimates == false, "user amount and the estimates switch persist") }
    eu.setLineGrams("er", line: "b1", grams: nil)
    check(eu.data.lineGrams["er"] == nil, "clearing the user's amount goes back to the estimate")
    var sitem = ShoppingItem(key: "cheddar", text: "Cheddar", grams: 20)
    sitem.estimated = true
    check(ShoppingList.label(sitem) == "Cheddar (≈ 20 g, est.)" && ShoppingList.label(ShoppingItem(key: "x", text: "Rice", grams: 50)) == "Rice (50 g)", "shopping list marks estimated amounts with ≈ and (est.)")
    let shopRes = ShoppingList.items(for: er, cfg: { var c = RecipeConfig(); c.source = .calculated; return c }(), catalog: ecat)
    check(shopRes.first { $0.key == "cheddar" }?.estimated == true, "shopping items carry the estimated flag")
    do {
        let rc = NutritionCalculator(catalog: store.catalog)
        let eu2 = UserStore(fileURL: nil)
        var withEst = 0, lines = 0, notCounted = 0, withoutEstNotCounted = 0
        for r in store.recipes {
            let cfg = eu2.config(for: r, catalog: store.catalog, applyGoal: false)
            let res = rc.compute(r, cfg)
            if res.estimatedCount > 0 { withEst += 1 }
            lines += res.estimatedCount
            notCounted += res.uncounted
            var off = cfg; off.useEstimates = false
            withoutEstNotCounted += rc.compute(r, off).uncounted
        }
        print("  real data: \(withEst) of \(store.recipes.count) recipes have at least one estimated line (\(lines) lines); still not counted: \(notCounted) lines (was \(withoutEstNotCounted) before estimates)")
    }

    // ---- protein upgrade (wings / crispy bites)
    print("(pu) protein upgrade")
    if let wing = fx.recipes.first(where: { $0.id == "web-korean-cauliflower-wings" }) {
        check(wing.proteinUpgrade?.role == "wing_base" && wing.proteinUpgrade?.lineIndex == 0, "build marks the Korean cauliflower wings for the protein upgrade")
        check(fx.recipes.filter { $0.proteinUpgrade != nil }.map(\.id) == ["web-korean-cauliflower-wings"], "only wing-style recipes with a produce base get it")
        let pcalc = NutritionCalculator(catalog: fstore.catalog)
        let pu = UserStore(fileURL: nil)
        pu.data.isVegetarian = false
        let baseKcal = pcalc.compute(wing, pu.config(for: wing, catalog: fstore.catalog)).displayed
        pu.setUpgrade(wing.id, "tofu_extra_firm")
        let tofu = pcalc.compute(wing, pu.config(for: wing, catalog: fstore.catalog)).displayed
        let expectP = 400 * (16 - 1.9) / 100 / 2
        check(near((tofu.protein - baseKcal.protein) / 2, expectP, 0.01), "400 g cauliflower -> tofu: protein +\(String(format: "%.2f", (tofu.protein - baseKcal.protein) / 2)) g per serving (expected \(String(format: "%.2f", expectP)))")
        check(near((tofu.calories - baseKcal.calories) / 2, 400 * (145 - 25) / 100 / 2, 0.01), "kcal delta = alt - base at the same weight")
        let shownW = pu.effectiveRecipe(wing, catalog: fstore.catalog)
        check(shownW.name == "Spicy Korean Fried Tofu Wings" && shownW.base[0].text == "400 g extra-firm tofu (pressed, torn into wing-size pieces)" && shownW.base[0].grams == 400, "title and line: \(shownW.name) / \(shownW.base[0].text)")
        check(shownW.instructions.first?.hasPrefix("Prep (Extra-firm tofu): Press 20 min") == true && shownW.instructions.contains { $0.contains("Toss the tofu pieces") }, "prep is step 0 and the base word is replaced in the steps (\(shownW.instructions.dropFirst().first ?? ""))")
        pu.setUpgrade(wing.id, "soy_chunks")
        let soy = pu.upgradeCard(wing, catalog: fstore.catalog)
        check(soy?.chosen?.grams == 133 && pu.effectiveRecipe(wing, catalog: fstore.catalog).base[0].text.hasPrefix("133 g dry soy chunks (rehydrated"), "soy chunks show dry grams = weight / 3 (133 g)")
        check(near((soy?.chosen?.nutrition.protein ?? 0), 52 * 1.33, 0.1), "soy chunks nutrition is computed from the dry weight")
        pu.setUpgrade(wing.id, "tofu_extra_firm")
        if let back = UserStore.encode(pu.data).flatMap({ UserStore.decode($0) }) { check(back.upgradeChoice[wing.id] == "tofu_extra_firm", "the choice persists per recipe") }
        // composes with the Cut version: the goal changes see the upgraded lines
        pu.data.goal = .cut
        let withCut = pcalc.compute(wing, pu.config(for: wing, catalog: fstore.catalog))
        check(withCut.lines.first?.ing.key == "tofu_extra_firm" && withCut.displayedFull.protein >= tofu.protein - 0.01, "Cut version composes with the upgrade (upgrade first)")
        check(ShoppingList.items(for: wing, cfg: pu.config(for: wing, catalog: fstore.catalog), catalog: fstore.catalog).contains { $0.key == "tofu_extra_firm" }, "shopping list uses the upgraded ingredient")
        var uf = FilterState(); uf.section = nil; uf.hasUpgrade = true
        check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: uf, ctx: FilterContext()).map(\.id) == ["web-korean-cauliflower-wings"] && uf.activePills().map(\.label) == ["Has protein upgrade"], "Has protein upgrade filter and pill")
    } else { check(false, "fixture Korean cauliflower wings missing") }

    // ---- goal versions, saved-per-goal, ratings, quickest sort
    print("(gv) goal versions / saved / rating / quickest")
    check(Goal.original(nut(300, 31), bookTitle: nil) == .cut && Goal.original(nut(700, 40), bookTitle: nil) == .bulk && Goal.original(nut(500, 25), bookTitle: nil) == .maintain
          && Goal.original(nut(400, 20), bookTitle: Goal.bulkBook) == .bulk && Goal.original(nut(300, 31), bookTitle: Goal.bulkBook) == .cut, "original classification: Cut / Bulk / Maintain (Lean Bulking book counts as Bulk unless cut-friendly)")

    func ing(_ name: String, _ cat: String, _ kcal: Double, _ p: Double, swaps: [SwapOption] = []) -> IngredientInfo {
        var i = IngredientInfo(name: name, category: cat, per100g: Nutrition(calories: kcal, protein: p)); i.swaps = swaps; return i
    }
    func sw(_ key: String, _ name: String) -> SwapOption { try! JSONDecoder().decode(SwapOption.self, from: Data(#"{"name":"\#(name)","key":"\#(key)","ratio":1}"#.utf8)) }
    var gcat = Catalog()
    gcat.ingredients = [
        "cheddar": ing("Cheddar", "dairy", 400, 25, swaps: [sw("cheddar_light", "Light cheddar"), sw("blue_cheese", "Blue cheese")]),
        "cheddar_light": ing("Light cheddar", "dairy", 300, 27),
        "blue_cheese": ing("Blue cheese", "dairy", 350, 21),         // only 12% lighter: not eligible
        "olive_oil": ing("Olive oil", "other", 884, 0),
        "fat_free_ultra_filtered_milk": ing("Fat-free milk", "ultra_filtered", 32, 5, swaps: [sw("whole_milk", "Whole milk")]),
        "whole_milk": ing("Whole milk", "milk", 61, 3.2),
        "nuts": ing("Mixed nuts", "nut", 607, 20),
        "rice_cooked": ing("Cooked rice", "other", 130, 2.7),
    ]
    gcat.ingredients["onion"] = ing("Onion", "produce", 40, 1.1, swaps: [sw("scallions", "Scallions")])
    gcat.ingredients["scallions"] = ing("Scallions", "produce", 32, 1.8)
    gcat.ingredients["sauce_a"] = ing("Sauce A", "sauce", 100, 1, swaps: [sw("sauce_b", "Sauce B")])      // 10 g: 10 kcal -> 6 kcal, saves 4 kcal
    gcat.ingredients["sauce_b"] = ing("Sauce B", "sauce", 60, 1)
    let gcalc = NutritionCalculator(catalog: gcat)
    func grecipe(_ id: String, servings: Int, kcal: Double, protein: Double, lines: String, section: String = "meal") -> Recipe {
        RecipeStore.decodeRecipes(Data(#"[{"id":"\#(id)","name":"\#(id)","section":"\#(section)","course":"dinner","servings":\#(servings),"macros":{"calories":\#(kcal),"protein":\#(protein),"carbs":50,"fat":30},"base":[\#(lines)],"instructions":["a","b"]}]"#.utf8))[0]
    }
    func gl(_ text: String, _ key: String, _ grams: Double) -> String { #"{"text":"\#(text)","key":"\#(key)","grams":\#(grams)}"# }
    let gr = grecipe("cutme", servings: 2, kcal: 1400, protein: 80, lines: [gl("200 g cheddar", "cheddar", 200), gl("20 g olive oil", "olive_oil", 20)].joined(separator: ","))
    let gu = UserStore(fileURL: nil)
    gu.data.goal = .cut
    let gres = gu.goalResolution(gr, catalog: gcat)
    let ids = gres.changes.map(\.id)
    check(ids == ["cut:swap:b0", "cut:fat:b1", "cut:portion"] && gres.changes.allSatisfy(\.enabled), "cut changes: lighter cheese, halved oil, portion (\(ids)); blue cheese (12% lighter) is not eligible")
    let cutCfg = gu.config(for: gr, catalog: gcat)
    let cutRes = gcalc.compute(gr, cutCfg)
    // 1400 - 200 (cheddar 200 g: 800 -> 600 kcal) - 88.4 (20 g oil -> 10 g) = 1111.6 per recipe = 555.8 per serving > 450 -> 0.80 serving
    check(near(cutRes.displayedFull.calories, 1111.6, 0.01), "cut swap + fat math: \(String(format: "%.1f", cutRes.displayedFull.calories)) kcal (expected 1111.6)")
    check(gres.portion == 0.8 && near(cutRes.displayed.calories, 1111.6 * 0.8, 0.01) && gres.portionLabel == "Cut portion: 0.8 serving", "cut portion: \(gres.portion), label \(gres.portionLabel ?? "-"), displayed \(String(format: "%.1f", cutRes.displayed.calories)) kcal")
    check(near(cutRes.displayed.protein, (80 + 3 * 2 * 1.0 * 0 + (27 - 25) * 2) * 0.8, 0.01), "cut swap protein: +4 g from the lighter cheese, then x0.8 (\(String(format: "%.1f", cutRes.displayed.protein)))")
    check(cutRes.lines.first?.swapFromGoal == true && cutRes.lines[1].lineScale == 0.5 && cutRes.lines[1].grams == 10, "cut lines flagged: goal swap, halved oil (10 g)")
    gu.setChange("cutme", "cut:portion", false)
    check(gu.goalResolution(gr, catalog: gcat).portion == 1 && near(gcalc.compute(gr, gu.config(for: gr, catalog: gcat)).displayed.calories, 1111.6, 0.01), "a change can be toggled off individually (portion off -> full portion)")
    gu.setChange("cutme", "cut:swap:b0", false)
    check(near(gcalc.compute(gr, gu.config(for: gr, catalog: gcat)).displayedFull.calories, 1400 - 88.4, 0.01), "swap off too: only the halved oil remains")
    check(near(gcalc.compute(gr, gu.config(for: gr, catalog: gcat, applyGoal: false)).displayed.calories, 1400, 0.01), "cards and filters (applyGoal false) always see the recipe as written")
    gu.data.goalToggles = [:]
    gu.setVersion("cutme", .maintain)
    check(gu.goalResolution(gr, catalog: gcat).changes.isEmpty && near(gcalc.compute(gr, gu.config(for: gr, catalog: gcat)).displayed.calories, 1400, 0.01), "per-recipe version Maintain = the recipe as-is")
    gu.setVersion("cutme", .cut)
    check(gu.data.recipeGoal["cutme"] == nil || gu.versionGoal("cutme") == .cut, "version defaults to the global goal")
    // a user's own swap on a line is left alone
    gu.setSwap("cutme", line: "b0", index: 0)
    check(!gu.goalResolution(gr, catalog: gcat).changes.contains { $0.id == "cut:swap:b0" }, "lines the user swapped are not touched by the goal version")
    gu.setSwap("cutme", line: "b0", index: nil)

    // small and aromatic lines are left alone
    let tinyRecipe = grecipe("smallswaps", servings: 1, kcal: 400, protein: 20, lines: [gl("150 g onion", "onion", 150), gl("10 g sauce A", "sauce_a", 10), gl("200 g cheddar", "cheddar", 200)].joined(separator: ","))
    let smallIds = gu.goalResolution(tinyRecipe, catalog: gcat).changes.map(\.id)
    check(!smallIds.contains("cut:swap:b0"), "an onion line gets no Cut swap (produce, under 30 kcal/100 g rule)")
    check(!smallIds.contains("cut:swap:b1"), "a 10 g swap saving 4 kcal per serving is not applied (minimum 15 kcal per serving)")
    check(smallIds.contains("cut:swap:b2"), "the dairy swap (200 g cheddar -> light cheddar) still applies")

    // bulk: richer milk, portion rounding up to 0.25, capped at 2.0, optional add-on off by default
    let bu = UserStore(fileURL: nil); bu.data.goal = .bulk
    let small = grecipe("small", servings: 1, kcal: 300, protein: 20, lines: gl("400 g fat-free milk", "fat_free_ultra_filtered_milk", 400))
    let bres = bu.goalResolution(small, catalog: gcat)
    check(bres.changes.contains { $0.id == "bulk:swap:b0" && $0.enabled } && bres.portion == 2.0, "bulk: fat-free milk -> whole milk, portion capped at 2.0 (\(bres.portion))")
    let mid = grecipe("mid", servings: 1, kcal: 500, protein: 40, lines: gl("200 g cooked rice", "rice_cooked", 200))
    check(bu.goalResolution(mid, catalog: gcat).portion == 1.5, "bulk portion: 750 / 500 = 1.5 exactly")
    let mid2 = grecipe("mid2", servings: 1, kcal: 600, protein: 40, lines: gl("200 g cooked rice", "rice_cooked", 200))
    check(bu.goalResolution(mid2, catalog: gcat).portion == 1.25, "bulk portion rounds up to 0.25: 750 / 600 = 1.25")
    let big = grecipe("big", servings: 1, kcal: 800, protein: 40, lines: gl("200 g cooked rice", "rice_cooked", 200))
    let bigRes = bu.goalResolution(big, catalog: gcat)
    check(bigRes.portion == 1 && !bigRes.changes.contains { $0.kind == .portion }, "bulk: no portion change when already at the target")
    let addon = bigRes.changes.first { $0.kind == .addon }
    check(addon != nil && addon?.enabled == false && bigRes.cfg.extras.isEmpty, "bulk add-on is suggested but OFF by default (\(addon?.title ?? "-"))")
    let offKcal = gcalc.compute(big, bigRes.cfg).displayed.calories
    bu.setChange("big", addon!.id, true)
    let onRes = bu.goalResolution(big, catalog: gcat)
    let onKcal = gcalc.compute(big, onRes.cfg).displayed.calories
    check(onRes.cfg.extras.count == 1 && near(onKcal - offKcal, 130 * 1.5, 0.01), "add-on ON adds its catalog nutrition (+\(String(format: "%.1f", onKcal - offKcal)) kcal for 150 g cooked rice, per serving)")
    check(ShoppingList.items(for: big, cfg: onRes.cfg, catalog: gcat).contains { $0.text.contains("Cooked rice") }, "shopping list includes the add-on")

    // real data: goal versions are monotonic and cheap
    do {
        let rc = NutritionCalculator(catalog: store.catalog)
        let cu = UserStore(fileURL: nil); cu.data.goal = .cut
        let bk = UserStore(fileURL: nil); bk.data.goal = .bulk
        var cutUp = 0, bulkDown = 0, cutChanged = 0, bulkChanged = 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        for r in store.recipes {
            let orig = rc.compute(r, cu.config(for: r, catalog: store.catalog, applyGoal: false)).displayed.calories
            let c = rc.compute(r, cu.config(for: r, catalog: store.catalog)).displayed.calories
            let b = rc.compute(r, bk.config(for: r, catalog: store.catalog)).displayed.calories
            if c > orig + 0.01 { cutUp += 1; if cutUp <= 4 { print("    cut up: \(r.id) \(orig) -> \(c) \(cu.goalResolution(r, catalog: store.catalog).changes.map(\.id))") } }
            if b < orig - 0.01 { bulkDown += 1; if bulkDown <= 4 { print("    bulk down: \(r.id) \(orig) -> \(b) \(bk.goalResolution(r, catalog: store.catalog).changes.map(\.id))") } }
            if abs(c - orig) > 0.01 { cutChanged += 1 }
            if abs(b - orig) > 0.01 { bulkChanged += 1 }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        check(cutUp == 0 && bulkDown == 0, "real data: cut versions never add calories, bulk versions never remove them (cut changed \(cutChanged), bulk changed \(bulkChanged) of \(store.recipes.count) recipes; \(String(format: "%.0f", ms)) ms for all three versions)")
    }

    // spot values: Book kcal per serving, Cut / Maintain
    do {
        let rc = NutritionCalculator(catalog: store.catalog)
        let spots: [(String, Double, Double)] = [
            // Cut values rose a little (reviewer 300.8 / 440.7 / 435.2): Cut no longer swaps onions, aromatics or lines saving under 15 kcal per serving
            ("web-meal-coconut-curry-ramen-minimalist-baker", 306.4, 528.0), ("bulk-chicken-tikka-and-pilau-rice", 444.6, 913.3),
            ("web-meal-air-fryer-tortilla-pizza-chicken-nourished-by-nic", 369.4, 464.0),   // reviewer 278.5: "10 inch tortilla" is now ONE tortilla (was count 10)
            ("web-hot-chocolate-ice-cream", 318.8, 976.0),                                  // reviewer 158.8 / 244.0: printed values were per serving, scaled x4 to the whole pint
            ("chef-chicken-pad-thai", 446.5, 786.8)]                                       // reviewer 435.2: the noodles line was keyed vegetable_oil, now rice_noodles
        for (id, wantCut, wantMaint) in spots {
            guard let r = store.recipes.first(where: { $0.id == id }) else { check(false, "spot recipe \(id) missing"); continue }
            let vegActive = r.vegAdaptation != nil && r.vegetarian != true
            var vals: [Goal: Double] = [:]
            for g in [Goal.cut, .maintain] {
                var base = RecipeConfig(vegActive: vegActive, preferEasy: true, source: .book); base.useEstimates = true
                let gr = GoalVersion.resolve(r, catalog: store.catalog, base: base, goal: g, toggles: [:], vegetarianUser: true)
                vals[g] = (rc.compute(r, gr.cfg).displayed * (1 / r.perServingDivisor)).calories
            }
            print("  spot \(id): Cut \(String(format: "%.1f", vals[.cut] ?? 0)) / Maintain \(String(format: "%.1f", vals[.maintain] ?? 0)) (reviewer: \(wantCut) / \(wantMaint))")
            check(near(vals[.cut] ?? 0, wantCut, 2) && near(vals[.maintain] ?? 0, wantMaint, 2), "spot values \(id)")
        }
    }

    do {
        var lines = 0, recipes = 0
        for r in store.recipes where r.vegAdaptation != nil {
            let n = VegAlternatives.resolve(r, catalog: store.catalog, choices: [:], preferEasy: true).lines.count
            lines += n; if n > 0 { recipes += 1 }
        }
        print("  real data: veg-alternative lines \(lines) in \(recipes) recipes (meat-line gate: keyToRole / matchKeys or non-vegetarian protein >= 10 g)")
    }

    // ---- My Greek yogurt
    print("(gy) My Greek yogurt")
    func gyi(_ n: String, _ k: Double, _ p: Double, _ f: Double) -> IngredientInfo { IngredientInfo(name: n, category: "dairy", per100g: Nutrition(calories: k, protein: p, fat: f)) }
    var gcat2 = Catalog()
    gcat2.ingredients = ["greek_yogurt_full": gyi("Greek yogurt 5%", 97, 9, 5), "greek_yogurt_2pct": gyi("Greek yogurt 2%", 73, 9.5, 2), "greek_yogurt_nonfat": gyi("Greek yogurt 0%", 54, 10.3, 0),
                         "greek_yogurt": gyi("Nonfat Greek yogurt", 59, 10.2, 0.4), "plain_yogurt": gyi("Plain whole-milk yogurt", 61, 3.5, 3.3), "hung_curd": gyi("Hung curd", 97, 9, 5),
                         "labneh": gyi("Labneh", 150, 6, 12), "skyr_full": gyi("Skyr whole milk", 91, 9, 4), "skyr_plain": gyi("Skyr nonfat", 63, 11, 0.2), "quark": gyi("Quark", 67, 12, 0.2)]
    func yrec(_ lines: String) -> Recipe {
        RecipeStore.decodeRecipes(Data(#"[{"id":"y1","name":"y","servings":1,"macros":null,"base":[\#(lines)],"instructions":["a","b"]}]"#.utf8))[0]
    }
    func yl(_ text: String, _ key: String, _ g: Double) -> String { #"{"text":"\#(text)","key":"\#(key)","grams":\#(g)}"# }
    let yr = yrec([yl("200 g full-fat Greek yogurt", "greek_yogurt_full", 200), yl("200 g plain yogurt", "plain_yogurt", 200), yl("100 g hung curd", "hung_curd", 100), yl("100 g labneh", "labneh", 100),
                   yl("100 g skyr whole milk", "skyr_full", 100), yl("100 g quark", "quark", 100), yl("100 g nonfat greek", "greek_yogurt", 100)].joined(separator: ","))
    let ycalc = NutritionCalculator(catalog: gcat2)
    let yu = UserStore(fileURL: nil)
    @MainActor func ycfg() -> RecipeConfig { var c = yu.config(for: yr, catalog: gcat2); c.source = .calculated; return c }
    check(yu.data.greekYogurt == .zero, "the default is 0% Greek yogurt")
    let y0 = ycalc.compute(yr, ycfg())
    check(near(y0.lines[0].nutrition.calories, 54 * 2, 0.01) && y0.lines[0].yogurtKey == "greek_yogurt_nonfat" && y0.lines[0].yogurtLabel == "0% Greek yogurt",
          "200 g full-fat Greek yogurt shows the 0% nutrition under the default (\(y0.lines[0].nutrition.calories) kcal, note: \(y0.lines[0].yogurtLabel ?? "-"))")
    check(near(y0.lines[4].nutrition.calories, 63, 0.01) && y0.lines[4].yogurtKey == "skyr_plain", "full-fat skyr shows as nonfat skyr")
    check(y0.lines[1].yogurtKey == nil && y0.lines[2].yogurtKey == nil && y0.lines[3].yogurtKey == nil && y0.lines[5].yogurtKey == nil && y0.lines[6].yogurtKey == nil
          && near(y0.lines[1].nutrition.calories, 122, 0.01) && near(y0.lines[3].nutrition.calories, 150, 0.01), "plain yogurt, curd, labneh, quark and nonfat lines are untouched")
    yu.data.greekYogurt = .asWritten
    check(near(ycalc.compute(yr, ycfg()).lines[0].nutrition.calories, 97 * 2, 0.01) && ycalc.compute(yr, ycfg()).lines.allSatisfy { $0.yogurtKey == nil }, "\"As written\" restores the original (194 kcal)")
    yu.data.greekYogurt = .twoPercent
    check(near(ycalc.compute(yr, ycfg()).lines[0].nutrition.calories, 73 * 2, 0.01), "2% shows the 2% yogurt")
    yu.data.greekYogurt = .zero
    // Book mode: printed numbers hold the full-fat yogurt, the picker changes them proportionally (never below zero)
    let yb = RecipeStore.decodeRecipes(Data(#"[{"id":"y2","name":"y","servings":1,"macros":{"calories":300,"protein":20,"carbs":20,"fat":15},"base":[{"text":"200 g full-fat Greek yogurt","key":"greek_yogurt_full","grams":200}],"instructions":["a","b"]}]"#.utf8))[0]
    var ybc = yu.config(for: yb, catalog: gcat2); ybc.source = .book
    let ybRes = ycalc.compute(yb, ybc)
    check(ybRes.displayed.calories >= 0 && ybRes.displayed.calories < 300 && ybRes.displayed.fat >= 0, "Book mode applies the picker proportionally (no negatives): \(String(format: "%.1f", ybRes.displayed.calories)) kcal")
    // the Cut version leaves yogurt lines to the picker
    yu.data.goal = .cut
    check(!yu.goalResolution(yr, catalog: gcat2).changes.contains { $0.id == "cut:swap:b0" }, "the Cut version's own yogurt swap is a no-op under the picker")
    check(UserStore.encode(yu.data).flatMap { UserStore.decode($0) }?.greekYogurt == .zero && UserData().greekYogurt == .zero, "the setting persists, default 0%")

    // ---- Sushi chip
    let sushiRecipes = RecipeStore.decodeRecipes(Data(#"[{"id":"s1","name":"Spicy Tuna Maki","section":"meal","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},{"id":"s2","name":"Rainbow Bowl","tags":["sushi"],"section":"meal","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},{"id":"s3","name":"Onigiri Triangles","section":"meal","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},{"id":"s4","name":"Pasta Salad","section":"meal","base":[{"text":"x","key":"x"}],"instructions":["a","b"]}]"#.utf8))
    check(sushiRecipes.map { $0.mealChipMatches(keys: []).contains("sushi") } == [true, true, true, false] && Recipe.mealChips.contains { $0.id == "sushi" }, "Sushi chip: tag 'sushi' or maki / nigiri / temaki / onigiri / inari ... in the name")
    do {
        let sr = store.recipes.filter { store.index[$0.id]?.chips.contains("sushi") == true }
        let japanese = store.recipes.filter { $0.tags.contains("sushi") }
        print("  real data: \(sr.count) recipes match the Sushi chip (\(japanese.count) tagged sushi)")
        check(japanese.allSatisfy { store.index[$0.id]?.chips.contains("sushi") == true }, "every sushi-tagged recipe is matched by the Sushi chip")
    }

    // ---- clarity text rules (display only)
    print("(clarity) text rules and notes")
    if let cl = store.catalog.clarity {
        let rules = ClarityRules(textRules: cl.textRules)
        check(cl.textRules.count > 50 && cl.ingredientNotes.count > 100, "clarity_notes.json loads: \(cl.textRules.count) rules, \(cl.ingredientNotes.count) ingredient notes")
        let cases: [(String, String)] = [
            ("2 tbsp tomato puree", "(tomato paste)"), ("1 cup cornflour", "(cornstarch)"), ("200 g plain flour", "(all-purpose flour)"),
            ("a handful of coriander leaves", "(cilantro)"), ("2 tbsp Coriander", "(cilantro)"),
        ]
        for (before, expect) in cases {
            let after = rules.annotate(before)
            check(after.contains(expect) && after.hasPrefix(before.prefix(8)), "\"\(before)\" -> \"\(after)\"")
        }
        check(rules.annotate("1 tsp ground coriander") == "1 tsp ground coriander" && rules.annotate("1 tsp coriander seeds") == "1 tsp coriander seeds", "ground coriander is NOT turned into cilantro")
        check(rules.annotate("1 cup salsa see note") == "1 cup salsa", "\"1 cup salsa see note\" -> \"1 cup salsa\"")
        let nested = "1 tbsp soy sauce ((or tamari (wheat-free soy sauce)))"
        check(rules.annotate(nested) == nested, "no annotation inside existing parentheses (tamari nesting): \(rules.annotate(nested))")
        let flax = "1 eggs ((use 'flax' eggs to make vegan. One flax egg = 1 tbsp flax seeds))"
        check(rules.annotate(flax) == flax, "the flax-egg rule does not fire inside a parenthetical")
        check(rules.annotate("1 cup all-purpose flour, or plain flour") == "1 cup all-purpose flour, or plain flour", "a rule is skipped when the US term is already on the line")
        check(rules.annotate("2 tbsp tomato puree") == rules.annotate(rules.annotate("2 tbsp tomato puree")), "annotating twice changes nothing")
    } else { check(false, "clarity_notes.json not loaded") }

    // ---- negative-macro sweep: no recipe, source (Book / Calculated) or version (Cut / Maintain / Bulk) may show a negative number
    print("(neg) negative-macro sweep")
    do {
        let rc = NutritionCalculator(catalog: store.catalog)
        var negatives: [String] = []
        var cutLow: [String] = []
        for r in store.recipes {
            let vegActive = r.vegAdaptation != nil && r.vegetarian != true
            for (src, yp) in [(CalorieSource.book, GreekYogurtPref.asWritten), (.calculated, .asWritten), (.book, .zero), (.calculated, .zero)] {
                var base = RecipeConfig(vegActive: vegActive, preferEasy: true, source: src)
                base.useEstimates = true
                base.yogurtPref = yp
                var per: [Goal: Nutrition] = [:]
                for g in [Goal.cut, .maintain, .bulk] {
                    let gr = GoalVersion.resolve(r, catalog: store.catalog, base: base, goal: g, toggles: [:], vegetarianUser: true)
                    let ps = rc.compute(r, gr.cfg).displayed * (1 / r.perServingDivisor)      // hidden (missing-flag) fields are checked too
                    per[g] = ps
                    for (name, v) in [("kcal", ps.calories), ("protein", ps.protein), ("carbs", ps.carbs), ("fat", ps.fat), ("sugar", ps.sugar), ("fiber", ps.fiber)] where v < -0.05 {
                        negatives.append("\(r.id) \(src.rawValue)/\(g.rawValue)/\(yp.rawValue) \(name)=\(String(format: "%.1f", v))")
                    }
                }
                if let c = per[.cut], let mt = per[.maintain], mt.calories > 0, c.calories < 0.15 * mt.calories { cutLow.append("\(r.id)") }
            }
        }
        if !negatives.isEmpty { print("    negatives: \(negatives.prefix(12))") }
        check(negatives.isEmpty, "0 negative fields across \(store.recipes.count) recipes x {Book, Calculated} x {yogurt as written, 0%} x {Cut, Maintain, Bulk} (found \(negatives.count))")
        // Cut below 15% of Maintain is only allowed for recipes the audit explained (printed numbers or amounts that make the whole recipe tiny)
        let cutLowAllowed: [String: String] = [
            "web-pistachio-ice-cream-real-pistachios": "Creami: nuts dominate the maintain total, cut swaps/portion shrink it",
            "web-hazelnut-praline-gelato": "Creami: very rich pint, cut portion applies",
            "web-meal-air-fired-spiced-chickpeas-milk-street": "printed per-serving numbers are far above the catalog sum",
            "web-tt-lemonade-italian-ice": "tiny sorbet where the portion floor dominates",
            "web-budget-delicious-coconut-ice-cream": "Creami: coconut cream pint, cut portion applies",
            "web-george-eats-lemon-curd-ice-cream": "Creami: egg yolk and cream pint, cut portion applies",
            "web-meal-vegetarian-rogan-josh-lentil-littlesugarsnaps": "amount errors in the source (fixed at build time when possible)",
        ]
        let unexplained = Set(cutLow).subtracting(cutLowAllowed.keys)
        check(unexplained.isEmpty, "Cut < 15% of Maintain only for the audited list (\(Set(cutLow).count) rows, unexplained: \(unexplained.sorted()))")
    }

    // saved per goal: migration, persistence
    let oldFile = Data(#"{"favorites":["a","b"],"goal":"cut"}"#.utf8)
    let mig = UserStore.decode(oldFile)
    check(mig?.saved == ["a": .maintain, "b": .maintain] && mig?.favorites.isEmpty == true, "old favorites migrate to Saved for Maintain and are kept")
    if let mig, let again = UserStore.encode(mig).flatMap({ UserStore.decode($0) }) {
        var more = again; more.saved["c"] = .bulk
        let third = UserStore.encode(more).flatMap { UserStore.decode($0) }
        check(again.saved == mig.saved && third?.saved["c"] == .bulk && third?.saved.count == 3, "migration runs once; later saves persist")
    }
    let sv = UserStore(fileURL: nil)
    sv.save("r1", for: .cut); sv.save("r1", for: .bulk); sv.save("r2", for: .maintain); sv.unsave("r2")
    check(sv.savedGoal("r1") == .bulk && !sv.isSaved("r2"), "save for a goal, re-save for another, unsave")

    // rating: persistence, clear on same star, rating sort prefers the user's stars over the made log
    sv.setRating("r1", 4); sv.setRating("r3", 2)
    check(sv.rating("r1") == 4, "rating set")
    sv.setRating("r3", 2)
    check(sv.rating("r3") == 0, "tapping the same star again clears the rating")
    if let back = UserStore.encode(sv.data).flatMap({ UserStore.decode($0) }) { check(back.ratings == ["r1": 4], "ratings round-trip through JSON") }
    let rated = RecipeStore.decodeRecipes(Data(#"[{"id":"r1","name":"Alpha","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},{"id":"r2","name":"Beta","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},{"id":"r3","name":"Gamma","base":[{"text":"x","key":"x"}],"instructions":["a","b"]}]"#.utf8))
    let rs = RecipeStore(); rs.apply(LoadedData(recipes: rated, catalog: Catalog()))
    var rctx = FilterContext(madeLog: [MadeEntry(recipeId: "r2", rating: 5), MadeEntry(recipeId: "r3", rating: 3)], ratings: ["r1": 4])
    var rf = FilterState(); rf.section = nil; rf.sort = .rating
    check(FilterEngine.apply(store: rs, recipes: rs.recipes, query: "", state: rf, ctx: rctx).map(\.id) == ["r2", "r1", "r3"], "rating sort: own stars (r1 = 4) beat nothing, made-log average (r2 = 5, r3 = 3) is the fallback")
    rctx.ratings = ["r1": 5]
    check(FilterEngine.apply(store: rs, recipes: rs.recipes, query: "", state: rf, ctx: rctx).first?.id == "r1" || FilterEngine.apply(store: rs, recipes: rs.recipes, query: "", state: rf, ctx: rctx).map(\.id) == ["r1", "r2", "r3"], "own rating changes the order")

    // quickest sort: prep + cook, unknown last
    let qr = RecipeStore.decodeRecipes(Data(#"""
    [{"id":"q1","name":"Slow","prepMinutes":20,"cookMinutes":40,"chillHours":8,"base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"id":"q2","name":"Fast","prepMinutes":5,"cookMinutes":10,"base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"id":"q3","name":"Unknown","base":[{"text":"x","key":"x"}],"instructions":["a","b"]},
     {"id":"q4","name":"CookOnly","cookMinutes":12,"freezeHours":16,"base":[{"text":"x","key":"x"}],"instructions":["a","b"]}]
    """#.utf8))
    let qs = RecipeStore(); qs.apply(LoadedData(recipes: qr, catalog: Catalog()))
    var qf = FilterState(); qf.section = nil; qf.sort = .quickest
    check(FilterEngine.apply(store: qs, recipes: qs.recipes, query: "", state: qf, ctx: FilterContext()).map(\.id) == ["q4", "q2", "q1", "q3"], "quickest: prep + cook ascending (chill/freeze excluded), unknown time last")

    // null macros show a dash
    let nullMacros = RecipeStore.decodeRecipes(Data(#"[{"name":"N","servings":1,"macros":{"calories":300,"protein":20,"carbs":30,"fat":10,"sugar":null}}]"#.utf8))
    if let n = nullMacros.first?.macros {
        let scaled = (n + .zero) * 2
        check(n.isMissing("sugar") && n.isMissing("fiber") && !n.isMissing("protein") && scaled.isMissing("sugar") && !(Nutrition.zero + n).isMissing("sugar"), "null macros are flagged missing (shown as a dash) and survive scaling")
    }
    let tl = RecipeStore.decodeRecipes(Data(#"[{"name":"A","section":"meal","cookMinutes":20},{"name":"B","section":"meal"},{"name":"C","section":"dessert","chillHours":4},{"name":"D"}]"#.utf8))
    check(tl.map { $0.timerLabel } == ["Timer", nil, "Chill", "Freeze"] && tl[0].timerHours == 20.0 / 60, "timer label: meals 'Timer' (cookMinutes), desserts 'Chill', Creami 'Freeze', none without a time")

    // performance: filtering all recipes with a typical filter set
    print("(perf)")
    do {
        var pf = FilterState(); pf.section = nil; pf.tags = ["high-protein"]; pf.hideAffiliate = false; pf.noEgg = true; pf.maxCalories = 900; pf.sort = .healthiest
        let pctx = FilterContext(favorites: [], missing: [], madeLog: [], displayed: { $0.macros ?? .zero })
        var times: [Double] = []
        for _ in 0..<20 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = FilterEngine.apply(store: store, recipes: store.recipes, query: "chicken", state: pf, ctx: pctx)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        times.sort()
        check(times[10] < 30, "FilterEngine.apply over \(store.recipes.count) recipes: median \(String(format: "%.1f", times[10])) ms (< 30 ms)")
        // cached display values: cold vs warm
        let pu = UserStore(fileURL: nil)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for r in store.recipes { _ = pu.display(for: r, catalog: store.catalog) }
        let cold = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let t1 = DispatchTime.now().uptimeNanoseconds
        for r in store.recipes { _ = pu.display(for: r, catalog: store.catalog) }
        let warm = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        check(warm < 30, "displayed-macros cache over all recipes: cold \(String(format: "%.0f", cold)) ms, warm \(String(format: "%.1f", warm)) ms (< 30 ms)")
    }

    // data-fix app features: veg-mode pro tip, servingLabel, source.alsoIn
    print("(f14-16) pro tip / pieces / also in")
    let tipRecipes = RecipeStore.decodeRecipes(Data(#"[{"name":"Nuggets","servingLabel":"piece","servings":12,"source":{"kind":"book","alsoIn":"The Ultimate Guide to Lean Bulking p.33"},"proTip":{"title":"Tip","text":"Press the tofu well. Brush the chicken with oil. Use veggie bacon for crunch. Add real bacon bits!"}},{"name":"T2","proTip":{"title":"Tip","text":"Cook the steak rare."}}]"#.utf8))
    if tipRecipes.count == 2 {
        check(tipRecipes[0].proTip(vegMode: true)?.text == "Press the tofu well. Use veggie bacon for crunch.", "veg-mode pro tip drops meat sentences, keeps 'veggie bacon' (\(tipRecipes[0].proTip(vegMode: true)?.text ?? "nil"))")
        check(tipRecipes[0].proTip(vegMode: false)?.text.contains("chicken") == true, "pro tip untouched when not vegetarian")
        check(tipRecipes[1].proTip(vegMode: true) == nil, "pro tip card hidden when nothing is left")
        check(tipRecipes[0].servingLabel == "piece" && tipRecipes[0].servingNoun == "piece" && tipRecipes[1].servingNoun == "serving", "servingLabel piece decodes")
        check(tipRecipes[0].source.alsoIn == "The Ultimate Guide to Lean Bulking p.33", "source.alsoIn decodes")
    } else { check(false, "pro tip fixtures did not decode") }

    // ranked vegetarian alternatives
    print("(v) ranked vegetarian alternatives")
    if let bowl = fx.recipes.first(where: { $0.id == "chef-chicken-bowl" }) {
        let tofu = "tofu_extra_firm"
        let us = UserStore(fileURL: nil)
        // (b) default selection
        let easy = us.vegResolution(bowl, catalog: fstore.catalog).lines["b0"]
        check(easy?.chosenKey == tofu && easy?.defaultKey == "seitan" && (easy?.options.count ?? 0) == 3, "prefer easy ON: default is the first 'everywhere' alternative (\(easy?.chosenKey ?? "-"))")
        us.data.preferEasyAlternatives = false
        let own = us.vegResolution(bowl, catalog: fstore.catalog).lines["b0"]
        check(own?.chosenKey == "seitan", "prefer easy OFF: the vegAdaptation's own sub (seitan) is the default")
        let ownRes = fcalc.compute(bowl, us.config(for: bowl, catalog: fstore.catalog))
        check(ownRes.displayed.calories == 960 && ownRes.lines.first?.ing.text == "375 g seitan", "default sub keeps the authored amount and macros (480 x 2 = \(ownRes.displayed.calories))")
        // (a) switch to tofu: protein-matched against the raw meat role values (23 g P/100 g)
        us.data.vegChoice[bowl.id] = ["b0": tofu]
        let res = us.vegResolution(bowl, catalog: fstore.catalog)
        let opt = res.lines["b0"]?.chosen
        check(opt?.grams == 430, "300 g chicken (23 P/100 g) -> tofu (16 P/100 g) = \(opt?.grams ?? -1) g (300x23/16 = 431 -> 430)")
        let cfgTofu = us.config(for: bowl, catalog: fstore.catalog)
        let tofuRes = fcalc.compute(bowl, cfgTofu)
        let expectDelta = 145 * 4.30 - 140 * 2.75           // tofu 430 g minus the default seitan at protein-matched 275 g
        check(near(tofuRes.displayed.calories - ownRes.displayed.calories, expectDelta, 1),
              "veg macros delta = alt - default: \(String(format: "%.1f", tofuRes.displayed.calories - ownRes.displayed.calories)) kcal (expected \(String(format: "%.1f", expectDelta)))")
        check(tofuRes.lines.first?.grams == 430 && near(tofuRes.calculated.calories, 145 * 4.30, 1), "calculated source uses 430 g of tofu")
        check(near(opt?.deltaPerServing.calories ?? 0, expectDelta / 2, 0.5), "chip delta vs default is per serving")
        // protein-matched chips: every alternative's protein delta per serving is about zero
        let allOpts = res.lines["b0"]?.options ?? []
        check(allOpts.count == 3 && allOpts.allSatisfy { abs($0.deltaPerServing.protein) <= 1 }, "chips are protein-matched: |protein delta| per serving <= 1 g for every alternative (\(allOpts.map { String(format: "%.2f", $0.deltaPerServing.protein) }))")
        check(allOpts.first(where: { $0.isDefault })?.deltaPerServing.calories == 0, "default chip delta is zero")
        // veg-mode display names
        check(VegAlternatives.replaceMeatWords(in: "Beef & Broccoli Fried Rice", with: "Tofu") == "Tofu & Broccoli Fried Rice"
              && VegAlternatives.replaceMeatWords(in: "Seasoned Beef: 30 ml soy", with: "Tofu") == "Seasoned Tofu: 30 ml soy", "meat words replaced by the alternative's short name")
        let vegBowl = us.effectiveRecipe(bowl, catalog: fstore.catalog)
        check(vegBowl.name == "Extra-firm tofu".prefix(0) + "Chicken Bowl".replacingOccurrences(of: "Chicken", with: "Tofu") && bowl.name == "Chicken Bowl", "veg title: \(vegBowl.name) (original \(bowl.name))")
        check(us.display(for: bowl, catalog: fstore.catalog).title == "Tofu Bowl" && us.display(for: bowl, catalog: fstore.catalog).vegTitle, "card display uses the veg title")
        us.data.showOriginal.insert(bowl.id)
        check(us.display(for: bowl, catalog: fstore.catalog).title == "Chicken Bowl", "display cache follows the Original toggle")
        us.data.showOriginal = []
        check(VegAlternatives.shortName(VegAlt.testAlt("veggie_bacon", "Veggie bacon")) == "Veggie bacon" && VegAlternatives.shortName(VegAlt.testAlt("tofu_extra_firm", "Extra-firm tofu")) == "Tofu", "short names keep 'Veggie' for bacon, 'Tofu' for tofu")
        // (c) persistence
        var data = us.data
        data.preferEasyAlternatives = false
        if let enc = UserStore.encode(data), let back = UserStore.decode(enc) {
            check(back.vegChoice[bowl.id]?["b0"] == tofu && back.preferEasyAlternatives == false && back == data, "per-recipe choice and the easy-to-find setting round-trip through JSON")
            let us2 = UserStore(fileURL: nil); us2.data = back
            check(us2.vegResolution(bowl, catalog: fstore.catalog).lines["b0"]?.chosenKey == tofu, "restored choice is applied")
        } else { check(false, "UserData encode/decode failed") }
        // (d) shopping + cook mode text
        let shop = ShoppingList.items(for: bowl, cfg: cfgTofu, catalog: fstore.catalog)
        check(shop.contains { $0.text == "Extra-firm tofu" } && !shop.contains { $0.text.lowercased().contains("seitan") || $0.text.lowercased().contains("chicken") }, "shopping list uses the chosen alternative's name")
        let eff = us.effectiveRecipe(bowl, catalog: fstore.catalog)
        check(eff.instructions.joined(separator: " ").contains("Extra-firm tofu") && !eff.instructions.joined(separator: " ").lowercased().contains("seitan"), "steps name the chosen alternative")
        check(eff.instructions.first?.hasPrefix("Prep:") == true && eff.instructions.first?.contains("Press 15 min") == true, "alt prep line is step 0")
        check(eff.base.first?.text == "430 g Extra-firm tofu", "cook-mode checklist line: \(eff.base.first?.text ?? "-")")
        // keywords beat keyToRole, but only within the same food family
        check(d0Role("chicken_breast", "300 g chicken breast", "Chicken Tikka Bowl") == "chicken_curry"
              && d0Role("chicken_breast", "300 g chicken breast", "Plain Bowl") == "chicken_strips"
              && d0Role("beef_mince", "200 g beef mince", "Chicken Tikka Bowl") == "mince", "role keywords: recipe name wins within the same family (tikka -> curry), other foods keep their own role")
        // role matching by matchKeys / keyword
        let d = fstore.catalog.vegAlts
        check(d?.role(forKey: "chicken_breast", text: "x", recipeName: "Plain bowl")?.id == "chicken_strips" && d?.role(forKey: "beef_mince", text: "x")?.id == "mince"
              && d?.role(forKey: nil, text: "2 mince patties")?.id == "mince" && d?.role(forKey: "unknown", text: "shredded chicken thigh")?.id == "chicken_strips", "role lookup: keyToRole, matchKeys, keyword")
    } else { check(false, "fixture chicken bowl missing") }

    // real data: veg alternatives against the bundled books
    print("(v2) real veg_alternatives.json")
    if let real = store.catalog.vegAlts {
        check(real.roles.count >= 10 && !real.keyToRole.isEmpty, "real veg alternatives: \(real.roles.count) roles, \(real.keyToRole.count) keyToRole entries")
        let ruser = UserStore(fileURL: nil)
        if let bc = store.recipes.first(where: { $0.source.isBook && $0.name.lowercased().contains("butter chicken") && $0.vegAdaptation != nil }) {
            let lines = ruser.vegResolution(bc, catalog: store.catalog).lines.values.filter { $0.original.key?.contains("chicken") == true }
            check(!lines.isEmpty && lines.allSatisfy { $0.roleId == "chicken_curry" && $0.options.first?.alt.key == "paneer" },
                  "\(bc.name): chicken line -> curry role with paneer as Alt 1 (\(lines.map { $0.roleId + "/" + ($0.options.first?.alt.key ?? "-") }))")
        } else { check(false, "no book Butter Chicken recipe with a vegAdaptation") }

        var offUser = UserStore(fileURL: nil); offUser.data.preferEasyAlternatives = false
        var seitanChecked = 0, seitanKept = 0, seitanNotInRole = 0
        for r in store.recipes where r.source.isBook {
            guard let adapt = r.vegAdaptation else { continue }
            for sw in adapt.swaps where sw.with.key == "seitan" {
                guard let lk = r.allLines.first(where: { $0.ing.text == sw.replaces })?.key,
                      let line = offUser.vegResolution(r, catalog: store.catalog).lines[lk] else { continue }
                guard line.options.contains(where: { $0.alt.key == "seitan" }) else { seitanNotInRole += 1; continue }   // default only applies when it is in the role's list
                seitanChecked += 1
                if line.chosenKey == "seitan" { seitanKept += 1 }
            }
        }
        check(seitanChecked > 0 && seitanKept == seitanChecked, "prefer easy OFF keeps the book's seitan default (\(seitanKept) of \(seitanChecked) seitan swaps; \(seitanNotInRole) more sit in roles without seitan, e.g. curry)")
        offUser = UserStore(fileURL: nil)

        // every swap of a meat line resolves to a role
        let notRoles = ["stock", "broth", "bouillon", "boullion", "sauce", "baking_soda"]   // handled by plain veg swaps, not meat roles
        let meatWords = ["chicken", "beef", "pork", "bacon", "ham", "turkey", "sausage", "fish", "salmon", "tuna", "prawn", "shrimp", "lamb", "chorizo", "pepperoni", "mince", "steak", "meat", "salami", "cod"]
        var total = 0
        var unresolved: [String] = []
        for r in store.recipes where r.vegAdaptation != nil {
            for sw in r.vegAdaptation!.swaps {
                guard let ing = r.allIngredients.first(where: { $0.text == sw.replaces }) else { continue }
                let k = (ing.key ?? "").lowercased() + " " + ing.text.lowercased()
                guard meatWords.contains(where: { k.contains($0) }), !notRoles.contains(where: { k.contains($0) }) else { continue }
                total += 1
                if real.role(forKey: ing.key, text: ing.text, recipeName: r.name) == nil { unresolved.append("\(r.id): \(ing.text) [\(ing.key ?? "nil")]") }
            }
        }
        print("  meat-line swaps in the books: \(total), unresolved: \(unresolved.count)")
        for u in unresolved.prefix(30) { print("    unresolved \(u)") }
        check(unresolved.isEmpty, "every vegAdaptation swap of a meat line resolves to a role")
    } else {
        print("  (no real veg_alternatives.json bundled: skipped)")
    }

    let chicken = fstore.catalog.info("chicken_breast")
    check(chicken?.vegetarian == .no && chicken?.vegNote == "Meat", "catalog vegetarian=false + vegNote decode")
    check(fstore.catalog.info("greek_yogurt")?.vegetarian == .yes && fstore.catalog.info("banana")?.vegetarian == .check
          && IngredientInfo(name: "x").vegetarian == .yes, "vegetarian flag: bool, string and absent")

    var fe = FilterState(); fe.section = nil; fe.noEgg = true
    let noEgg = FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fe, ctx: ctx).map(\.id)
    check(!noEgg.contains("chef-omelette") && noEgg.contains("chef-chicken-wrap") && noEgg.contains("bulk-oat-shake"), "No egg filter drops the omelette only")
    var fv2 = FilterState(); fv2.section = nil; fv2.hasVegVersion = true
    check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fv2, ctx: ctx).map(\.id).sorted() == ["chef-chicken-bowl", "chef-chicken-wrap"], "Has veg version filter")
    fv2 = FilterState(); fv2.section = nil; fv2.vegAsWritten = true
    check(Set(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fv2, ctx: ctx).map(\.id)) == ["chef-omelette", "bulk-oat-shake", "web-paneer-tikka", "web-carbonara", "web-hakka", "web-korean-cauliflower-wings"], "Vegetarian as written filter")
    var fm = FilterState(); fm.section = "meal"; fm.courses = ["breakfast"]
    check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fm, ctx: ctx).map(\.id) == ["chef-omelette"], "meal section + course filter")
    fm = FilterState(); fm.section = "meal"; fm.books = ["The Ultimate Guide to Lean Bulking"]
    check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fm, ctx: ctx).map(\.id) == ["chef-omelette"], "source-book filter")
    if let w = fx.recipes.first(where: { $0.id == "web-paneer-tikka" }) {
        check(w.source.kind == "web" && w.macros?.calories == 800 && w.macros?.fiber == 18 && w.cuisine == "indian", "web meal (macrosPerServing) normalized like books: 400 x 2 = \(w.macros?.calories ?? -1) kcal")
    }
    @MainActor func chip(_ id: String) -> [String] {
        var s = FilterState(); s.section = nil; s.mealChips = [id]
        return FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: s, ctx: ctx).map(\.id)
    }
    check(chip("paneer") == ["web-paneer-tikka"] && chip("indian") == ["web-paneer-tikka"] && chip("spicy").sorted() == ["web-korean-cauliflower-wings", "web-paneer-tikka"], "meal chips: paneer (ingredient), indian (cuisine), spicy (tag)")
    check(chip("pasta") == ["web-carbonara"], "Pasta chip catches the Carbonara recipe (by name)")
    check(chip("noodles") == ["web-hakka"], "Noodles chip catches Hakka Noodles")
    check(chip("paneer") == ["web-paneer-tikka"] && !chip("pasta").contains("web-hakka"), "Pasta chip does not catch noodle recipes")
    check(chip("breakfast") == ["chef-omelette"] && chip("tofu").isEmpty, "meal chips: breakfast (course); tofu matches by ingredient key (none in fixtures)")
    var fh = FilterState(); fh.section = nil; fh.highFiber = true
    check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fh, ctx: ctx).map(\.id) == ["web-paneer-tikka"], "High fiber filter (fiber/serving >= 8 or tag)")
    var fs2 = FilterState(); fs2.section = nil; fs2.sort = .healthiest
    let healthiest = FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fs2, ctx: FilterContext(displayed: { $0.macros ?? .zero }))
    check(healthiest.first?.id == "chef-omelette", "Healthiest sort runs (top: \(healthiest.first?.name ?? "-"))")
    let pp = healthiest.map { ($0.macros ?? .zero).proteinPer100kcal }
    check(zip(pp, pp.dropFirst()).allSatisfy { $0 >= $1 }, "Healthiest sort is protein per 100 kcal descending")
    check(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: FilterState(), ctx: ctx).isEmpty, "default (Creami) view hides meals and drinks")

    check(fstore.catalog.guides.count == 1 && fstore.catalog.guides[0].sections[0].table?.rows.first == ["Whole", "180 g"]
          && fstore.catalog.guides[0].sections[0].bullets?.count == 2, "guides.json decodes (sections, bullets, table)")

    print("(p) paneer calculator")
    if let model = fstore.catalog.paneer, let whole = fstore.catalog.liquids.first(where: { $0.id == "whole_milk" }) {
        let r = PaneerCalculator.estimate(milk: whole, liters: 1, model: model)
        let k = 1000.0 / 240.0
        let expected = (8 * k * 0.75 + 8 * k * 0.9 + 12 * k * 0.05) / (1 - 0.55)
        check(near(r.yieldGrams, expected, 1), "1 L whole milk: \(String(format: "%.1f", r.yieldGrams)) g (formula \(String(format: "%.1f", expected)) g)")
        check(near(r.total.protein, 8 * k * 0.75, 0.01) && near(r.per100g.protein, r.total.protein / r.yieldGrams * 100, 0.01), "paneer macros total and per 100 g")
        let uf = fstore.catalog.liquids.first { $0.id == "fairlife_skim" }!
        check(near(PaneerCalculator.estimate(milk: uf, liters: 1, model: model).total.protein, 13 * k * 0.8, 0.01), "per-milk override applied")
        check(near(PaneerCalculator.estimate(milk: whole, liters: 3, model: model).yieldGrams, expected * 3, 3), "volume scales linearly")
        let table = PaneerCalculator.comparison(milks: PaneerCalculator.eligible(fstore.catalog.liquids), model: model)
        check(table.count == 2 && table[0].result.per100g.proteinPer100kcal >= table[1].result.per100g.proteinPer100kcal, "comparison sorted by protein per 100 kcal")
    } else { check(false, "fixture paneer model or whole milk missing") }

    // (f) hide affiliate
    print("(f) affiliate filter")
    let aff = all.filter { $0.allIngredients.contains { $0.key == "prime_bites_brownie" } }
    check(!aff.isEmpty, "\(aff.count) recipes contain prime_bites_brownie")
    var fs = FilterState(); fs.section = nil; fs.hideAffiliate = true
    let kept = Set(FilterEngine.apply(store: store, recipes: all, query: "", state: fs, ctx: ctx).map(\.id))
    check(aff.allSatisfy { !kept.contains($0.id) }, "hideAffiliate excludes all of them")
    check(kept.count < all.count && !kept.isEmpty, "and keeps the rest (\(kept.count) of \(all.count))")
    var fb = FilterState(); fb.section = nil; fb.excludedBrands = ["Prime Bites"]
    let keptB = Set(FilterEngine.apply(store: store, recipes: all, query: "", state: fb, ctx: ctx).map(\.id))
    check(aff.allSatisfy { !keptB.contains($0.id) }, "excluding brand Prime Bites does too")

    // (g) can make now
    print("(g) pantry")
    if let r = all.first(where: { $0.allIngredients.contains { !$0.optional && $0.key != nil } }), let key = r.allIngredients.first(where: { !$0.optional && $0.key != nil })?.key {
        var fm = FilterState(); fm.section = nil; fm.canMakeNow = true
        var c = FilterContext()
        let before = FilterEngine.apply(store: store, recipes: all, query: "", state: fm, ctx: c).contains { $0.id == r.id }
        c.missing = [key]
        let after = FilterEngine.apply(store: store, recipes: all, query: "", state: fm, ctx: c).contains { $0.id == r.id }
        check(before && !after, "\(r.name): can-make-now true -> false after marking \(key) missing")
        c.missing = []
        check(FilterEngine.apply(store: store, recipes: all, query: "", state: fm, ctx: c).count == all.count, "all recipes makeable with empty missing set")
    }

    // (h) persistence
    print("(h) persistence")
    var u = UserData()
    u.saved = ["a": .cut, "b": .bulk]; u.ratings = ["a": 4]; u.recipeGoal = ["a": .bulk]; u.goalToggles = ["a": ["cut:portion": false]]; u.recipeMilk = ["a": "oat"]; u.defaultMilkId = "fairlife_2pct"
    u.swaps = ["a": ["b0": 1]]; u.pints = ["a": 3]; u.defaultCalorieSource = .calculated
    u.pantryMissing = ["salt"]
    u.nutritionOverrides = ["salt": NutritionOverride(per100g: Nutrition(calories: 1, protein: 2), sourceLabel: "OFF", productName: "Salt")]
    u.customLiquids = [BaseLiquid(id: "m", name: "My milk", family: "milk", perServing: Nutrition(calories: 90))]
    u.madeLog = [MadeEntry(recipeId: "a", date: Date(timeIntervalSince1970: 1_700_000_000), rating: 4, note: "yum")]
    u.freezer = [FreezeTimer(recipeId: "a", start: Date(timeIntervalSince1970: 1_700_000_000), readyAt: Date(timeIntervalSince1970: 1_700_050_000))]
    u.shopping = [ShoppingItem(key: "salt", text: "Salt", category: "spice", grams: 5)]
    u.filterState.tags = ["healthy"]; u.filterState.maxCalories = 400; u.filterState.sort = .rating
    let enc = UserStore.encode(u)
    let dec = enc.flatMap { UserStore.decode($0) }
    check(dec == u, "UserData round-trips through JSON")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("creami-\(UUID().uuidString).json")
    try? Data("{ not json".utf8).write(to: tmp)
    check(UserStore.loadData(at: tmp) == UserData(), "corrupt file yields fresh data")
    try? FileManager.default.removeItem(at: tmp.appendingPathExtension("corrupt"))
    check(UserStore.loadData(at: tmp.appendingPathExtension("nope")) == UserData(), "missing file yields fresh data")
    try? Data(#"{"favorites":["x"],"pints":"oops"}"#.utf8).write(to: tmp)
    let partial = UserStore.loadData(at: tmp)
    check(partial.saved["x"] == .maintain && partial.pints.isEmpty, "partially valid file keeps good fields (an old favorite becomes Saved for Maintain)")
    try? FileManager.default.removeItem(at: tmp)
    let us = UserStore(fileURL: nil)
    us.save("z", for: .bulk)
    check(us.isSaved("z") && us.savedGoal("z") == .bulk, "in-memory store works")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

extension VegAlt {
    static func testAlt(_ key: String, _ name: String) -> VegAlt {
        let json = #"{"key":"\#(key)","name":"\#(name)"}"#
        return try! JSONDecoder().decode(VegAlt.self, from: Data(json.utf8))
    }
}
