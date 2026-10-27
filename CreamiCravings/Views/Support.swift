import SwiftUI
import ImageIO

// MARK: - Colors

extension Color {
    static let calorieRed = Color(red: 0.90, green: 0.25, blue: 0.30)
    static let proteinGreen = Color(red: 0.20, green: 0.68, blue: 0.40)
    static let carbBlue = Color(red: 0.25, green: 0.50, blue: 0.92)
    static let fatOrange = Color(red: 0.95, green: 0.60, blue: 0.15)
    static let sugarPink = Color(red: 0.85, green: 0.35, blue: 0.65)
    static let fiberBrown = Color(red: 0.55, green: 0.40, blue: 0.28)

    static var cardBackground: Color {
        #if os(iOS)
        Color(.secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
    static var screenBackground: Color {
        #if os(iOS)
        Color(.systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

// MARK: - Platform shims

extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    func largeTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }
    func noAutocap() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
    /// Full-screen on iPhone, a sheet elsewhere.
    func cookCover<Item: Identifiable, C: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        self
        #endif
    }
    /// Zoom transition source (iOS 18).
    func zoomSource(_ id: String, in ns: Namespace.ID) -> some View {
        #if os(iOS)
        matchedTransitionSource(id: id, in: ns)
        #else
        self
        #endif
    }
    func zoomDestination(_ id: String, in ns: Namespace.ID) -> some View {
        #if os(iOS)
        navigationTransition(.zoom(sourceID: id, in: ns))
        #else
        self
        #endif
    }
}

// MARK: - Navigation state

enum AppTab: Hashable { case recipes, favorites, freezer, shopping, settings }

struct CookRequest: Identifiable {
    let id = UUID()
    var recipeId: String
    var skipChecklist: Bool = false
    var timerID: UUID?
}

@MainActor @Observable
final class Router {
    var tab: AppTab = .recipes
    var recipesPath: [String] = []
    var favoritesPath: [String] = []
    var cook: CookRequest?

    func open(recipe id: String) {
        tab = .recipes
        recipesPath = [id]
    }
}

extension UserStore {
    func result(for r: Recipe, store: RecipeStore) -> RecipeNutrition {
        NutritionCalculator(catalog: store.catalog).compute(r, config(for: r, catalog: store.catalog))
    }
}

// MARK: - Layout

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 320, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, p) in a.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            maxW = max(maxW, x - spacing)
        }
        return (CGSize(width: maxW, height: y + rowH), pts)
    }
}

struct ChipToggle: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(isOn ? Color.accentColor : Color.cardBackground, in: Capsule())
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .overlay(Capsule().strokeBorder(Color.secondary.opacity(isOn ? 0 : 0.25)))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

// MARK: - Photos

@MainActor
enum PhotoCache {
    private static let cache = NSCache<NSString, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ i: CGImage) { image = i } }

    static func image(named name: String, maxPixel: Int) async -> CGImage? {
        let key = "\(name)@\(maxPixel)" as NSString
        if let b = cache.object(forKey: key) { return b.image }
        let img = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension.isEmpty ? "jpg" : (name as NSString).pathExtension
            guard let url = RecipeStore.findResource(base, ext: ext, in: nil, bundle: .main),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let img { cache.setObject(CGImageBox(img), forKey: key) }
        return img
    }
}

/// Remote recipe photos: a dedicated URLSession with a ~200 MB disk cache, thumbnails decoded off the main thread.
@MainActor
enum RemoteImages {
    private static let memory = NSCache<NSString, PhotoCache.CGImageBox>()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("RecipePhotos")
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024, directory: dir)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"]
        return URLSession(configuration: config)
    }()

    static func image(url: URL, maxPixel: Int) async -> CGImage? {
        let key = "\(url.absoluteString)@\(maxPixel)" as NSString
        if let hit = memory.object(forKey: key) { return hit.image }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
        let img = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let img { memory.setObject(PhotoCache.CGImageBox(img), forKey: key) }
        return img
    }
}

struct RecipePhoto: View {
    let recipe: Recipe
    var maxPixel: Int = 600
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill().transition(.opacity)
            } else {
                RecipePlaceholder(recipe: recipe)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .clipped()
        .task(id: "\(recipe.id)|\(recipe.photo ?? "")|\(recipe.photoURL ?? "")") {
            image = nil
            if let name = recipe.photo, let local = await PhotoCache.image(named: name, maxPixel: maxPixel) {
                image = local
            } else if let s = recipe.photoURL, let url = URL(string: s) {
                image = await RemoteImages.image(url: url, maxPixel: maxPixel)      // the gradient stays on failure
            }
        }
    }
}

struct RecipePlaceholder: View {
    let recipe: Recipe

    typealias Style = (colors: [Color], symbol: String)

    static let flavorStyles: [String: Style] = [
        "chocolate": ([Color(red: 0.45, green: 0.28, blue: 0.20), Color(red: 0.25, green: 0.14, blue: 0.10)], "cup.and.saucer"),
        "sorbet": ([Color(red: 1.00, green: 0.62, blue: 0.30), Color(red: 0.95, green: 0.40, blue: 0.25)], "leaf"),
        "fruit": ([Color(red: 1.00, green: 0.62, blue: 0.30), Color(red: 0.95, green: 0.40, blue: 0.25)], "leaf"),
        "mint": ([Color(red: 0.45, green: 0.85, blue: 0.65), Color(red: 0.15, green: 0.60, blue: 0.45)], "sparkles"),
        "coffee": ([Color(red: 0.82, green: 0.68, blue: 0.50), Color(red: 0.60, green: 0.45, blue: 0.32)], "mug"),
        "cheesecake": ([Color(red: 1.00, green: 0.95, blue: 0.80), Color(red: 0.93, green: 0.80, blue: 0.58)], "birthday.cake"),
        "caramel": ([Color(red: 0.95, green: 0.70, blue: 0.35), Color(red: 0.80, green: 0.50, blue: 0.20)], "drop"),
        "peanut-butter": ([Color(red: 0.88, green: 0.65, blue: 0.35), Color(red: 0.70, green: 0.45, blue: 0.22)], "circle.hexagongrid"),
        "cookies": ([Color(red: 0.62, green: 0.55, blue: 0.52), Color(red: 0.35, green: 0.30, blue: 0.30)], "circle.dotted"),
        "cake": ([Color(red: 0.98, green: 0.70, blue: 0.80), Color(red: 0.85, green: 0.45, blue: 0.70)], "birthday.cake"),
        "vanilla": ([Color(red: 0.99, green: 0.92, blue: 0.78), Color(red: 0.90, green: 0.76, blue: 0.55)], "snowflake"),
    ]

