import SwiftUI
import CoreSpotlight

@main
struct CreamiCravingsApp: App {
    @State private var store = RecipeStore()
    @State private var user = UserStore()
    @State private var router = Router()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(user)
                .environment(router)
                .task {
                    await store.loadAsync()
                    Spotlight.index(store.recipes)
                    await user.warmCache(store.recipes, catalog: store.catalog)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        router.open(recipe: id)
                    }
                }
                .onChange(of: phase) { _, p in if p != .active { user.flush() } }
        }
    }
}
