#if DEBUG
import Foundation
#if os(iOS)
import UIKit
#endif

/// DEBUG-only: launch arguments that put the app in a fixed state for README screenshots (tools/screenshots.sh).
/// It uses a fresh in-memory UserStore (saved data is never touched), default settings, vegetarian mode on, goal Maintain, and never
/// loads remote photos. This file is not compiled into Release builds.
///
///   -ss recipes  [-ssSection meal] [-ssSearch "text"]
///   -ss recipe   -ssId <id> [-ssVersion cut|maintain|bulk] [-ssUpgrade tofu|paneer|seitan|soy] [-ssAnchor versionCard|macros|ingredients|upgrade|boost]
///   -ss airfry   [-ssId <id>]  (a recipe detail in its air-fryer version, scrolled to the Fried | Air fryer control)
///   -ss filters  [-ssSection meal]
///   -ss guide    -ssGuide paneer
///   -ss saved | -ss settings
///   -ss plan   (Food mode, Plan tab, a generated sample day at the goal's default targets)
///   -ss today | skin | hair | progress   (Health mode with sample data; photos are generated drawings, never real ones)
///   -ss checkup   (Progress tab opened on a canned AI check-up result; the network is never used in screenshot mode)
@MainActor
enum ScreenshotMode {
    /// Generated sample photos live here (a temp folder), never in the real Application Support/Progress folder.
    static let sampleRoot = FileManager.default.temporaryDirectory.appendingPathComponent("creami_screenshot_progress", isDirectory: true)

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

