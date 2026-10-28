import Foundation

// Content files (original content, bundled): Resources/skincare.json and Resources/haircare.json. Their "_schema" key describes the shape.
// Every field decodes leniently so a content update can add or drop fields without breaking the app.

private func strings<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> [String] { (try? c.decode([String].self, forKey: k)) ?? [] }
private func string<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K, _ d: String = "") -> String { (try? c.decode(String.self, forKey: k)) ?? d }

// MARK: skincare

struct SkinActive: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var whatItDoes: String
    var bestFor: [String]
    var howToStart: String
    var whenToExpect: String
    var sideEffects: String
    var evidence: String                    // A strong | B moderate | C weak | D none
    var otc: Bool                           // false = prescription
    var rxNote: String?
    var pairsWellWith: [String]
    var avoidWith: [String]
    enum CodingKeys: String, CodingKey { case id, name, whatItDoes, bestFor, howToStart, whenToExpect, sideEffects, evidence, otc, rxNote, pairsWellWith, avoidWith }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id)
        whatItDoes = string(c, .whatItDoes); howToStart = string(c, .howToStart); whenToExpect = string(c, .whenToExpect); sideEffects = string(c, .sideEffects)
        bestFor = strings(c, .bestFor); pairsWellWith = strings(c, .pairsWellWith); avoidWith = strings(c, .avoidWith)
        evidence = string(c, .evidence, "C")
        otc = (try? c.decode(Bool.self, forKey: .otc)) ?? true
        rxNote = (try? c.decodeIfPresent(String.self, forKey: .rxNote)) ?? nil
    }
    var isRetinoid: Bool { ["adapalene", "retinol", "tretinoin", "retinal"].contains(id) }
}

struct RoutineStep: Codable, Hashable {
    var step: String                        // cleanser | treatment | moisturizer | spf | spot
    var activeId: String?
    var frequency: String                   // daily | 2-3x-week | alternate-nights | ramp-up | as-needed
    var note: String
    enum CodingKeys: String, CodingKey { case step, activeId, frequency, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = try c.decode(String.self, forKey: .step)
        activeId = (try? c.decodeIfPresent(String.self, forKey: .activeId)) ?? nil
        frequency = string(c, .frequency, "daily")
        note = string(c, .note)
    }
}

struct SkinRoutineTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var skinTypes: [String]
    var concerns: [String]
    var description: String
    var am: [RoutineStep]
    var pm: [RoutineStep]
    enum CodingKeys: String, CodingKey { case id, name, skinTypes, concerns, description, am, pm }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id)
        skinTypes = strings(c, .skinTypes); concerns = strings(c, .concerns); description = string(c, .description)
        am = decodeLenientArray(from: c, key: .am); pm = decodeLenientArray(from: c, key: .pm)
    }
}

struct SkinConflict: Codable, Hashable {
    var a: String
    var b: String
    var sameTime: Bool                      // true: only when both are in the same AM or PM session
    var severity: String                    // info | caution
    var message: String
    enum CodingKeys: String, CodingKey { case a, b, sameTime, severity, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        a = try c.decode(String.self, forKey: .a); b = try c.decode(String.self, forKey: .b)
        sameTime = (try? c.decode(Bool.self, forKey: .sameTime)) ?? true
        severity = string(c, .severity, "caution")
        message = string(c, .message, "\(a) and \(b) can irritate skin when used together.")
    }
}

struct RampStep: Codable, Hashable {
    var week: Int
    var nightsPerWeek: Int
}

struct ProductExample: Codable, Hashable {
    var name: String
    var brand: String
    var activeIds: [String]
    var approxPriceUSD: Double?
    var note: String
    enum CodingKeys: String, CodingKey { case name, brand, activeIds, approxPriceUSD, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = string(c, .name); brand = string(c, .brand); activeIds = strings(c, .activeIds); note = string(c, .note)
        approxPriceUSD = (try? c.decodeIfPresent(Double.self, forKey: .approxPriceUSD)) ?? nil
    }
}

