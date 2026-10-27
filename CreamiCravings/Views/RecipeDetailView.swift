import SwiftUI

struct RecipeDetailView: View {
    let recipe: Recipe
    init(recipe: Recipe) {
        self.recipe = recipe
        _perServing = State(initialValue: recipe.usesServings)
        _servings = State(initialValue: recipe.usesServings ? 1 : 2)
    }
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var showCompare = false
    @State private var swapLine: String?
    @State private var showAddMilk = false
    @State private var showAddPowder = false
    @State private var showLog = false
    @State private var perServing = false
    @State private var servings = 2
    @State private var addedToList = false
    @State private var timerStarted = false
    #if DEBUG
    @State private var ssScroll = ScrollPosition()           // README screenshots: scroll to -ssAnchor
    #endif

    /// Screenshot mode never loads remote photos, so it shows no credit for them either.
    private var photoCreditHidden: Bool {
        #if DEBUG
        return ScreenshotMode.isActive
        #else
        return false
        #endif
    }

    private var vegOn: Bool { user.vegActive(recipe) }
    private var hasVegChoice: Bool { user.data.isVegetarian && recipe.vegAdaptation != nil && recipe.vegetarian != true }
    private var vegRes: VegResolution { vegOn ? user.vegResolution(recipe, catalog: store.catalog) : VegResolution(recipe: recipe, lines: [:]) }
    private var shown: Recipe { user.effectiveRecipe(recipe, catalog: store.catalog) }

    /// Vegan for the version on screen: veg version, chosen alternatives, protein upgrade, goal swaps and add-ons.
    private var veganNow: Bool {
        var keys: [String?] = []
        for l in result.lines where l.included {
            if l.swap != nil && l.swap?.key == nil { continue }       // "leave it out"
            keys.append(l.isExtra ? l.ing.key : l.effectiveKey)
        }
        return VeganRules.recipeIsVegan(keys: keys, tags: recipe.tags, catalog: store.catalog)
    }

    private var cfg: RecipeConfig { user.config(for: recipe, catalog: store.catalog) }
    private var result: RecipeNutrition { NutritionCalculator(catalog: store.catalog).compute(recipe, cfg) }

