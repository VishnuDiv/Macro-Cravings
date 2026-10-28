import SwiftUI

struct RootView: View {
    @Environment(RecipeStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(Router.self) private var router
    @Environment(ProgressLibrary.self) private var progress

    var body: some View {
        Group {
            #if DEBUG
            if store.isLoaded, ScreenshotMode.guide != nil {
                NavigationStack { PaneerCalculatorView() }
            } else if store.isLoaded {
                tabs
            } else { loading }
            #else
            if store.isLoaded { tabs } else { loading }
            #endif
        }
        .animation(.default, value: store.isLoaded)
    }

    private var tabs: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            if user.data.appMode == .food {
                Tab("Recipes", systemImage: "fork.knife", value: AppTab.recipes) {
                    RecipesView(mode: .all)
                }
                Tab("Plan", systemImage: "calendar", value: AppTab.plan) {
                    PlanView()
                }
                .badge(readyCount)
                Tab("Saved", systemImage: "bookmark.fill", value: AppTab.favorites) {
                    RecipesView(mode: .favorites)
                }
                Tab("Shopping", systemImage: "cart.fill", value: AppTab.shopping) {
                    ShoppingView()
                }
                .badge(user.data.shopping.filter { !$0.checked }.count)
            } else {
                Tab("Today", systemImage: "checklist", value: AppTab.today) {
                    HealthGate { TodayView() }
                }
                Tab("Skin", systemImage: "face.smiling", value: AppTab.skin) {
                    HealthGate { SkinView() }
                }
                Tab("Hair", systemImage: "comb", value: AppTab.hair) {
                    HealthGate { HairView() }
                }
                Tab("Progress", systemImage: "camera.viewfinder", value: AppTab.progress) {
                    HealthGate { ProgressTabView() }
                }
                .badge(dueCount)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .cookCover(item: $router.cook) { req in
            CookModeView(request: req)
                .environment(store).environment(user).environment(router)
        }
        .onChange(of: user.data.appMode) { _, m in
            let foodTabs: Set<AppTab> = [.recipes, .plan, .favorites, .shopping, .settings]
            let healthTabs: Set<AppTab> = [.today, .skin, .hair, .progress, .settings]
            if !(m == .food ? foodTabs : healthTabs).contains(router.tab) { router.tab = (m == .food) ? .recipes : .today }
        }
    }

    /// Photo series due today (badge on the Progress tab).
    private var dueCount: Int { progress.dueSeries(user).count }

    private var loading: some View {
        VStack(spacing: 14) {
            Image(systemName: "snowflake").font(.system(size: 54)).foregroundStyle(Color.accentColor)
            ProgressView()
            Text("Loading recipes…").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var readyCount: Int { user.data.freezer.filter { $0.isReady() }.count }
}
