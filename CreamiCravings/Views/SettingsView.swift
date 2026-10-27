import SwiftUI

struct SettingsView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var showAddMilk = false
    @State private var showAddPowder = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { GuidesView() } label: { Label("Guides and paneer calculator", systemImage: "book.pages") }
                }
                Section {
                    Picker("My goal", selection: Binding(get: { user.data.goal }, set: { user.data.goal = $0 })) {
                        ForEach(Goal.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("Goal") } footer: {
                    Text("Cut sorts by protein per 100 kcal and badges cut-friendly recipes. Bulk sorts by protein and badges bulk-friendly ones. Maintain changes nothing. A goal never hides recipes.")
                }
                Section {
                    Toggle("I'm vegetarian", isOn: Binding(get: { user.data.isVegetarian }, set: { user.data.isVegetarian = $0 }))
                    Toggle("Prefer easy-to-find alternatives", isOn: Binding(get: { user.data.preferEasyAlternatives }, set: { user.data.preferEasyAlternatives = $0 }))
                    Toggle("I avoid eggs", isOn: Binding(get: { user.data.avoidsEggs }, set: {
                        user.data.avoidsEggs = $0
                        if $0 { user.data.filterState.noEgg = true }
                    }))
                } header: { Text("Diet") } footer: {
                    Text("Vegetarian mode shows the vegetarian version of meat recipes by default, and flags non-vegetarian ingredients. Avoiding eggs turns on the No egg filter.")
                }
                Section {
                    Picker("My default milk", selection: Binding<String?>(
                        get: { user.data.defaultMilkId }, set: { user.data.defaultMilkId = $0 })) {
                        Text("Recipe's own").tag(String?.none)
                        ForEach(user.allLiquids(store.catalog)) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    Picker("My Greek yogurt", selection: Binding(get: { user.data.greekYogurt }, set: { user.data.greekYogurt = $0 })) {
                        ForEach(GreekYogurtPref.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("My protein powder", selection: Binding<String?>(
                        get: { user.data.defaultPowderId }, set: { user.data.defaultPowderId = $0 })) {
                        Text("Recipe's own").tag(String?.none)
                        ForEach(user.allPowders(store.catalog)) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    Picker("Calories from", selection: Binding(get: { user.data.defaultCalorieSource }, set: { user.data.defaultCalorieSource = $0 })) {
                        ForEach(CalorieSource.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("Defaults") } footer: {
                    Text("Book uses the printed macros and adjusts them for your milk and swaps. Calculated adds up the ingredient database.")
                }

                Section("Pantry") {
                    NavigationLink {
                        PantryView()
                    } label: {
                        LabeledContent("What I have", value: store.catalog.ingredients.isEmpty ? "" : "\(user.data.pantryMissing.count) missing")
                    }
                }

                Section("Nutrition overrides") {
                    if user.data.nutritionOverrides.isEmpty {
                        Text("None yet. Open any ingredient's swap sheet to use a scanned or typed-in product.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(user.data.nutritionOverrides.keys.sorted(), id: \.self) { k in
                        if let o = user.data.nutritionOverrides[k] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.catalog.info(k)?.name ?? k).font(.subheadline.weight(.medium))
                                Text("\(o.productName) · \(o.sourceLabel) · \(Int(o.per100g.calories)) kcal/100 g").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        let keys = user.data.nutritionOverrides.keys.sorted()
                        for i in idx { user.data.nutritionOverrides[keys[i]] = nil }
                    }
                }

                Section("My milks") {
                    ForEach(user.data.customLiquids) { l in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(l.name)
                            Text("\(Int(l.perServing.calories)) kcal · \(Int(l.perServing.protein)) g protein per \(Int(l.servingMl)) ml")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { user.data.customLiquids[$0].id }
                        user.data.customLiquids.remove(atOffsets: idx)
                        if let d = user.data.defaultMilkId, ids.contains(d) { user.data.defaultMilkId = nil }
                        user.data.recipeMilk = user.data.recipeMilk.filter { !ids.contains($0.value) }
                    }
                    Button { showAddMilk = true } label: { Label("Add my milk…", systemImage: "plus.circle") }
                }

                Section("My powders") {
                    ForEach(user.data.customPowders) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text("\(Int(p.perScoop.calories)) kcal · \(Int(p.perScoop.protein)) g protein per \(Int(p.scoopGrams)) g scoop")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { idx in
                        let ids = idx.map { user.data.customPowders[$0].id }
                        user.data.customPowders.remove(atOffsets: idx)
                        if let d = user.data.defaultPowderId, ids.contains(d) { user.data.defaultPowderId = nil }
                        user.data.recipePowder = user.data.recipePowder.filter { !ids.contains($0.value) }
                    }
                    Button { showAddPowder = true } label: { Label("Add my powder…", systemImage: "plus.circle") }
                }

                Section {
                    Button("Reset filters & sort", role: .destructive) { user.data.filterState = FilterState() }
                        .disabled(user.data.filterState == FilterState())
                } footer: { Text("Clears every filter and chip and puts the sort back to Featured.") }

                Section("About") {
                    LabeledContent("Book", value: "Creami Cravings")
                    LabeledContent("Author", value: "Eli @FitnessProductFinder")
                    LabeledContent("Book recipes", value: "\(store.recipes.filter { $0.source.isBook }.count)")
                    LabeledContent("Web recipes", value: "\(store.recipes.filter { !$0.source.isBook }.count) from \(store.webSiteCount) sites")
                    Text("Nutrition lookups use Open Food Facts. Everything else stays on your phone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAddPowder) {
                NavigationStack { NutritionLookupView(purpose: .customPowder, onSaved: { _ in }) }
                    .environment(store).environment(user)
            }
            .sheet(isPresented: $showAddMilk) {
                NavigationStack { NutritionLookupView(purpose: .customMilk) { _ in } }
                    .environment(store).environment(user)
            }
        }
    }
}

struct PantryView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @State private var query = ""

    private var rows: [(key: String, info: IngredientInfo)] {
        let q = FilterEngine.tokens(query)
        return store.catalog.ingredients
            .filter { q.isEmpty || FilterEngine.matches(query: q, haystack: FilterEngine.normalize($0.value.name + " " + $0.key)) }
            .map { (key: $0.key, info: $0.value) }
            .sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if store.catalog.ingredients.isEmpty {
                ContentUnavailableView("Ingredient catalog not available", systemImage: "shippingbox",
                                       description: Text("Pantry tracking needs the bundled ingredient list."))
            } else {
                List {
                    ForEach(IngCategory.order + ["_other"], id: \.self) { cat in
                        let items = rows.filter { cat == "_other" ? !IngCategory.order.contains($0.info.category) : $0.info.category == cat }
                        if !items.isEmpty {
                            Section(IngCategory.title(cat == "_other" ? "other" : cat)) {
                                ForEach(items, id: \.key) { row in
                                    Toggle(isOn: Binding(get: { !user.data.pantryMissing.contains(row.key) },
                                                         set: { user.setMissing(row.key, !$0) })) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(row.info.name)
                                            if row.info.pantryStaple { Text("Pantry staple").font(.caption2).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $query, prompt: "Search ingredients")
            }
        }
        .navigationTitle("Pantry")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Mark all staples as have") {
                        for (k, i) in store.catalog.ingredients where i.pantryStaple { user.data.pantryMissing.remove(k) }
                    }
                    Button("I have everything") { user.data.pantryMissing = [] }
                    Button("I have nothing", role: .destructive) { user.data.pantryMissing = Set(store.catalog.ingredients.keys) }
                } label: { Label("Bulk", systemImage: "ellipsis.circle") }
            }
        }
    }
}