    static let courseStyles: [String: Style] = [
        "breakfast": ([Color(red: 1.00, green: 0.80, blue: 0.40), Color(red: 0.95, green: 0.55, blue: 0.30)], "sunrise"),
        "lunch": ([Color(red: 0.40, green: 0.75, blue: 0.55), Color(red: 0.20, green: 0.55, blue: 0.45)], "fork.knife"),
        "dinner": ([Color(red: 0.45, green: 0.45, blue: 0.80), Color(red: 0.25, green: 0.25, blue: 0.55)], "fork.knife"),
        "snack": ([Color(red: 0.95, green: 0.60, blue: 0.55), Color(red: 0.80, green: 0.35, blue: 0.40)], "takeoutbag.and.cup.and.straw"),
        "drink": ([Color(red: 0.45, green: 0.75, blue: 0.95), Color(red: 0.25, green: 0.50, blue: 0.80)], "mug"),
        "side": ([Color(red: 0.55, green: 0.80, blue: 0.45), Color(red: 0.30, green: 0.60, blue: 0.30)], "leaf"),
        "sauce": ([Color(red: 0.90, green: 0.45, blue: 0.35), Color(red: 0.65, green: 0.25, blue: 0.25)], "drop"),
        "dessert": ([Color(red: 0.98, green: 0.70, blue: 0.80), Color(red: 0.85, green: 0.45, blue: 0.70)], "birthday.cake"),
    ]

    /// Fallbacks so untagged recipes do not all look alike; picked by a stable hash of the id.
    static let fallbacks: [Style] = [
        ([Color(red: 0.95, green: 0.45, blue: 0.65), Color(red: 0.70, green: 0.35, blue: 0.80)], "snowflake"),
        ([Color(red: 0.40, green: 0.65, blue: 0.95), Color(red: 0.35, green: 0.40, blue: 0.80)], "snowflake"),
        ([Color(red: 0.95, green: 0.65, blue: 0.45), Color(red: 0.85, green: 0.40, blue: 0.45)], "snowflake"),
        ([Color(red: 0.45, green: 0.80, blue: 0.75), Color(red: 0.25, green: 0.55, blue: 0.65)], "snowflake"),
    ]

    var style: Style {
        if recipe.section == "meal" || recipe.section == "drink" {
            let key = recipe.section == "drink" ? "drink" : (recipe.course ?? "dinner")
            if let s = Self.courseStyles[key] { return s }
        }
        for t in recipe.tags { if let s = Self.flavorStyles[t] { return s } }
        if recipe.section == "dessert", let s = Self.courseStyles["dessert"] { return s }
        let h = recipe.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.fallbacks[h % Self.fallbacks.count]
    }

    var body: some View {
        let s = style
        ZStack {
            LinearGradient(colors: s.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: s.symbol).font(.system(size: 44)).foregroundStyle(.white.opacity(0.78))
        }
    }
}

// MARK: - Macro display

struct MacroPill: View {
    let label: String
    let value: Double
    let unit: String
    let color: Color
    var known = true
    var body: some View {
        VStack(spacing: 2) {
            Text(known ? "\(Int(value.rounded()))\(unit)" : "–")
                .font(.headline.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: value))
            Text(label).font(.caption2.weight(.medium)).opacity(0.85).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8).padding(.horizontal, 2)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(color)
    }
}

struct MacroRow: View {
    let n: Nutrition
    var body: some View {
        HStack(spacing: 6) {
            MacroPill(label: "kcal", value: n.calories, unit: "", color: .calorieRed, known: !n.isMissing("calories"))
            MacroPill(label: "protein", value: n.protein, unit: "g", color: .proteinGreen, known: !n.isMissing("protein"))
            MacroPill(label: "carbs", value: n.carbs, unit: "g", color: .carbBlue, known: !n.isMissing("carbs"))
            MacroPill(label: "fat", value: n.fat, unit: "g", color: .fatOrange, known: !n.isMissing("fat"))
            MacroPill(label: "sugar", value: n.sugar, unit: "g", color: .sugarPink, known: !n.isMissing("sugar"))
            MacroPill(label: "fiber", value: n.fiber, unit: "g", color: .fiberBrown, known: !n.isMissing("fiber"))
        }
    }
}

struct SmallPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct StarRating: View {
    @Binding var rating: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.title2)
                    .foregroundStyle(i <= rating ? Color.yellow : Color.secondary)
                    .onTapGesture { rating = (rating == i) ? 0 : i }
            }
        }
        .sensoryFeedback(.selection, trigger: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating \(rating) of 5")
        .accessibilityAdjustableAction { dir in
            rating = dir == .increment ? min(5, rating + 1) : max(0, rating - 1)
        }
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    let h = s / 3600, m = (s % 3600) / 60
    return h > 0 ? "\(h) h \(m) min" : "\(m) min"
}
