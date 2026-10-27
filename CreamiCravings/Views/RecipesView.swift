import SwiftUI

struct RecipesView: View {
    enum Mode { case all, favorites }
    let mode: Mode

    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var showFilters = false
    @Namespace private var zoom

    private var path: Binding<[String]> {
        Binding(get: { mode == .all ? router.recipesPath : router.favoritesPath },
                set: { if mode == .all { router.recipesPath = $0 } else { router.favoritesPath = $0 } })
    }

    private var filter: Binding<FilterState> {
        Binding(get: { user.data.filterState }, set: { user.data.filterState = $0 })
    }

    /// Meals, desserts and drinks show per-serving numbers; say so once in the header.
    private var perServingHeader: Bool { mode == .favorites || (user.data.filterState.section ?? "creami") != "creami" }

    private var effective: FilterState {
        var f = user.data.filterState
        if mode == .favorites { f.favoritesOnly = true; f.section = nil }
        return f
    }

    private var results: [Recipe] {
        let catalog = store.catalog
        let ctx = FilterContext(favorites: user.data.favorites, missing: user.data.pantryMissing, madeLog: user.data.madeLog,
                                displayed: { r in user.display(for: r, catalog: catalog).displayed * (1 / r.perServingDivisor) })
        return FilterEngine.apply(store: store, recipes: store.recipes, query: query, state: effective, ctx: ctx)
    }

