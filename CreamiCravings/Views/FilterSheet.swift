import SwiftUI

struct FilterSheet: View {
    /// The tab being filtered: "creami", "dessert", "meal", "drink", or nil for Favorites (everything).
    let section: String?
    /// Live number of recipes with the current filters, for the "Show N recipes" button.
    let resultCount: Int

    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    private var f: Binding<FilterState> {
        Binding(get: { user.data.filterState }, set: { user.data.filterState = $0 })
    }
    private var st: FilterState { user.data.filterState }

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

    private func flagChip(_ title: String, _ kp: WritableKeyPath<FilterState, Bool>) -> some View {
        ChipToggle(title: title, isOn: user.data.filterState[keyPath: kp]) { user.data.filterState[keyPath: kp].toggle() }
    }

    private var shakeFlavors: [String] { Set(store.index.values.compactMap { $0.shakeFlavor }).sorted() }
    private var isCreami: Bool { section == "creami" || section == nil }
    private var isMeal: Bool { section == "meal" || section == nil }
    private var isDessert: Bool { section == "dessert" || section == nil }

    var body: some View {
        NavigationStack {
            Form {
                quickSection
                goalSection
                densitySection
                if section == "creami" { creamiTypeSection }
                if isMeal { mealSections }
                if isDessert { dessertSections }
                Section("Vegetarian and eggs") {
                    FlowLayout {
                        flagChip("Vegetarian as written", \.vegAsWritten)
                        flagChip("Has a vegetarian version", \.hasVegVersion)
                        flagChip("No egg", \.noEgg)
                        flagChip("Air fryer", \.airFryer)
                        flagChip("High fiber (8 g+)", \.highFiber)
                    }
                    .padding(.vertical, 4)
                    if user.data.avoidsEggs { Text("\"I avoid eggs\" in Settings turns on No egg.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Good for") { chips(Benefit.allCases.map { ($0.rawValue, $0.title) }, \.goodFor) }
                Section("Tags") {
                    chips(Recipe.vocabulary.map { ($0, $0.replacingOccurrences(of: "-", with: " ").capitalized) }, \.tags)
                }
                if !store.affiliateBrands.isEmpty {
                    Section("Exclude affiliate brands") { chips(store.affiliateBrands.map { ($0, $0) }, \.excludedBrands) }
                }
                if isCreami {
                    Section("Base liquid") {
                        chips(BaseKind.allCases.filter { $0 != .other }.map { ($0.rawValue, $0.title) }, \.baseKinds)
                        if !shakeFlavors.isEmpty {
                            Text("Protein shake flavor").font(.caption).foregroundStyle(.secondary)
                            chips(shakeFlavors.map { ($0, $0.capitalized) }, \.shakeFlavors)
                        }
                    }
                }
                Section("Ingredients") {
                    NavigationLink {
                        IngredientPickerView(title: "Contains", selection: Binding(
                            get: { user.data.filterState.containsKeys }, set: { user.data.filterState.containsKeys = $0 }))
                    } label: { LabeledContent("Contains", value: summary(st.containsKeys)) }
                    NavigationLink {
                        IngredientPickerView(title: "Excludes", selection: Binding(
                            get: { user.data.filterState.excludesKeys }, set: { user.data.filterState.excludesKeys = $0 }))
                    } label: { LabeledContent("Excludes", value: summary(st.excludesKeys)) }
                }
                Section("Allergens to avoid") {
                    chips([("dairy", "Dairy"), ("egg", "Egg"), ("gluten", "Gluten"), ("peanut", "Peanut"),
                           ("tree_nut", "Tree nut"), ("soy", "Soy"), ("coconut", "Coconut")], \.allergens)
                    if store.catalog.ingredients.isEmpty {
                        Text("Allergen data comes from the ingredient catalog.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(section == "creami" ? "Nutrition (per pint)" : "Nutrition (per serving)") {
                    VStack(alignment: .leading) {
                        Text(st.maxCalories >= FilterState.maxCaloriesCeiling ? "Max calories: any" : "Max calories: \(Int(st.maxCalories))")
                        Slider(value: f.maxCalories, in: 100...FilterState.maxCaloriesCeiling, step: 25)
                    }
                    VStack(alignment: .leading) {
                        Text(st.minProtein <= 0 ? "Min protein: any" : "Min protein: \(Int(st.minProtein)) g")
                        Slider(value: f.minProtein, in: 0...60, step: 1)
                    }
                }
                Section("Pantry") {
                    FlowLayout {
                        flagChip("Can make now", \.canMakeNow)
                        flagChip("Can make with swaps", \.canMakeWithSwaps)
                    }
                    .padding(.vertical, 4)
                }
                Section("More") {
                    FlowLayout {
                        flagChip("Has video", \.hasVideo)
                        flagChip("Made before", \.madeBefore)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Filters")
            .inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .presentationDetents([.large])
    }

    // MARK: sections

    private var quickSection: some View {
        Section("Quick") {
            FlowLayout {
                flagChip("Saved", \.favoritesOnly)
                ChipToggle(title: "Book", isOn: st.sources.contains("book")) { flip(\.sources, "book") }
                ChipToggle(title: "Web", isOn: st.sources.contains("web")) { flip(\.sources, "web") }
                ForEach(["healthy", "indulgent", "high-protein"], id: \.self) { t in
                    ChipToggle(title: t.replacingOccurrences(of: "-", with: " ").capitalized, isOn: st.tags.contains(t)) { flip(\.tags, t) }
                }
                flagChip("No affiliate products", \.hideAffiliate)
                flagChip("Can make now", \.canMakeNow)
                flagChip("Vegan", \.vegan)
                flagChip("Has protein upgrade", \.hasUpgrade)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var goalSection: some View {
        Section {
            FlowLayout {
                flagChip("Cut-friendly only", \.cutOnly)
                flagChip("Bulk-friendly only", \.bulkOnly)
            }
            .padding(.vertical, 4)
        } header: { Text("Goal (\(user.data.goal.title))") } footer: {
            Text("Cut-friendly: protein × 10 ≥ calories and at most 550 kcal. Bulk-friendly: 600+ kcal with 35+ g protein, or from the Lean Bulking book.")
        }
    }

    private var densitySection: some View {
        let steps = FilterState.proteinDensitySteps
        let idx = steps.firstIndex(of: st.proteinDensity) ?? 0
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Protein density")
                    Spacer()
                    Text(idx == 0 ? "Off" : "\(FilterSheet.num(steps[idx])) g per 100 kcal").foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: steps[idx]))
                }
                Slider(value: Binding(get: { Double(idx) }, set: { user.data.filterState.proteinDensity = steps[min(steps.count - 1, max(0, Int($0.rounded())))] }),
                       in: 0...Double(steps.count - 1), step: 1)
                if idx > 0 {
                    Text("protein × \(FilterSheet.num(100 / steps[idx])) ≥ calories").font(.caption).foregroundStyle(.secondary)
                }
            }
            .sensoryFeedback(.selection, trigger: idx)
        } footer: { Text("Recipes without printed macros are left out while this is on.") }
    }

    static func num(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d) }

    /// Only the types that have at least one Creami recipe.
    @ViewBuilder private var creamiTypeSection: some View {
        let present = Set(store.recipes.compactMap { $0.section == "creami" ? $0.creamiType : nil })
        let list = Recipe.creamiTypes.filter { present.contains($0.id) }
        if !list.isEmpty { Section("Type") { chips(list.map { ($0.id, $0.title) }, \.creamiTypes) } }
    }

    @ViewBuilder private var mealSections: some View {
        Section("Course") { chips(Recipe.courses.map { ($0, $0.capitalized) }, \.courses) }
        Section("Cuisine & style") { chips(Recipe.mealChips.map { ($0.id, $0.title) }, \.mealChips) }
        if !store.bookTitles.isEmpty {
            Section("Books") { chips(store.bookTitles.map { ($0, $0.replacingOccurrences(of: "The Ultimate ", with: "")) }, \.books) }
        }
    }

    @ViewBuilder private var dessertSections: some View {
        Section("Dessert type") { chips(Recipe.dessertTypes.map { ($0, $0.capitalized) }, \.dessertTypes) }
        Section("Verdict") { chips(Recipe.verdicts.map { ($0, $0.capitalized) }, \.verdicts) }
    }

    /// Sticky bottom bar: Reset and a live "Show N recipes".
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button("Reset") { withAnimation(.snappy) { user.data.filterState.clearFilters() } }
                .buttonStyle(.bordered)
                .disabled(st.activeCount == 0)
            Button { dismiss() } label: {
                Text("Show \(resultCount) recipe\(resultCount == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText(value: Double(resultCount)))
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
        .animation(.snappy, value: resultCount)
    }

    private func summary(_ keys: Set<String>) -> String { keys.isEmpty ? "Any" : "\(keys.count) selected" }
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
