import Foundation
import Security

// Everything around the AI check-up that is not the network call: the Keychain wrapper, the request context, photo pre-selection,
// "Add to routine" mapping, history, comparing two check-ups, and canned fixtures for screenshots and tests.

// MARK: Keychain

protocol SecretStore {
    func read(service: String, account: String) -> String?
    @discardableResult func write(_ value: String, service: String, account: String) -> Bool
    @discardableResult func delete(service: String, account: String) -> Bool
}

/// kSecClassGenericPassword, readable only while the phone is unlocked and never copied to another device.
struct KeychainSecretStore: SecretStore {
    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    func write(_ value: String, service: String, account: String) -> Bool {
        _ = delete(service: service, account: account)
        var q = query(service, account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    func delete(service: String, account: String) -> Bool {
        let s = SecItemDelete(query(service, account) as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }
}

/// For tests and screenshot mode.
final class MemorySecretStore: SecretStore {
    private var items: [String: String] = [:]
    func read(service: String, account: String) -> String? { items[service + "|" + account] }
    func write(_ value: String, service: String, account: String) -> Bool { items[service + "|" + account] = value; return true }
    func delete(service: String, account: String) -> Bool { items[service + "|" + account] = nil; return true }
}

struct APIKeyStore {
    var store: SecretStore = KeychainSecretStore()
    var service = "com.vishnudiv.CreamiCravings.anthropic"
    var account = "api-key"

    var key: String? { store.read(service: service, account: account).flatMap { $0.isEmpty ? nil : $0 } }
    var hasKey: Bool { key != nil }
    @discardableResult func save(_ k: String) -> Bool {
        let t = k.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? false : store.write(t, service: service, account: account)
    }
    func remove() { store.delete(service: service, account: account) }
    /// "sk-ant-…1234" for display; the full key is never shown or logged.
    var masked: String? { key.map { $0.count > 10 ? String($0.prefix(7)) + "…" + String($0.suffix(4)) : "••••" } }
}

// MARK: context sent with the photos

enum CheckupContext {
    /// The final text block of the request: profile, routine, the previous check-up summary and the ids the answer may use.
    static func json(scope: String, user: UserData, skincare: SkincareContent?, haircare: HaircareContent?, previous: CheckupRecord?) -> String {
        var ctx: [String: Any] = ["scope": scope]
        if scope != "hair" {
            var p: [String: Any] = ["concerns": user.skinProfile.concerns.sorted()]
            if let t = user.skinProfile.skinType { p["skinType"] = t }
            if let s = user.skinProfile.sun { p["sunExposure"] = s }
            ctx["skinProfile"] = p
            ctx["skinRoutine"] = user.products.map { pr -> [String: Any] in
                var d: [String: Any] = ["name": pr.name, "step": pr.step, "period": pr.period, "frequency": pr.frequency]
                if let a = pr.activeId { d["activeId"] = a }
                return d
            }
        }
        if scope != "skin" {
            var p: [String: Any] = ["concerns": user.hairProfile.concerns.sorted()]
            for (k, v) in [("hairType", user.hairProfile.hairType), ("thickness", user.hairProfile.thickness), ("length", user.hairProfile.length), ("faceShape", user.hairProfile.faceShape)] {
                if let v { p[k] = v }
            }
            if let n = user.hairProfile.norwood { p["selfAssessedNorwood"] = n }
            ctx["hairProfile"] = p
            ctx["hairRoutine"] = user.hairItems.map { it -> [String: Any] in
                var d: [String: Any] = ["title": it.title, "schedule": it.schedule]
                if let i = it.interventionId { d["interventionId"] = i }
                return d
            }
        }
        if let previous { ctx["previousCheckupSummary"] = previous.summaryLine }
        var allowed: [String: Any] = [:]
        if scope != "hair" { allowed["activeIds"] = (skincare?.actives.map(\.id) ?? []).sorted() }
        if scope != "skin" {
            allowed["interventionIds"] = (haircare?.interventions.map(\.id) ?? []).sorted()
            allowed["styleIds"] = (haircare?.styles.map(\.id) ?? []).sorted()
        }
        ctx["allowedIds"] = allowed
        let data = (try? JSONSerialization.data(withJSONObject: ctx, options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: choosing photos

enum CheckupPhotos {
    static let maxPhotos = 4

    /// Series in the order they are picked, per scope.
    static func priority(_ scope: String) -> [PhotoSeries] {
        switch scope {
        case "skin": return [.faceFront, .faceLeft, .faceRight]
        case "hair": return [.hairline, .crown, .templeLeft, .templeRight, .hairOverall]
        default: return [.faceFront, .hairline, .crown, .faceLeft, .templeLeft, .faceRight, .templeRight, .hairOverall]
        }
    }

    /// The latest photo per relevant series, at most 4.
    static func preselect(scope: String, latest: [PhotoSeries: ProgressEntry]) -> [ProgressEntry] {
        Array(priority(scope).compactMap { latest[$0] }.prefix(maxPhotos))
    }

    /// "Photo 1 · Hairline · 2026-10-27"
    static func label(_ index: Int, _ e: ProgressEntry) -> String { "Photo \(index + 1) · \(e.series.title) · \(isoDay(e.date))" }
}

// MARK: Add to routine

enum CheckupActions {
    /// A placeholder product for a recommended active ("Add to routine"); the user fills in the real product later.
    static func product(for rec: CheckupSkinRec, skincare: SkincareContent?, now: Date = Date()) -> SkinProduct? {
        guard let id = rec.activeId, !id.isEmpty else { return nil }
        let active = skincare?.active(id)
        let step = skincare?.routines.flatMap { $0.am + $0.pm }.first { $0.activeId == id }?.step ?? "treatment"
        var p = SkinProduct(name: active?.name ?? id.replacingOccurrences(of: "_", with: " ").capitalized, step: step)
        p.activeId = id
        p.period = step == "spf" ? "am" : "pm"
        p.startedAt = now
        let f = rec.frequency.lowercased()
        if f.contains("ramp") { p.frequency = "ramp-up" }
        else if f.contains("alternate") || f.contains("every other") { p.frequency = "alternate"; p.weekdays = [2, 4, 6] }
        else if f.contains("2-3") || f.contains("2–3") || f.contains("two") || f.contains("three") || f.contains("2x") || f.contains("3x") { p.frequency = "2-3x"; p.weekdays = [2, 4, 6] }
        else if f.contains("week") && !f.contains("daily") { p.frequency = "weekly"; p.weekdays = [2] }
        else if f.contains("as needed") || f.contains("as-needed") || f.contains("spot") { p.frequency = "as-needed" }
        else { p.frequency = "daily" }
        return p
    }

    /// A hair routine item for a recommended intervention.
    static func hairItem(for rec: CheckupHairRec, haircare: HaircareContent?, now: Date = Date()) -> HairRoutineItem? {
        guard let id = rec.interventionId, !id.isEmpty else { return nil }
        let template = haircare?.routineItems.first { $0.linkedIntervention == id }
        let name = haircare?.intervention(id)?.name ?? id.replacingOccurrences(of: "_", with: " ").capitalized
        return HairRoutineItem(title: template?.name ?? name, interventionId: id, schedule: template?.schedule ?? "daily", startedAt: now, note: template?.note ?? rec.why)
    }

    /// Adds the product unless the same active is already in the list. Returns whether it was added.
    @discardableResult
    static func add(_ p: SkinProduct, to products: inout [SkinProduct]) -> Bool {
        if let a = p.activeId, products.contains(where: { $0.activeId == a }) { return false }
        products.append(p); return true
    }
    @discardableResult
    static func add(_ item: HairRoutineItem, to items: inout [HairRoutineItem]) -> Bool {
        if items.contains(where: { $0.interventionId != nil && $0.interventionId == item.interventionId }) { return false }
        items.append(item); return true
    }
}

// MARK: history and comparison

/// Saved check-ups: one JSON file next to the progress photos (same folder, so the same backup rule and "delete all" apply).
struct CheckupHistory {
    let file: URL
    init(root: URL) { file = root.appendingPathComponent("checkups.json") }

    private var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    func load() -> [CheckupRecord] {
        guard let d = try? Data(contentsOf: file), let list = try? coder.1.decode([CheckupRecord].self, from: d) else { return [] }
        return list.sorted { $0.date < $1.date }
    }

    func save(_ list: [CheckupRecord]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try coder.0.encode(list).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

enum CheckupDiff {
    struct Change: Hashable { var area: String; var text: String; var better: Bool? }

    /// What changed between two check-ups: observation severities by area, new and dropped recommendations, the dermatologist flag.
    static func compare(old: CheckupResult, new: CheckupResult) -> [Change] {
        var out: [Change] = []
        func obs(_ r: CheckupResult) -> [String: CheckupObservation] {
            var m: [String: CheckupObservation] = [:]
            for o in (r.skin?.observations ?? []) + (r.hair?.observations ?? []) { m[o.area.lowercased()] = o }
            return m
        }
        let a = obs(old), b = obs(new)
        for (k, n) in b.sorted(by: { $0.key < $1.key }) {
            if let o = a[k] {
                if o.severityRank != n.severityRank {
                    out.append(Change(area: n.area, text: "\(o.severity) → \(n.severity)", better: n.severityRank < o.severityRank))
                }
            } else { out.append(Change(area: n.area, text: "new: \(n.severity)", better: n.severityRank == 0 ? true : nil)) }
        }
        for (k, o) in a.sorted(by: { $0.key < $1.key }) where b[k] == nil { out.append(Change(area: o.area, text: "no longer mentioned (was \(o.severity))", better: nil)) }
        func actions(_ r: CheckupResult) -> Set<String> { Set((r.skin?.recommendations.map(\.action) ?? []) + (r.hair?.recommendations.map(\.action) ?? [])) }
        let oa = actions(old), na = actions(new)
        for x in na.subtracting(oa).sorted() { out.append(Change(area: "New advice", text: x, better: nil)) }
        for x in oa.subtracting(na).sorted() { out.append(Change(area: "Dropped advice", text: x, better: nil)) }
        if old.seeDermatologist.recommended != new.seeDermatologist.recommended {
            out.append(Change(area: "Dermatologist", text: new.seeDermatologist.recommended ? "now recommended" : "no longer flagged", better: !new.seeDermatologist.recommended))
        }
        return out
    }
}

// MARK: fixtures

enum CheckupFixtures {
    /// A canned model answer (the text of the first content block). Used by screenshot mode and the decoder checks. Never from the network.
    static let resultJSON = """
    {"overall":{"summary":"Skin looks calmer than last time, with mild redness on the cheeks. Hairline looks stable.","nextCheckupWeeks":4},
     "photoQuality":{"ok":true,"issues":["Hairline photo is slightly warmer in tone than the face photo."]},
     "skin":{"observations":[
        {"area":"Cheeks","finding":"Mild diffuse redness, no raised lesions.","severity":"mild","confidence":"medium"},
        {"area":"Forehead","finding":"A few small closed comedones.","severity":"mild","confidence":"high"}],
       "likelyDrivers":["Barrier irritation from frequent exfoliation","Oil and congestion in the T-zone"],
       "recommendations":[
        {"action":"Add a gentle retinoid two nights a week","activeId":"adapalene","frequency":"2-3x per week","why":"Targets the closed comedones.","priority":"high"},
        {"action":"Use sunscreen every morning","activeId":null,"frequency":"daily","why":"Protects the skin while using actives.","priority":"medium"}],
       "avoid":["Scrubbing with physical exfoliants"]},
     "hair":{"norwoodEstimate":"Norwood 2 (mild temple recession)",
       "observations":[{"area":"Temples","finding":"Slight symmetric recession, no clear thinning.","severity":"mild","confidence":"medium"}],
       "recommendations":[{"action":"Start topical minoxidil once a day","interventionId":"minoxidil_topical","why":"Evidence-backed for maintaining density.","priority":"high"}],
       "styleIds":[]},
     "seeDermatologist":{"recommended":false,"reason":"No red flags in these photos."}}
    """

    static var result: CheckupResult { try! CheckupResponse.decode(resultJSON) }

    /// The same answer wrapped the way the API returns it.
    static func responseData(stopReason: String = "end_turn", input: Int = 9_500, output: Int = 2_100, text: String = resultJSON) -> Data {
        let obj: [String: Any] = ["id": "msg_fixture", "type": "message", "role": "assistant", "stop_reason": stopReason,
                                  "content": [["type": "text", "text": text]], "usage": ["input_tokens": input, "output_tokens": output]]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Fixture records for the screenshot mode history.
    static func record(date: Date) -> CheckupRecord {
        let u = CheckupUsage(inputTokens: 9_500, outputTokens: 2_100)
        return CheckupRecord(date: date, scope: "both", result: result, photos: [], usage: u, cost: CheckupPricing.cost(u), effort: "high")
    }
}
