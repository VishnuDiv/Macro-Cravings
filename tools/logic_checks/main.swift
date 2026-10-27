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
        let before = calc.compute(r, cfg()).displayed.calories
        let after = calc.compute(r, c).displayed.calories
        let expected = x * 400 / (240 * 1.03)
        check(near(after - before, expected, 1), "\(r.name): +\(x) kcal/240ml -> \(String(format: "%.2f", after - before)) kcal (expected \(String(format: "%.2f", expected)))")
        c.source = .calculated
        let d2 = calc.compute(r, c).displayed.calories - calc.compute(r, cfg(.calculated)).displayed.calories
        check(near(d2, expected, 1), "calculated source gives same delta (\(String(format: "%.2f", d2)))")
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
                let got = calc.compute(r, c).displayed.calories - calc.compute(r, cfg()).displayed.calories
                check(near(got, expected, 0.01), "\(r.name): \(ing.key ?? "") -> \(sk) x\(s.ratio): \(String(format: "%.2f", got)) kcal (expected \(String(format: "%.2f", expected)))")
                let impact = calc.swapImpact(r, lineKey: lk, swapIndex: si, cfg: cfg())
                check(near(impact.delta.calories, expected, 0.01) && impact.recalculated, "swapImpact agrees")
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
    check(fx.recipes.count == 7, "fixture build produced 4 book + 3 web meal recipes (\(fx.recipes.count))")
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
    check(Set(FilterEngine.apply(store: fstore, recipes: fstore.recipes, query: "", state: fv2, ctx: ctx).map(\.id)) == ["chef-omelette", "bulk-oat-shake", "web-paneer-tikka", "web-carbonara", "web-hakka"], "Vegetarian as written filter")
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
    check(chip("paneer") == ["web-paneer-tikka"] && chip("indian") == ["web-paneer-tikka"] && chip("spicy") == ["web-paneer-tikka"], "meal chips: paneer (ingredient), indian (cuisine), spicy (tag)")
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
    u.favorites = ["a", "b"]; u.recipeMilk = ["a": "oat"]; u.defaultMilkId = "fairlife_2pct"
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
    check(partial.favorites == ["x"] && partial.pints.isEmpty, "partially valid file keeps good fields")
    try? FileManager.default.removeItem(at: tmp)
    let us = UserStore(fileURL: nil)
    us.toggleFavorite("z")
    check(us.isFavorite("z"), "in-memory store works")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)

extension VegAlt {
    static func testAlt(_ key: String, _ name: String) -> VegAlt {
        let json = #"{"key":"\#(key)","name":"\#(name)"}"#
        return try! JSONDecoder().decode(VegAlt.self, from: Data(json.utf8))
    }
}
