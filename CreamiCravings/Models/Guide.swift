import Foundation

struct GuideTable: Codable, Hashable {
    var columns: [String]
    var rows: [[String]]
    enum CodingKeys: String, CodingKey { case columns, rows }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = (try? c.decodeIfPresent([String].self, forKey: .columns)) ?? []
        rows = (try? c.decodeIfPresent([[String]].self, forKey: .rows)) ?? []
    }
}

struct GuideSection: Codable, Hashable {
    var heading: String
    var body: String
    var bullets: [String]?
    var table: GuideTable?
    enum CodingKeys: String, CodingKey { case heading, body, bullets, table }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heading = (try? c.decodeIfPresent(String.self, forKey: .heading)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        bullets = (try? c.decodeIfPresent([String].self, forKey: .bullets)) ?? nil
        table = (try? c.decodeIfPresent(GuideTable.self, forKey: .table)) ?? nil
    }
}

struct Guide: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    var sections: [GuideSection]
    enum CodingKeys: String, CodingKey { case id, title, subtitle, icon, sections }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let t = try c.decode(String.self, forKey: .title)
        title = t
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? t
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? ""
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? "book.pages"
        sections = decodeLenientArray(from: c, key: .sections)
    }
}

/// Paneer yield model (Resources/paneer_model.json). Fractions may be given as 0.75 or 75.
struct PaneerModel: Codable, Hashable {
    var proteinRecovery: Double
    var fatRecovery: Double
    var lactoseRecovery: Double
    var moisturePct: Double
    var ashGramsPerLiter: Double
    var notes: String?
    var overrides: [String: PaneerOverride]

    struct PaneerOverride: Codable, Hashable {
        var proteinRecovery: Double?
        var fatRecovery: Double?
        var lactoseRecovery: Double?
        var moisturePct: Double?
    }

    static let fallback = PaneerModel(proteinRecovery: 0.78, fatRecovery: 0.88, lactoseRecovery: 0.04, moisturePct: 0.55,
                                      ashGramsPerLiter: 0, notes: "Typical home pressing; adjust to your own results.", overrides: [:])

    init(proteinRecovery: Double, fatRecovery: Double, lactoseRecovery: Double, moisturePct: Double,
         ashGramsPerLiter: Double, notes: String?, overrides: [String: PaneerOverride]) {
        self.proteinRecovery = proteinRecovery; self.fatRecovery = fatRecovery; self.lactoseRecovery = lactoseRecovery
        self.moisturePct = moisturePct; self.ashGramsPerLiter = ashGramsPerLiter; self.notes = notes; self.overrides = overrides
    }

    enum CodingKeys: String, CodingKey { case proteinRecovery, fatRecovery, lactoseRecovery, moisturePct, ashGramsPerLiter, notes, overrides }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = PaneerModel.fallback
        proteinRecovery = (try? c.decodeIfPresent(Double.self, forKey: .proteinRecovery)) ?? f.proteinRecovery
        fatRecovery = (try? c.decodeIfPresent(Double.self, forKey: .fatRecovery)) ?? f.fatRecovery
        lactoseRecovery = (try? c.decodeIfPresent(Double.self, forKey: .lactoseRecovery)) ?? f.lactoseRecovery
        moisturePct = (try? c.decodeIfPresent(Double.self, forKey: .moisturePct)) ?? f.moisturePct
        ashGramsPerLiter = (try? c.decodeIfPresent(Double.self, forKey: .ashGramsPerLiter)) ?? 0
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? nil
        overrides = (try? c.decodeIfPresent([String: PaneerOverride].self, forKey: .overrides)) ?? [:]
    }
}