struct SkincareContent: Decodable {
    var actives: [SkinActive]
    var routines: [SkinRoutineTemplate]
    var conflicts: [SkinConflict]
    var rampUps: [String: [RampStep]]
    var products: [String: [ProductExample]]
    var guides: [Guide]
    enum CodingKeys: String, CodingKey { case actives, routines, conflicts, rampUps, products, guides }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actives = decodeLenientArray(from: c, key: .actives)
        routines = decodeLenientArray(from: c, key: .routines)
        conflicts = decodeLenientArray(from: c, key: .conflicts)
        rampUps = (try? c.decode([String: [RampStep]].self, forKey: .rampUps)) ?? [:]
        products = (try? c.decode([String: [ProductExample]].self, forKey: .products)) ?? [:]
        guides = decodeLenientArray(from: c, key: .guides)
    }
    func active(_ id: String?) -> SkinActive? { id.flatMap { i in actives.first { $0.id == i } } }
}

// MARK: haircare

struct FaceShapeInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var howToTell: String
    var aimFor: String
    var goodStyles: [String]
    var avoid: String
    enum CodingKeys: String, CodingKey { case id, name, howToTell, aimFor, goodStyles, avoid }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id.capitalized); howToTell = string(c, .howToTell); aimFor = string(c, .aimFor); avoid = string(c, .avoid)
        goodStyles = strings(c, .goodStyles)
    }
    var symbol: String {
        switch id {
        case "round": return "circle"; case "square": return "square"; case "oblong": return "capsule.portrait"
        case "heart": return "heart"; case "diamond": return "diamond"; default: return "oval.portrait"
        }
    }
}

struct NorwoodStage: Codable, Hashable, Identifiable {
    var stage: Int
    var label: String
    var description: String
    var typicalAdvice: String
    var id: Int { stage }
    enum CodingKeys: String, CodingKey { case stage, label, description, typicalAdvice }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(Int.self, forKey: .stage)
        label = string(c, .label, "Norwood \(stage)"); description = string(c, .description); typicalAdvice = string(c, .typicalAdvice)
    }
}

struct HairStyle: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var description: String
    var faceShapes: [String]
    var hairTypes: [String]
    var lengths: [String]
    var norwoodMax: Int
    var receding: String                    // great | ok | avoid
    var barberAsk: String
    var maintenance: String                 // low | med | high
    var productTips: String
    enum CodingKeys: String, CodingKey { case id, name, description, suits, receding, barberAsk, maintenance, productTips }
    enum SuitKeys: String, CodingKey { case faceShapes, hairTypes, lengths, norwoodMax }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id); description = string(c, .description); barberAsk = string(c, .barberAsk); productTips = string(c, .productTips)
        receding = string(c, .receding, "ok"); maintenance = string(c, .maintenance, "med")
        let s = try? c.nestedContainer(keyedBy: SuitKeys.self, forKey: .suits)
        faceShapes = (try? s?.decode([String].self, forKey: .faceShapes)) ?? []
        hairTypes = (try? s?.decode([String].self, forKey: .hairTypes)) ?? []
        lengths = (try? s?.decode([String].self, forKey: .lengths)) ?? []
        norwoodMax = (try? s?.decode(Int.self, forKey: .norwoodMax)) ?? 7
    }
}

