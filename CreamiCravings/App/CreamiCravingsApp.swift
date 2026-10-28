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
    @State private var lock = HealthLock()
    #if DEBUG
    @State private var progress = ScreenshotMode.isActive ? ProgressLibrary(root: ScreenshotMode.sampleRoot) : ProgressLibrary()   // screenshots only see generated samples
    #else
    @State private var progress = ProgressLibrary()
    #endif
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(user)
                .environment(router)
                .environment(lock)
                .environment(progress)
                .task {
                    await store.loadAsync()
                    #if DEBUG
                    if ScreenshotMode.isActive { ScreenshotMode.apply(store: store, user: user, router: router, lib: progress); return }
                    #endif
                    progress.store.applyBackupFlag(!user.data.progressInBackup)
                    await progress.rearmReminders(user)
                    Spotlight.index(store.recipes)
                    await user.warmCache(store.recipes, catalog: store.catalog)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        router.open(recipe: id)
                    }
                }
                .onChange(of: phase) { _, p in
                    if p != .active { user.flush(); lock.appLeft() } else { lock.appReturned() }
                }
                .onChange(of: user.data.appMode, initial: true) { _, m in
                    if m == .health && user.data.healthLockEnabled { Task { await lock.unlock() } }
                }
        }
    }
}