    var body: some View {
        let res = result
        let goalRes = user.goalResolution(recipe, catalog: store.catalog)
        ScrollView {
            VStack(spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if hasVegChoice { vegToggle }
                    versionSection(goalRes).id("versionCard")
                    if let up = user.upgradeCard(recipe, catalog: store.catalog) { UpgradeCard(card: up) { user.setUpgrade(recipe.id, $0) }.id("upgrade") }
                    macroSection(res).id("macros")
                    if let ev = recipe.evidence { EvidenceCard(evidence: ev) }
                    controls(res)
                    ingredientSection("Base", lines: res.lines.filter { $0.isBase }).id("ingredients")
                    if !recipe.mixIns.isEmpty || res.lines.contains(where: { $0.isExtra || $0.isBoost }) { ingredientSection("Mix-ins", lines: res.lines.filter { !$0.isBase }) }
                    boostCard(res).id("boost")
                    instructions
                    if let tip = recipe.proTip(vegMode: user.data.isVegetarian) { proTip(tip) }
                    links
                    madeLog
                }
                .scrollTargetLayout()
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
        }
        #if DEBUG
        .scrollPosition($ssScroll)
        .task {
            guard let a = router.ssAnchor else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            ssScroll.scrollTo(id: a, anchor: .top)
        }
        #endif
        .coordinateSpace(name: "detailScroll")
        .ignoresSafeArea(edges: .top)
        .background(Color.screenBackground)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SaveMenu(recipe: recipe) }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showCompare) { CompareSheet(recipe: recipe).environment(store).environment(user) }
        .sheet(isPresented: Binding(get: { swapLine != nil }, set: { if !$0 { swapLine = nil } })) {
            if let lk = swapLine { SwapSheet(recipe: recipe, lineKey: lk).environment(store).environment(user) }
        }
        .sheet(isPresented: $showAddMilk) {
            NavigationStack {
                NutritionLookupView(purpose: .customMilk) { liquid in
                    if let liquid { user.data.recipeMilk[recipe.id] = liquid.id }
                }
            }
            .environment(store).environment(user)
        }
        .sheet(isPresented: $showAddPowder) {
            NavigationStack {
                NutritionLookupView(purpose: .customPowder, onSaved: { _ in }, onSavedPowder: { p in
                    user.data.recipePowder[recipe.id] = p.id
                })
            }
            .environment(store).environment(user)
        }
        .sheet(isPresented: $showLog) { MadeLogSheet(recipe: recipe).environment(user) }
    }

    // MARK: sections

    /// Fixed-height hero (about 320 pt plus the status bar). The photo is aspect-filled and clipped to it; only the title
    /// sits on the image (over a dark scrim). Everything else lives below, on the normal background.
    private var hero: some View {
        Color.clear
            .frame(height: 340)
            .overlay { RecipePhoto(recipe: recipe, maxPixel: 1400).allowsHitTesting(false) }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                    Text(shown.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal).padding(.bottom, 14)
                }
                .frame(height: 180)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shown.name != recipe.name {
                Text((user.upgradeChoice(recipe.id) != nil && recipe.proteinUpgrade != nil ? "Protein upgrade of: " : "Veg version of: ") + recipe.name).font(.caption).foregroundStyle(.secondary)
            }
            sourceLine
            if recipe.photo == nil, let u = recipe.photoURL, !photoCreditHidden {
                Text("Photo: \(recipe.source.site ?? URL(string: u)?.host ?? "source site")").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Your rating").font(.subheadline).foregroundStyle(.secondary)
                StarRating(rating: Binding(get: { user.rating(recipe.id) }, set: { user.setRating(recipe.id, $0) }))
                if let g = user.savedGoal(recipe.id) { SavedBadge(goal: g, size: 18) }
            }
            if recipe.section != "creami", recipe.course != nil || recipe.bookCategory != nil {
                Text([recipe.course?.capitalized, recipe.bookCategory].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if veganNow {
                Label("Vegan", systemImage: "leaf.fill")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.veganGreen, in: Capsule())
            } else if user.data.isVegetarian, recipe.section != "creami" {
                if recipe.vegetarian == true { Text("🌱 Vegetarian").font(.subheadline.weight(.semibold)).foregroundStyle(.green) }
                else if recipe.vegAdaptation != nil { Text(vegOn ? "🌱 Vegetarian version" : "Contains meat or fish as written")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(vegOn ? .green : .orange) }
            }
            if !recipe.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(recipe.tags, id: \.self) { t in
                        Text(t.replacingOccurrences(of: "-", with: " "))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            HStack(spacing: 14) {
                if let p = recipe.prepMinutes { Label("\(p) min prep", systemImage: "clock") }
                if recipe.usesServings {
                    if let c = recipe.cookMinutes { Label("\(c) min \(recipe.method ?? "cook")", systemImage: "oven") }
                    if let h = recipe.chillHours, h > 0 { Label("\(h.formatted()) h chill", systemImage: "snowflake") }
                } else {
                    Label("\(recipe.freezeHours) h freeze", systemImage: "snowflake")
                }
                if recipe.pintSize == "deluxe" { Label("Deluxe pint", systemImage: "cylinder") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "Add protein" for low-protein overnight oats (eligible = flagged by the build and under 20 g protein per serving as written).
    @ViewBuilder private func boostCard(_ res: RecipeNutrition) -> some View {
        let d = user.display(for: recipe, catalog: store.catalog)
        if ProteinBoosts.isEligible(recipe, proteinPerServing: d.displayed.protein / recipe.perServingDivisor) {
            ProteinBoostCard(recipe: recipe,
                             options: ProteinBoosts.options(for: shown, catalog: store.catalog, powder: user.powder(for: recipe.id, catalog: store.catalog)),
                             totalProteinPerServing: res.displayedFull.protein / recipe.perServingDivisor,
                             isOn: { user.boostSelected(recipe.id, $0) },
                             toggle: { user.setBoost(recipe.id, $0, $1) })
        }
    }

    private var originalGoal: Goal {
        let d = user.display(for: recipe, catalog: store.catalog)
        return Goal.original(d.displayed * (1 / recipe.perServingDivisor), bookTitle: recipe.source.title)
    }

    /// "Version: Cut | Maintain | Bulk", the original's class, and the toggleable changes for the chosen version.
    private func versionSection(_ goalRes: GoalResolution) -> some View {
        let ver = user.versionGoal(recipe.id)
        let orig = originalGoal
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Version").font(.subheadline.weight(.semibold))
                Spacer()
                Label("Original: \(orig.title)", systemImage: orig.symbol)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(orig.color.opacity(0.16), in: Capsule())
                    .foregroundStyle(orig.color)
            }
            Picker("Version", selection: Binding(get: { ver }, set: { user.setVersion(recipe.id, $0) })) {
                ForEach(Goal.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: ver)
            if ver != .maintain { changesCard(goalRes) }
        }
        .animation(.snappy, value: ver)
    }

    private func changesCard(_ goalRes: GoalResolution) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Changes for \(goalRes.goal.title)", systemImage: goalRes.goal.symbol)
                .font(.subheadline.weight(.semibold)).foregroundStyle(goalRes.goal.color)
            if goalRes.changes.isEmpty {
                Text(goalRes.goal == .cut ? "Nothing to trim: this recipe already fits a cut." : "Nothing to add: this recipe already fits a bulk.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(goalRes.changes) { c in
                Toggle(isOn: Binding(get: { c.enabled }, set: { user.setChange(recipe.id, c.id, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(.footnote.weight(.medium))
                        if let d = c.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .toggleStyle(.switch).tint(goalRes.goal.color)
            }
        }
        .padding(12)
        .background(goalRes.goal.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var vegToggle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Version", selection: Binding(
                get: { vegOn },
                set: { on in
                    if on { user.data.showOriginal.remove(recipe.id) } else { user.data.showOriginal.insert(recipe.id) }
                })) {
                Text("🌱 Vegetarian version").tag(true)
                Text("Original").tag(false)
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: vegOn)
            if vegOn, let s = recipe.vegAdaptation?.summary, !s.isEmpty {
                Label(s, systemImage: "leaf.fill").font(.subheadline).foregroundStyle(.green)
            }
        }
        .padding()
        .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var sourceLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourceMain
            if let also = recipe.source.alsoIn, !also.isEmpty {
                Text("Also in: \(also)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var sourceMain: some View {
        if recipe.source.isBook {
            Label("\(recipe.source.title ?? "Creami Cravings")" + (recipe.source.page.map { " · page \($0)" } ?? ""), systemImage: "book.closed")
                .font(.subheadline).foregroundStyle(.secondary)
        } else if let site = recipe.source.site {
            if let u = recipe.source.url.flatMap(URL.init(string:)) {
                Link(destination: u) { Label(site, systemImage: "link") }.font(.subheadline)
            } else {
                Label(site, systemImage: "link").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func macroSection(_ res: RecipeNutrition) -> some View {
        let div = recipe.usesServings ? recipe.perServingDivisor : Double(servings)
        // the goal portion applies per serving (and per pint for Creami); the whole-recipe view shows the full recipe
        let whole = recipe.usesServings ? res.displayedFull : res.displayed
        let shown = perServing ? (recipe.usesServings ? res.displayed * (Double(servings) / div) : res.displayed * (1 / div)) : whole
        return VStack(alignment: .leading, spacing: 10) {
            MacroRow(n: shown)
                .animation(.snappy, value: shown)
            if shown.calories > 0 {
                Label("\(String(format: "%.1f", shown.proteinPer100kcal)) g protein / 100 kcal", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: shown.proteinPer100kcal))
            }
            Picker("Calories from", selection: Binding(
                get: { res.usedSource },
                set: { user.data.recipeCalorieSource[recipe.id] = $0 })) {
                ForEach(CalorieSource.allCases) { Text($0 == .book ? (recipe.source.isBook ? "Book" : "Source") : $0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .sensoryFeedback(.selection, trigger: res.usedSource)

            HStack(alignment: .firstTextBaseline) {
                Group {
                    if res.estimated {
                        Label("Estimated from ingredients (this recipe has no printed macros)", systemImage: "function")
                    } else if vegOn && res.usedSource == .book && recipe.vegAdaptation?.macrosPerServing != nil {
                        Label("Vegetarian version (estimated)", systemImage: "leaf.fill").foregroundStyle(.green)
                    } else if res.usedSource == .book {
                        Label("\(recipe.source.isBook ? "Book" : "Source") numbers " + (recipe.usesServings ? (perServing ? "per serving" : "for the whole recipe")
                                                                                       : (res.pints > 1 ? "× \(res.pints) pints" : "for the whole pint")), systemImage: "book.closed")
                    } else {
                        Label("Calculated from the ingredient database", systemImage: "function")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Compare") { showCompare = true }.font(.caption.weight(.semibold))
            }
            if res.estimatedCount > 0 || res.uncounted > 0 || user.data.useEstimates == false {
                VStack(alignment: .leading, spacing: 4) {
                    if res.estimatedCount > 0 {
                        Label("Includes \(res.estimatedCount) estimated amount\(res.estimatedCount == 1 ? "" : "s")", systemImage: "wand.and.stars")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if res.uncounted > 0 {
                        Label("\(res.uncounted) ingredient\(res.uncounted == 1 ? "" : "s") not counted", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle(isOn: Binding(get: { user.data.useEstimates }, set: { user.data.useEstimates = $0 })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Use estimates").font(.caption.weight(.semibold))
                            Text("Guesses typical amounts for lines with none. Affects Calculated numbers and Cut / Bulk changes, not the book or source numbers.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch).tint(.orange)
                }
            }
            Picker("View", selection: $perServing.animation(.snappy)) {
                Text(recipe.usesServings ? "Whole recipe" : "Whole pint").tag(false)
                Text("Per \(recipe.servingNoun)").tag(true)
            }
            .pickerStyle(.segmented)
            if perServing {
                if recipe.usesServings {
                    Stepper("\(servings) \(recipe.servingNoun)\(servings == 1 ? "" : "s") of \(recipe.servings ?? 1)", value: $servings, in: 1...max(1, recipe.servings ?? 1))
                        .font(.subheadline)
                } else {
                Stepper("\(servings) serving\(servings == 1 ? "" : "s") per pint", value: $servings, in: 1...4)
                    .font(.subheadline)
                }
            }
        }
        .padding()
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func controls(_ res: RecipeNutrition) -> some View {
        VStack(spacing: 0) {
            if store.catalog.liquidLineKey(recipe) != nil {
            HStack {
                Label("Your milk", systemImage: "cup.and.saucer")
                Spacer()
                Menu {
                    Button {
                        user.data.recipeMilk[recipe.id] = nil
                    } label: {
                        Label("Default (\(defaultMilkName))", systemImage: user.data.recipeMilk[recipe.id] == nil ? "checkmark" : "arrow.uturn.backward")
                    }
                    ForEach(milkGroups, id: \.family) { g in
                        Section(BaseLiquid.familyTitle(g.family)) {
                            ForEach(g.items) { l in
                                Button {
                                    user.data.recipeMilk[recipe.id] = l.id
                                } label: {
                                    if cfg.milk?.id == l.id { Label("\(l.name) · \(Int(l.perServing.calories)) kcal", systemImage: "checkmark") }
                                    else { Text("\(l.name) · \(Int(l.perServing.calories)) kcal") }
                                }
                            }
                        }
                    }
                    Divider()
                    Button { showAddMilk = true } label: { Label("Add my milk…", systemImage: "plus") }
                } label: {
                    HStack(spacing: 4) {
                        Text(cfg.milk?.name ?? "Recipe's own").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 10)
            Divider()
            }
            if store.catalog.powderLineKey(recipe) != nil {
                powderRow
                Divider()
            }
            if !recipe.usesServings {
            Stepper(value: Binding(get: { cfg.pints }, set: { user.data.pints[recipe.id] = $0 == 1 ? nil : $0 }), in: 1...5) {
                Label("Pints: \(cfg.pints)", systemImage: "cylinder.split.1x2")
                    .contentTransition(.numericText(value: Double(cfg.pints)))
            }
            .padding(.vertical, 6)
            }
        }
        .padding(.horizontal)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.snappy, value: cfg.pints)
    }

    private var powderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Your protein powder", systemImage: "scalemass")
                Spacer()
                Menu {
                    Button {
                        user.data.recipePowder[recipe.id] = nil
                    } label: {
                        Label("Default (\(defaultPowderName))", systemImage: user.data.recipePowder[recipe.id] == nil ? "checkmark" : "arrow.uturn.backward")
                    }
                    ForEach(powderGroups, id: \.type) { g in
                        Section(ProteinPowder.typeTitle(g.type)) {
                            ForEach(g.items) { p in
                                Button {
                                    user.data.recipePowder[recipe.id] = p.id
                                } label: {
                                    if cfg.powder?.id == p.id { Label("\(p.name) · \(Int(p.perScoop.calories)) kcal", systemImage: "checkmark") }
                                    else { Text("\(p.name) · \(Int(p.perScoop.calories)) kcal") }
                                }
                            }
                        }
                    }
                    Divider()
                    Button { showAddPowder = true } label: { Label("Add my powder…", systemImage: "plus") }
                } label: {
                    HStack(spacing: 4) {
                        Text(cfg.powder?.name ?? "Recipe's own").lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            if let n = cfg.powder?.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary) }
            if let b = store.catalog.sourceBrands[recipe.id] {
                Text("Source used: \(b)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var defaultPowderName: String {
        user.data.defaultPowderId.flatMap { id in (user.data.customPowders + store.catalog.powders).first { $0.id == id }?.name } ?? "recipe's own"
    }

    private var powderGroups: [(type: String, items: [ProteinPowder])] {
        let all = user.allPowders(store.catalog)
        let groups = Dictionary(grouping: all, by: { $0.type })
        let order = ProteinPowder.typeOrder
        return (order + groups.keys.filter { !order.contains($0) }.sorted()).compactMap { t in groups[t].map { (t, $0) } }
    }

    private var defaultMilkName: String {
        user.data.defaultMilkId.flatMap { id in (user.data.customLiquids + store.catalog.liquids).first { $0.id == id }?.name } ?? "recipe's own"
    }

    private var milkGroups: [(family: String, items: [BaseLiquid])] {
        let all = user.allLiquids(store.catalog)
        let order = ["custom", "ultra_filtered", "milk", "plant", "protein_shake"]
        let groups = Dictionary(grouping: all, by: { $0.family })
        return (order + groups.keys.filter { !order.contains($0) }.sorted()).compactMap { f in groups[f].map { (f, $0) } }
    }

    private func ingredientSection(_ title: String, lines: [LineResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.lineKey) { i, l in
                    IngredientRow(recipe: recipe, line: l,
                                  vegSwap: vegOn ? recipe.vegAdaptation?.swaps.first { $0.replaces == recipe.allLines.first { $0.key == l.lineKey }?.ing.text } : nil,
                                  vegAlt: vegOn ? vegRes.lines[l.lineKey] : nil,
                                  onPickAlt: { key in
                                      var m = user.data.vegChoice[recipe.id] ?? [:]
                                      m[l.lineKey] = key
                                      user.data.vegChoice[recipe.id] = m
                                  }) { swapLine = l.lineKey }
                    if i < lines.count - 1 { Divider().padding(.leading) }
                }
            }
            .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Instructions").font(.title3.bold())
            ForEach(Array(shown.instructions.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.subheadline.bold()).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(Color.accentColor, in: Circle())
                    Text(step).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func proTip(_ tip: ProTip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(tip.title, systemImage: "lightbulb.fill").font(.headline).foregroundStyle(.orange)
            Text(tip.text).font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var links: some View {
        HStack {
            if let v = recipe.videoURL.flatMap(URL.init(string:)) {
                Button { openURL(v) } label: { Label("Watch video", systemImage: "play.rectangle.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            if let u = recipe.source.url.flatMap(URL.init(string:)) {
                Button { openURL(u) } label: { Label("Open source", systemImage: "safari").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private var madeLog: some View {
        let entries = user.data.madeLog.filter { $0.recipeId == recipe.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Made it").font(.title3.bold())
                Spacer()
                Button { showLog = true } label: { Label("Log", systemImage: "plus.circle.fill") }
            }
            if entries.isEmpty {
                Text("Nothing logged yet. After you spin it, log a rating and notes to find your best pints later.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline.weight(.medium))
                            Spacer()
                            if e.rating > 0 {
                                HStack(spacing: 2) { ForEach(0..<e.rating, id: \.self) { _ in Image(systemName: "star.fill") } }
                                    .font(.caption).foregroundStyle(.yellow)
                            }
                        }
                        if !e.note.isEmpty { Text(e.note).font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contextMenu {
                        Button("Delete", role: .destructive) { user.data.madeLog.removeAll { $0.id == e.id } }
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { router.cook = CookRequest(recipeId: recipe.id) } label: {
                Label("Cook", systemImage: "flame.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let timerText = recipe.timerLabel {
            Button {
                Notifier.startTimer(for: recipe, user: user); timerStarted.toggle()
            } label: { Label(timerText, systemImage: "timer") }
            .buttonStyle(.bordered)
            .fixedSize()
            .sensoryFeedback(.success, trigger: timerStarted)
            }
            Button {
                ShoppingList.merge(ShoppingList.items(for: recipe, cfg: cfg, catalog: store.catalog), into: &user.data.shopping)
                addedToList.toggle()
            } label: { Label("List", systemImage: "cart.badge.plus") }
            .buttonStyle(.bordered)
            .fixedSize()
            .sensoryFeedback(.success, trigger: addedToList)
        }
        .controlSize(.large)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }
}

struct EvidenceCard: View {
    let evidence: Evidence
    private var style: (String, String, Color) {
        switch evidence.verdict {
        case "proven": return ("Proven", "checkmark.seal.fill", .green)
        case "promising": return ("Promising", "questionmark.circle.fill", .yellow)
        default: return ("Unverified", "circle.dashed", .gray)
        }
    }
    var body: some View {
        let s = style
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(s.0, systemImage: s.1).font(.headline).foregroundStyle(s.2)
                Spacer()
                if let r = evidence.rating {
                    Label(String(format: "%.1f", r) + (evidence.ratingCount.map { " (\($0.formatted()))" } ?? ""), systemImage: "star.fill")
                        .font(.subheadline).foregroundStyle(.yellow)
                }
            }
            if let t = evidence.summary, !t.isEmpty { Text(t).font(.subheadline) }
            if !evidence.commonFixes.isEmpty {
                Text("Common fixes").font(.footnote.weight(.semibold)).padding(.top, 2)
                ForEach(evidence.commonFixes, id: \.self) { f in
                    HStack(alignment: .top, spacing: 6) { Text("•"); Text(f).fixedSize(horizontal: false, vertical: true) }.font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(s.2.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct MadeLogSheet: View {
    let recipe: Recipe
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss
    @State private var rating = 0
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("How was it?") { StarRating(rating: $rating) }
                Section("Notes") { TextField("What would you change?", text: $note, axis: .vertical).lineLimit(3...8) }
            }
            .navigationTitle("Log \(recipe.name)")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { user.logMade(recipeId: recipe.id, rating: rating, note: note); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

