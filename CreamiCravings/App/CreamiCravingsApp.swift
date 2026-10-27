import SwiftUI
import CoreSpotlight

@main
struct CreamiCravingsApp: App {
    @State private var store = RecipeStore()
    #if DEBUG
    @State private var user = ScreenshotMode.isActive ? UserStore(fileURL: nil) : UserStore()      // screenshots never touch saved data
    #else
    @State private var user = UserStore()
    #endif
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
                    #if DEBUG
                    if ScreenshotMode.isActive { ScreenshotMode.apply(store: store, user: user, router: router); return }
                    #endif
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
