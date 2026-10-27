import SwiftUI

struct FilterSheet: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    private var f: Binding<FilterState> {
        Binding(get: { user.data.filterState }, set: { user.data.filterState = $0 })
    }

    private func flip(_ keyPath: WritableKeyPath<FilterState, Set<String>>, _ v: String) {
        if user.data.filterState[keyPath: keyPath].contains(v) { user.data.filterState[keyPath: keyPath].remove(v) }
        else { user.data.filterState[keyPath: keyPath].insert(v) }
    }

    private func chips(_ items: [(String, String)], _ kp: WritableKeyPath<FilterState, Set<String>>) -> some View {
        FlowLayout {
            ForEach(items, id: \.0) { id, title in
                ChipToggle(title: title, isOn: user.data.filterState[keyPath: kp].contains(id)) { flip(kp, id) }
            }
        }
        .padding(.vertical, 4)
    }

    private var bookTitles: [String] { store.bookTitles }

    private var shakeFlavors: [String] {
        Set(store.index.values.compactMap { $0.shakeFlavor }).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    chips([("book", "Book"), ("web", "Web")], \.sources)
                }
                if user.data.filterState.section == "dessert" {
                    Section("Dessert type") {
                        chips(Recipe.dessertTypes.map { ($0, $0.capitalized) }, \.dessertTypes)
                    }
                    Section("Verdict") {
                        chips(Recipe.verdicts.map { ($0, $0.capitalized) }, \.verdicts)
                    }
                }
                if user.data.filterState.section == "meal" {
                    Section("Course") {
                        chips(Recipe.courses.map { ($0, $0.capitalized) }, \.courses)
                    }
                    Section("Cuisine and style") {
                        chips(Recipe.mealChips.map { ($0.id, $0.title) }, \.mealChips)
                    }
                    if !bookTitles.isEmpty {
                        Section("Book") { chips(bookTitles.map { ($0, $0) }, \.books) }
                    }
                }
                Section("Vegetarian and eggs") {
                    Toggle("Vegetarian as written", isOn: f.vegAsWritten)
                    Toggle("Has a vegetarian version", isOn: f.hasVegVersion)
                    Toggle("No egg", isOn: f.noEgg)
                    Toggle("High fiber (8 g+ per serving)", isOn: f.highFiber)
                    if user.data.avoidsEggs { Text("\"I avoid eggs\" in Settings turns this on.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Tags") {
                    chips(Recipe.vocabulary.map { ($0, $0.replacingOccurrences(of: "-", with: " ").capitalized) }, \.tags)
                }
                Section("Affiliate products") {
                    Toggle("Hide recipes with affiliate products", isOn: f.hideAffiliate)
                    if !store.affiliateBrands.isEmpty {
                        Text("Or exclude specific brands").font(.caption).foregroundStyle(.secondary)
                        chips(store.affiliateBrands.map { ($0, $0) }, \.excludedBrands)
                    }
                }
                Section("Base liquid") {
                    chips(BaseKind.allCases.filter { $0 != .other }.map { ($0.rawValue, $0.title) }, \.baseKinds)
                    if !shakeFlavors.isEmpty {
                        Text("Protein shake flavor").font(.caption).foregroundStyle(.secondary)
                        chips(shakeFlavors.map { ($0, $0.capitalized) }, \.shakeFlavors)
                    }
                }
                Section("Ingredients") {
                    NavigationLink {
                        IngredientPickerView(title: "Contains", selection: Binding(
                            get: { user.data.filterState.containsKeys }, set: { user.data.filterState.containsKeys = $0 }))
                    } label: {
                        LabeledContent("Contains", value: summary(user.data.filterState.containsKeys))
                    }
                    NavigationLink {
                        IngredientPickerView(title: "Excludes", selection: Binding(
                            get: { user.data.filterState.excludesKeys }, set: { user.data.filterState.excludesKeys = $0 }))
                    } label: {
                        LabeledContent("Excludes", value: summary(user.data.filterState.excludesKeys))
                    }
                }
                Section("Allergens to avoid") {
                    chips([("dairy", "Dairy"), ("egg", "Egg"), ("gluten", "Gluten"), ("peanut", "Peanut"),
                           ("tree_nut", "Tree nut"), ("soy", "Soy"), ("coconut", "Coconut")], \.allergens)
                    if store.catalog.ingredients.isEmpty {
                        Text("Allergen data comes from the ingredient catalog.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Nutrition (whole recipe; per serving for desserts)") {
                    VStack(alignment: .leading) {
                        Text(user.data.filterState.maxCalories >= FilterState.maxCaloriesCeiling
                             ? "Max calories: any" : "Max calories: \(Int(user.data.filterState.maxCalories))")
                        Slider(value: f.maxCalories, in: 100...FilterState.maxCaloriesCeiling, step: 25)
                    }
                    VStack(alignment: .leading) {
                        Text(user.data.filterState.minProtein <= 0 ? "Min protein: any" : "Min protein: \(Int(user.data.filterState.minProtein)) g")
                        Slider(value: f.minProtein, in: 0...60, step: 1)
                    }
                }
                Section("Pantry") {
                    Toggle("Can make now", isOn: f.canMakeNow)
                    Toggle("Can make with swaps", isOn: f.canMakeWithSwaps)
                }
                Section("More") {
                    Toggle("Favorites only", isOn: f.favoritesOnly)
                    Toggle("Has video", isOn: f.hasVideo)
                    Toggle("Made before", isOn: f.madeBefore)
                }
                Section {
                    Button("Reset all filters", role: .destructive) {
                        var n = FilterState(); n.sort = user.data.filterState.sort; n.section = user.data.filterState.section
                        user.data.filterState = n
                    }
                    .disabled(user.data.filterState.activeCount == 0)
                }
            }
            .navigationTitle("Filters")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func summary(_ keys: Set<String>) -> String {
        keys.isEmpty ? "Any" : "\(keys.count) selected"
    }
}

struct IngredientPickerView: View {
    let title: String
    @Binding var selection: Set<String>
    @Environment(RecipeStore.self) private var store
    @State private var query = ""

    private var rows: [(key: String, name: String)] {
        var keys = Set<String>()
        for idx in store.index.values { keys.formUnion(idx.keys) }
        let all = keys.map { (key: $0, name: store.catalog.info($0)?.name ?? $0.replacingOccurrences(of: "_", with: " ").capitalized) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let q = FilterEngine.tokens(query)
        return q.isEmpty ? all : all.filter { FilterEngine.matches(query: q, haystack: FilterEngine.normalize($0.name)) }
    }

    var body: some View {
        List(rows, id: \.key) { row in
            Button {
                if selection.contains(row.key) { selection.remove(row.key) } else { selection.insert(row.key) }
            } label: {
                HStack {
                    Text(row.name).foregroundStyle(.primary)
                    Spacer()
                    if selection.contains(row.key) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
        }
        .searchable(text: $query, prompt: "Search ingredients")
        .navigationTitle(title)
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Clear") { selection = [] }.disabled(selection.isEmpty) }
        }
    }
}