    static func apply(store: RecipeStore, user: UserStore, router: Router, lib: ProgressLibrary) {
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
        case "airfry":
            user.data.preferAirFryer = true
            router.ssAnchor = arg("ssAnchor") ?? "airfry"
            router.open(recipe: arg("ssId") ?? "web-meal-chilli-paneer-recipe-dry-gravy-indianhealthyrecipes")
        case "filters":
            router.tab = .recipes
            router.ssOpenFilters = true
        case "saved":
            for (id, g) in savedSeed { user.save(id, for: g) }
            router.tab = .favorites
        case "settings":
            router.tab = .settings
        case "plan":
            user.data.appMode = .food
            user.data.healthLockEnabled = false
            router.tab = .plan
            let planner = MealPlanner(store: store, user: user)
            let t = PlanTargets(kcal: Double(user.data.dailyKcal), protein: Double(user.data.dailyProtein))
            user.data.plans[PlanKey.key(Date())] = planner.generateDay(seed: 1, targets: t, goal: user.data.goal, existing: nil, avoid: [], includeDessert: false, focus: nil)
        case "today", "skin", "hair", "progress", "checkup":
            user.data.appMode = .health
            user.data.healthLockEnabled = false
            seedHealthSamples(store: store, user: user)
            router.tab = ["today": .today, "skin": .skin, "hair": .hair, "progress": .progress, "checkup": .progress][mode] ?? .today
            if mode == "checkup" || mode == "progress" {
                var older = CheckupFixtures.record(date: Date().addingTimeInterval(-42 * 86400))
                older.result.skin?.observations[0].severity = "moderate"
                lib.checkups.add(older)
                lib.checkups.add(CheckupFixtures.record(date: Date()))
                router.ssOpenCheckup = mode == "checkup"
            }
            lib.touch()
        default:
            break
        }
    }

    /// A routine, a hair profile and drawn (not real) sample photos so the Health screens have something to show.
    private static func seedHealthSamples(store: RecipeStore, user: UserStore) {
        user.data.skinProfile.skinType = "combination"; user.data.skinProfile.concerns = ["acne", "oil"]; user.data.skinProfile.sun = "moderate"
        user.data.hairProfile.hairType = "wavy"; user.data.hairProfile.faceShape = "oval"; user.data.hairProfile.length = "short"
        user.data.hairProfile.thickness = "medium"; user.data.hairProfile.concerns = ["receding_hairline"]; user.data.hairProfile.norwood = 2
        if let t = store.catalog.skincare?.routines.first {
            let now = Date()
            func prod(_ s: RoutineStep, _ period: String) -> SkinProduct {
                var p = SkinProduct(name: store.catalog.skincare?.active(s.activeId)?.name ?? Pretty.text(s.step), step: s.step)
                p.activeId = s.activeId; p.period = period; p.startedAt = now.addingTimeInterval(-30 * 86400)
                if s.frequency == "ramp-up" { p.frequency = "ramp-up" } else if s.frequency != "daily" { p.frequency = "2-3x"; p.weekdays = [2, 4, 6] }
                return p
            }
            user.data.products = t.am.map { prod($0, "am") } + t.pm.map { prod($0, "pm") }
        }
        if let item = store.catalog.haircare?.routineItems.first {
            user.data.hairItems = [HairRoutineItem(title: item.name, interventionId: item.linkedIntervention, schedule: item.schedule, note: item.note)]
        }
        var sched = PhotoSchedule(); sched.enabled = true; sched.frequency = "weekly"
        user.data.photoSchedules[PhotoSeries.faceFront.rawValue] = sched
        user.data.photoSchedules[PhotoSeries.hairline.rawValue] = sched
        #if os(iOS)
        let ps = ProgressStore(root: sampleRoot)
        ps.deleteAll()
        for (series, step) in [(PhotoSeries.faceFront, 0), (.hairline, 1)] {
            for i in 0..<5 {
                let date = Date().addingTimeInterval(-Double(5 - i) * 7 * 86400)
                var e = ProgressEntry(series: series, date: date)
                if series == .hairline {
                    let drift = 0.002 * Double(i)
                    e.marks = HairlineMarks(hairline: [NormPoint(x: 0.32, y: 0.22 + drift), NormPoint(x: 0.5, y: 0.19 + drift), NormPoint(x: 0.68, y: 0.22 + drift)], brows: [NormPoint(x: 0.34, y: 0.48), NormPoint(x: 0.66, y: 0.48)])
                }
                // measured numbers for the charts (the sample photos are drawings, so Vision is never run on them); one photo has off lighting
                var m = PhotoMetrics()
                m.luminance = i == 2 ? 0.74 : 0.55 + 0.004 * Double(i)
                if series == .faceFront { m.redness = 17.5 - 0.7 * Double(i); m.evenness = 4.2 - 0.15 * Double(i); m.spots = 9 - i }
                else { m.hairlineRatio = 0.80 + 0.012 * Double(i); m.hairlineTempleRatio = 0.86 + 0.01 * Double(i); m.lowerConfidence = i == 0 }
                e.metrics = m
                if let jpg = samplePhoto(hue: 0.08 + 0.02 * Double(step), shift: Double(i)) { _ = try? ps.save(jpeg: jpg, entry: e, excludeFromBackup: true) }
            }
        }
        #endif
    }

    #if os(iOS)
    /// A simple drawn face; there are no real photos anywhere in screenshot mode.
    private static func samplePhoto(hue: Double, shift: Double) -> Data? {
        let size = CGSize(width: 600, height: 800)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(hue: 0.58, saturation: 0.1, brightness: 0.92, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.35, brightness: 0.85 - shift * 0.01, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 150, y: 170, width: 300, height: 400))
            UIColor.darkGray.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 215, y: 330, width: 40, height: 20)); ctx.cgContext.fillEllipse(in: CGRect(x: 345, y: 330, width: 40, height: 20))
            ctx.cgContext.fill(CGRect(x: 205, y: 300, width: 60, height: 8)); ctx.cgContext.fill(CGRect(x: 335, y: 300, width: 60, height: 8))
            UIColor(hue: 0.07, saturation: 0.6, brightness: 0.25, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 140, y: 140, width: 320, height: 150 - shift * 3))
        }
        return img.jpegData(compressionQuality: 0.8)
    }
    #endif
}
#endif
