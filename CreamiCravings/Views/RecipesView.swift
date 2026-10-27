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
        if f.sort == .featured { f.sort = user.data.goal.defaultSort }      // the goal decides what "Featured" means
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
                    controlRow
                    pillsRow
                    HStack {
                        Text("\(list.count) recipe\(list.count == 1 ? "" : "s")" + (perServingHeader ? " · per serving" : ""))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(list.count)))
                        Spacer()
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
            }
            .sheet(isPresented: $showFilters) {
                FilterSheet(section: mode == .all ? user.data.filterState.section : nil, resultCount: list.count)
                    .environment(store).environment(user)
            }
        }
    }

    // MARK: controls

    private var activeCount: Int { user.data.filterState.activeCount }

    private func keyName(_ k: String) -> String {
        store.catalog.info(k)?.name ?? k.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Filters (n) · Sort · Goal: the only controls under the section picker.
    private var controlRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showFilters = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Filters")
                        if activeCount > 0 {
                            Text("\(activeCount)")
                                .font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    .controlCapsule(prominent: activeCount > 0)
                }
                .buttonStyle(.plain)

                Menu {
                    Picker("Sort", selection: filter.sort) {
                        ForEach(SortOption.allCases) { opt in
                            Text(opt == .featured && user.data.goal != .maintain ? "Featured · \(user.data.goal.defaultSort.title)" : opt.title).tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text("Sort").lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .controlCapsule()
                }

                Menu {
                    Picker("Goal", selection: Binding(get: { user.data.goal }, set: { user.data.goal = $0 })) {
                        ForEach(Goal.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: user.data.goal.symbol)
                        Text(user.data.goal.title).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .controlCapsule(prominent: user.data.goal != .maintain)
                }
            }
            .padding(.horizontal)
        }
        .sensoryFeedback(.selection, trigger: user.data.goal)
    }

    /// One removable pill per active filter, plus "Clear all".
    @ViewBuilder private var pillsRow: some View {
        let pills = user.data.filterState.activePills(keyName: keyName)
        if !pills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pills) { p in
                        Button {
                            withAnimation(.snappy) { user.data.filterState.remove(pill: p.id) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(p.label).lineLimit(1)
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .font(.footnote.weight(.medium))
                            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter \(p.label)")
                    }
                    Button("Clear all") { withAnimation(.snappy) { user.data.filterState.clearFilters() } }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal)
            }
            .sensoryFeedback(.selection, trigger: pills.count)
        }
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
                Button("Reset filters") { user.data.filterState.clearFilters() }
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
                HStack(spacing: 6) {
                    if let badge = vegBadge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                    if let g = goalBadge(shown) { SmallPill(text: g, color: user.data.goal == .cut ? .carbBlue : .fatOrange) }
                }
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
    /// "Cut" or "Bulk" when the recipe suits the user's goal (per serving; per pint for Creami).
    func goalBadge(_ n: Nutrition) -> String? {
        switch user.data.goal {
        case .cut: return Goal.isCutFriendly(n) ? "Cut" : nil
        case .bulk: return Goal.isBulkFriendly(n, bookTitle: recipe.source.title) ? "Bulk" : nil
        case .maintain: return nil
        }
    }

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

extension View {
    /// The rounded capsule used by the Filters / Sort / Goal controls.
    func controlCapsule(prominent: Bool = false) -> some View {
        self.font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)))
            .foregroundStyle(prominent ? Color.accentColor : Color.primary)
    }
}
