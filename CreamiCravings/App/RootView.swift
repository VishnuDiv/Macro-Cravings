import SwiftUI

struct RootView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        Group {
            if store.isLoaded {
                TabView(selection: $router.tab) {
                    Tab("Recipes", systemImage: "fork.knife", value: AppTab.recipes) {
                        RecipesView(mode: .all)
                    }
                    Tab("Favorites", systemImage: "star.fill", value: AppTab.favorites) {
                        RecipesView(mode: .favorites)
                    }
                    Tab("Freezer", systemImage: "snowflake", value: AppTab.freezer) {
                        FreezerView()
                    }
                    .badge(readyCount)
                    Tab("Shopping", systemImage: "cart.fill", value: AppTab.shopping) {
                        ShoppingView()
                    }
                    .badge(user.data.shopping.filter { !$0.checked }.count)
                    Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                        SettingsView()
                    }
                }
                .cookCover(item: $router.cook) { req in
                    CookModeView(request: req)
                        .environment(store).environment(user).environment(router)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "snowflake").font(.system(size: 54)).foregroundStyle(Color.accentColor)
                    ProgressView()
                    Text("Loading recipes…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.default, value: store.isLoaded)
    }

    private var readyCount: Int { user.data.freezer.filter { $0.isReady() }.count }
}
