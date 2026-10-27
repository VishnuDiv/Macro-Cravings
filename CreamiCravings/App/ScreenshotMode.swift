#if DEBUG
import Foundation

/// DEBUG-only: launch arguments that put the app in a fixed state for README screenshots (tools/screenshots.sh).
/// It uses a fresh in-memory UserStore (saved data is never touched), default settings, vegetarian mode on, goal Maintain, and never
/// loads remote photos. This file is not compiled into Release builds.
///
///   -ss recipes  [-ssSection meal] [-ssSearch "text"]
///   -ss recipe   -ssId <id> [-ssVersion cut|maintain|bulk] [-ssUpgrade tofu|paneer|seitan|soy] [-ssAnchor versionCard|macros|ingredients|upgrade|boost]
///   -ss filters  [-ssSection meal]
///   -ss guide    -ssGuide paneer
///   -ss saved | -ss settings
@MainActor
enum ScreenshotMode {
    private static func arg(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }

    static var mode: String? { arg("ss") }
    static var isActive: Bool { mode != nil }
    static var guide: String? { arg("ssGuide") }

    private static let upgradeKeys = ["tofu": "tofu_extra_firm", "paneer": "paneer_low_fat", "seitan": "seitan", "soy": "soy_chunks"]
    /// Adaptations and copycats only (no cookbook recipes) seeded into the Saved tab.
    private static let savedSeed: [(String, Goal)] = [
        ("web-meal-7th-street-double-impossible-jalapeno-high-protein", .bulk),
        ("web-meal-urad-moong-protein-garelu-air-fried-macro-kitchen", .cut),
        ("web-meal-yogurt-tub-parle-g-elaichi-consumer-queen", .maintain),
    ]

    static func apply(store: RecipeStore, user: UserStore, router: Router) {
        guard let mode else { return }
        user.data.isVegetarian = true
        user.data.goal = .maintain
        var f = FilterState()
        f.section = arg("ssSection") ?? "meal"
        user.data.filterState = f
        switch mode {
        case "recipes":
            router.tab = .recipes
            router.ssSearch = arg("ssSearch")
        case "recipe":
            guard let id = arg("ssId") else { return }
            if let v = arg("ssVersion").flatMap(Goal.init(rawValue:)) { user.setVersion(id, v) }
            if let u = arg("ssUpgrade"), let key = upgradeKeys[u] { user.setUpgrade(id, key) }
            router.ssAnchor = arg("ssAnchor")
            router.open(recipe: id)
        case "filters":
            router.tab = .recipes
            router.ssOpenFilters = true
        case "saved":
            for (id, g) in savedSeed { user.save(id, for: g) }
            router.tab = .favorites
        case "settings":
            router.tab = .settings
        default:
            break
        }
    }
}
#endif