    var body: some View {
        let list = results
        NavigationStack(path: path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if mode == .all {
                        Picker("Section", selection: Binding(get: { user.data.filterState.section ?? "creami" },
                                                              set: { user.data.filterState.section = $0 })) {
                            Text("Creami").tag("creami")
                            Text("Desserts").tag("dessert")
                            Text("Meals").tag("meal")
                            if store.hasDrinks { Text("Drinks").tag("drink") }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .sensoryFeedback(.selection, trigger: user.data.filterState.section)
                    }
                    chipBar
                    if mode == .all && user.data.filterState.section == "meal" { mealChips }
                    HStack {
                        Text("\(list.count) recipe\(list.count == 1 ? "" : "s")" + (perServingHeader ? " · per serving" : ""))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(list.count)))
                        Spacer()
                        Text(effective.sort.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    if list.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
                            ForEach(list) { r in
                                NavigationLink(value: r.id) { RecipeCard(recipe: r) }
                                    .buttonStyle(.plain)
                                    .zoomSource(r.id, in: zoom)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color.screenBackground)
            .navigationTitle(mode == .all ? "Recipes" : "Favorites")
            .largeTitle()
            .searchable(text: $query, prompt: "Search recipes, ingredients, tags")
            .navigationDestination(for: String.self) { id in
                if let r = store.recipeByID[id] {
                    RecipeDetailView(recipe: r).zoomDestination(id, in: zoom)
                } else {
                    ContentUnavailableView("Recipe not found", systemImage: "questionmark.circle")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { GuidesView() } label: { Label("Guides", systemImage: "book.pages") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { if let r = list.randomElement() { path.wrappedValue.append(r.id) } } label: {
                        Label("Surprise me", systemImage: "dice.fill")
                    }
                    .disabled(list.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: filter.sort) {
                            ForEach(SortOption.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                }
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet().environment(store).environment(user)
            }
        }
    }

    // MARK: chips

    private var chipBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showFilters = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Filters")
                        if user.data.filterState.activeCount > 0 {
                            Text("\(user.data.filterState.activeCount)")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.cardBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
                }
                .buttonStyle(.plain)

                if mode == .all {
                    ChipToggle(title: "Favorites", isOn: filter.wrappedValue.favoritesOnly) { filter.wrappedValue.favoritesOnly.toggle() }
                }
                ChipToggle(title: "Book", isOn: filter.wrappedValue.sources.contains("book")) { toggle(&filter.wrappedValue.sources, "book") }
                ChipToggle(title: "Web", isOn: filter.wrappedValue.sources.contains("web")) { toggle(&filter.wrappedValue.sources, "web") }
                ForEach(["healthy", "indulgent", "sorbet", "high-protein"], id: \.self) { t in
                    ChipToggle(title: t.replacingOccurrences(of: "-", with: " ").capitalized, isOn: filter.wrappedValue.tags.contains(t)) {
                        toggle(&filter.wrappedValue.tags, t)
                    }
                }
                ChipToggle(title: "No affiliate products", isOn: filter.wrappedValue.hideAffiliate) { filter.wrappedValue.hideAffiliate.toggle() }
                ChipToggle(title: "Can make now", isOn: filter.wrappedValue.canMakeNow) { filter.wrappedValue.canMakeNow.toggle() }
            }
            .padding(.horizontal)
        }
    }

    /// Two rows under the section control: courses + source books, then cuisine / style chips.
    private var mealChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Recipe.courses, id: \.self) { c in
                        ChipToggle(title: c.capitalized, isOn: filter.wrappedValue.courses.contains(c)) { toggle(&filter.wrappedValue.courses, c) }
                    }
                    if !store.bookTitles.isEmpty {
                        Divider().frame(height: 22)
                        ForEach(store.bookTitles, id: \.self) { t in
                            ChipToggle(title: t.replacingOccurrences(of: "The Ultimate ", with: ""), isOn: filter.wrappedValue.books.contains(t)) {
                                toggle(&filter.wrappedValue.books, t)
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Recipe.mealChips, id: \.id) { c in
                        ChipToggle(title: c.title, isOn: filter.wrappedValue.mealChips.contains(c.id)) { toggle(&filter.wrappedValue.mealChips, c.id) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func toggle(_ set: inout Set<String>, _ v: String) {
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
    }

    @ViewBuilder private var emptyState: some View {
        if mode == .favorites && user.data.favorites.isEmpty && query.isEmpty {
            ContentUnavailableView("No favorites yet", systemImage: "star",
                                   description: Text("Tap the star on any recipe to keep it here."))
                .padding(.top, 40)
        } else if !query.isEmpty {
            ContentUnavailableView.search(text: query).padding(.top, 40)
        } else {
            ContentUnavailableView {
                Label(mode == .all && user.data.filterState.section != "creami" ? "Nothing matches" : "No recipes match", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Your filters are hiding everything.")
            } actions: {
                Button("Reset filters") { var f = FilterState(); f.sort = user.data.filterState.sort; f.section = user.data.filterState.section; user.data.filterState = f }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 40)
        }
    }
}

struct RecipeCard: View {
    let recipe: Recipe
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user

    var body: some View {
        let d = user.display(for: recipe, catalog: store.catalog)
        let shown = d.displayed * (1 / recipe.perServingDivisor)
        let fav = user.isFavorite(recipe.id)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { RecipePhoto(recipe: recipe) }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Button { user.toggleFavorite(recipe.id) } label: {
                        Image(systemName: fav ? "star.fill" : "star")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(fav ? Color.yellow : Color.white)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.success, trigger: fav)
                    .accessibilityLabel(fav ? "Remove from favorites" : "Add to favorites")
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(d.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    SmallPill(text: "\(Int(shown.calories.rounded())) kcal", color: .calorieRed)
                    SmallPill(text: "\(Int(shown.protein.rounded())) g P", color: .proteinGreen)
                    if d.estimated { Text("est.").font(.caption2).foregroundStyle(.secondary) }
                }
                if let badge = vegBadge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.green) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu { RecipeContextMenu(recipe: recipe) }
    }
}

extension RecipeCard {
    /// 🌱 badge for non-Creami recipes while vegetarian mode is on.
    var vegBadge: String? {
        guard user.data.isVegetarian, recipe.section != "creami" else { return nil }
        if recipe.vegetarian == true { return "🌱 Veg" }
        if recipe.vegAdaptation != nil { return "🌱 Veg version" }
        return nil
    }
}

struct RecipeContextMenu: View {
    let recipe: Recipe
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user

    var body: some View {
        Button { user.toggleFavorite(recipe.id) } label: {
            Label(user.isFavorite(recipe.id) ? "Remove star" : "Star", systemImage: user.isFavorite(recipe.id) ? "star.slash" : "star")
        }
        Button {
            let items = ShoppingList.items(for: recipe, cfg: user.config(for: recipe, catalog: store.catalog), catalog: store.catalog)
            ShoppingList.merge(items, into: &user.data.shopping)
        } label: { Label("Add to shopping list", systemImage: "cart.badge.plus") }
        Button { Notifier.startTimer(for: recipe, user: user) } label: { Label("Start freeze timer", systemImage: "timer") }
        Button { user.logMade(recipeId: recipe.id, rating: 0, note: "") } label: { Label("Mark as made", systemImage: "checkmark.circle") }
    }
}
