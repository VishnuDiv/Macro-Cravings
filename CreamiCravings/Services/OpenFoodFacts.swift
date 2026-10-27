import Foundation

struct OFFProduct: Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var brand: String
    var per100g: Nutrition
    var servingSize: String?
}

enum OFFError: LocalizedError {
    case notFound, badResponse
    var errorDescription: String? {
        switch self {
        case .notFound: return "Product not found on Open Food Facts."
        case .badResponse: return "Open Food Facts did not respond correctly."
        }
    }
}

enum OpenFoodFacts {
    static let userAgent = "CreamiCravings/1.0 (personal app)"

    static func parse(_ p: [String: Any], code fallbackCode: String = "") -> OFFProduct? {
        func num(_ v: Any?) -> Double {
            if let d = v as? Double { return d }
            if let s = v as? String, let d = Double(s) { return d }
            if let i = v as? Int { return Double(i) }
            return 0
        }
        let nut = p["nutriments"] as? [String: Any] ?? [:]
        let name = (p["product_name"] as? String) ?? ""
        guard !name.isEmpty else { return nil }
        let code = (p["code"] as? String) ?? fallbackCode
        return OFFProduct(
            code: code, name: name, brand: (p["brands"] as? String) ?? "",
            per100g: Nutrition(calories: num(nut["energy-kcal_100g"]), protein: num(nut["proteins_100g"]),
                               carbs: num(nut["carbohydrates_100g"]), fat: num(nut["fat_100g"]),
                               sugar: num(nut["sugars_100g"]), fiber: num(nut["fiber_100g"])),
            servingSize: p["serving_size"] as? String)
    }

    private static func get(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OFFError.badResponse }
        return obj
    }

    static func product(barcode: String) async throws -> OFFProduct {
        let code = barcode.filter { $0.isNumber }
        guard !code.isEmpty,
              let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=product_name,brands,nutriments,serving_size")
        else { throw OFFError.notFound }
        let obj = try await get(url)
        guard let p = obj["product"] as? [String: Any], let prod = parse(p, code: code) else { throw OFFError.notFound }
        return prod
    }

    static func search(_ query: String) async throws -> [OFFProduct] {
        var comps = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        comps.queryItems = [
            URLQueryItem(name: "search_terms", value: query), URLQueryItem(name: "search_simple", value: "1"),
            URLQueryItem(name: "json", value: "1"), URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "fields", value: "code,product_name,brands,nutriments"),
        ]
        guard let url = comps.url else { throw OFFError.badResponse }
        let obj = try await get(url)
        let arr = obj["products"] as? [[String: Any]] ?? []
        return arr.compactMap { parse($0) }
    }
}