struct HairIntervention: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var evidence: String
    var type: String                        // Rx | OTC | procedure | lifestyle | supplement
    var rxNote: String?
    var whatItDoes: String
    var howToUse: String
    var whenToExpect: String
    var sideEffects: String
    var cost: String
    var regrowVsMaintain: String
    var rank: Int
    enum CodingKeys: String, CodingKey { case id, name, evidence, type, rxNote, whatItDoes, howToUse, whenToExpect, sideEffects, cost, regrowVsMaintain, rank }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id); evidence = string(c, .evidence, "C"); type = string(c, .type, "OTC")
        rxNote = (try? c.decodeIfPresent(String.self, forKey: .rxNote)) ?? nil
        whatItDoes = string(c, .whatItDoes); howToUse = string(c, .howToUse); whenToExpect = string(c, .whenToExpect); sideEffects = string(c, .sideEffects)
        cost = string(c, .cost); regrowVsMaintain = string(c, .regrowVsMaintain)
        rank = (try? c.decode(Int.self, forKey: .rank)) ?? 99
    }
    var needsDoctor: Bool { type == "Rx" || type == "procedure" || rxNote != nil }
}

struct HairPlanStep: Codable, Hashable {
    var interventionId: String
    var how: String
    var priority: String                    // core | add-on | optional
    enum CodingKeys: String, CodingKey { case interventionId, how, priority }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interventionId = try c.decode(String.self, forKey: .interventionId)
        how = string(c, .how); priority = string(c, .priority, "core")
    }
}

struct HairPlan: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var norwoodMin: Int
    var norwoodMax: Int
    var goal: String
    var steps: [HairPlanStep]
    var notes: String
    enum CodingKeys: String, CodingKey { case id, name, norwoodRange, goal, steps, notes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id); goal = string(c, .goal); notes = string(c, .notes)
        let r = (try? c.decode([Int].self, forKey: .norwoodRange)) ?? [1, 7]
        norwoodMin = r.first ?? 1; norwoodMax = r.count > 1 ? r[1] : 7
        steps = decodeLenientArray(from: c, key: .steps)
    }
}

struct HairRoutineTemplate: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var schedule: String                    // daily | every-2-days | 2x-week | weekly
    var timeOfDay: String
    var linkedIntervention: String?
    var note: String
    enum CodingKeys: String, CodingKey { case id, name, schedule, timeOfDay, linkedIntervention, note }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = string(c, .name, id); schedule = string(c, .schedule, "daily"); timeOfDay = string(c, .timeOfDay, "any"); note = string(c, .note)
        linkedIntervention = (try? c.decodeIfPresent(String.self, forKey: .linkedIntervention)) ?? nil
    }
}

struct HairMyth: Codable, Hashable {
    var myth: String
    var truth: String
    enum CodingKeys: String, CodingKey { case myth, truth }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        myth = try c.decode(String.self, forKey: .myth); truth = string(c, .truth)
    }
}

struct HaircareContent: Decodable {
    var interventions: [HairIntervention]
    var myths: [HairMyth]
    var norwood: [NorwoodStage]
    var plans: [HairPlan]
    var styles: [HairStyle]
    var faceShapes: [FaceShapeInfo]
    var howToMeasure: [String]
    var routineItems: [HairRoutineTemplate]
    var guides: [Guide]
    enum CodingKeys: String, CodingKey { case interventions, myths, norwood, plans, styles, faceShapeGuide, routineItems, guides }
    enum ShapeKeys: String, CodingKey { case howToMeasure, shapes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interventions = decodeLenientArray(from: c, key: .interventions)
        myths = decodeLenientArray(from: c, key: .myths)
        norwood = decodeLenientArray(from: c, key: .norwood)
        plans = decodeLenientArray(from: c, key: .plans)
        styles = decodeLenientArray(from: c, key: .styles)
        routineItems = decodeLenientArray(from: c, key: .routineItems)
        guides = decodeLenientArray(from: c, key: .guides)
        let s = try? c.nestedContainer(keyedBy: ShapeKeys.self, forKey: .faceShapeGuide)
        howToMeasure = (try? s?.decode([String].self, forKey: .howToMeasure)) ?? []
        faceShapes = s.map { decodeLenientArray(from: $0, key: ShapeKeys.shapes) } ?? []
    }
    func intervention(_ id: String?) -> HairIntervention? { id.flatMap { i in interventions.first { $0.id == i } } }
}
