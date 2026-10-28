import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// AI check-up over raw HTTPS (HEALTH_SPEC §10b): schema, system prompt, image prep, request builder, response parser and a client with
// an injectable transport. Foundation / ImageIO only, so the logic checks run it on macOS. The API key and the image data are never logged.

// MARK: schema

enum CheckupSchema {
    private static var str: [String: Any] { ["type": "string"] }
    private static func enumStr(_ v: [String]) -> [String: Any] { ["type": "string", "enum": v] }
    private static func arr(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    /// Every key is required and no extra keys are allowed.
    private static func obj(_ props: KeyValuePairs<String, [String: Any]>) -> [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in props { p[k] = v }
        return ["type": "object", "properties": p, "required": props.map(\.key), "additionalProperties": false]
    }
    private static func nullable(_ s: [String: Any]) -> [String: Any] { ["anyOf": [s, ["type": "null"]]] }

    private static var observation: [String: Any] {
        obj(["area": str, "finding": str, "severity": enumStr(["none", "mild", "moderate", "severe"]), "confidence": enumStr(["low", "medium", "high"])])
    }
    private static var priority: [String: Any] { enumStr(["high", "medium", "low"]) }

    static var schema: [String: Any] {
        obj([
            "overall": obj(["summary": str, "nextCheckupWeeks": ["type": "integer"]]),
            "photoQuality": obj(["ok": ["type": "boolean"], "issues": arr(str)]),
            "skin": nullable(obj([
                "observations": arr(observation),
                "likelyDrivers": arr(str),
                "recommendations": arr(obj(["action": str, "activeId": nullable(str), "frequency": str, "why": str, "priority": priority])),
                "avoid": arr(str)])),
            "hair": nullable(obj([
                "norwoodEstimate": str,
                "observations": arr(observation),
                "recommendations": arr(obj(["action": str, "interventionId": nullable(str), "why": str, "priority": priority])),
                "styleIds": arr(str)])),
            "seeDermatologist": obj(["recommended": ["type": "boolean"], "reason": str]),
        ])
    }
}

enum CheckupPrompt {
    static let system = """
    You are a dermatology- and trichology-informed assistant reviewing progress photos for skincare and hair-loss self-care. \
    Describe only what is visible in the photos, with a severity and a confidence for each finding. Name the likely drivers. \
    Recommend concrete steps, and where a recommendation maps to a product active or a hair intervention or a hairstyle, use ONLY the ids \
    provided in the context (never invent an id; use null when none applies). State uncertainty plainly. \
    Set seeDermatologist.recommended to true when there are red flags (painful or cystic or scarring acne, sudden patchy hair loss, \
    changing moles, rashes) or when prescription options (finasteride, tretinoin, oral minoxidil) are the logical next step, and say why. \
    Do not moralise and do not add generic disclaimers. Report photo-quality problems (lighting, angle, blur, framing) in photoQuality. \
    Return only the JSON that matches the schema; fill skin or hair with null when that part was not requested.
    """
}

// MARK: image prep

enum ImagePrep {
    static let maxEdge = 1568
    static let quality = 0.8

    /// Re-encodes from pixels: long edge at most 1568 px, JPEG 0.8, orientation baked in, and no EXIF / GPS / TIFF metadata at all.
    static func prepare(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: min(maxEdge, max(pw, ph)),
        ]
        guard let pixels = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return stripMetadataSegments(out as Data)
    }

    /// ImageIO still writes a tiny EXIF block (colour space, pixel size) of its own. Drops every APPn segment except JFIF (APP0), the ICC
    /// profile (APP2) and Adobe (APP14), and comments, so the file carries no metadata at all.
    static func stripMetadataSegments(_ jpeg: Data) -> Data {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let marker = b[i + 1]
            if marker == 0xDA { break }                                   // start of scan: the rest is pixel data
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard len >= 2, i + 2 + len <= b.count else { return jpeg }
            let keep = !((0xE1...0xEF).contains(marker) && marker != 0xE2 && marker != 0xEE) && marker != 0xFE
            if keep { out.append(contentsOf: b[i..<(i + 2 + len)]) }
            i += 2 + len
        }
        out.append(contentsOf: b[i...])
        return Data(out)
    }
}

// MARK: request

struct PreparedPhoto {
    var label: String              // "Photo 1 · Hairline · 2026-10-27"
    var jpeg: Data                 // already prepared (ImagePrep)
}

enum CheckupRequest {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let model = "claude-opus-5-5"
    static let version = "2026-10-21"
    static let beta = "server-side-fallback-2026-07-01"
    static let maxTokens = 16000
    static let timeout: TimeInterval = 180

    /// The JSON body. No thinking and no sampling parameters, on purpose.
    static func body(photos: [PreparedPhoto], contextJSON: String, effort: String) -> [String: Any] {
        var content: [[String: Any]] = []
        for p in photos {
            content.append(["type": "text", "text": p.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": p.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": contextJSON])
        return [
            "model": model,
            "max_tokens": maxTokens,
            "fallbacks": "default",
            "output_config": ["effort": effort, "format": ["type": "json_schema", "schema": CheckupSchema.schema]],
            "system": CheckupPrompt.system,
            "messages": [["role": "user", "content": content]],
        ]
    }

    static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func build(key: String, photos: [PreparedPhoto], contextJSON: String, effort: String) throws -> URLRequest {
        try request(key: key, body: encode(body(photos: photos, contextJSON: contextJSON, effort: effort)))
    }

    /// A tiny request for the "Test key" button: one short message, a few output tokens.
    static func testRequest(key: String) throws -> URLRequest {
        let body: [String: Any] = ["model": model, "max_tokens": 16, "fallbacks": "default", "messages": [["role": "user", "content": "Reply with the word ok."]]]
        return try request(key: key, body: encode(body))
    }

    private static func request(key: String, body: Data) -> URLRequest {
        var r = URLRequest(url: endpoint, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(version, forHTTPHeaderField: "anthropic-version")
        r.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        r.httpBody = body
        return r
    }

    /// The body as text with every base64 image string cut to `keep` characters (for logs, tests and docs; never includes the key).
    static func redactedBody(_ data: Data, keep: Int = 40) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if var msgs = obj["messages"] as? [[String: Any]] {
            for i in msgs.indices {
                guard var content = msgs[i]["content"] as? [[String: Any]] else { continue }
                for j in content.indices {
                    guard var src = content[j]["source"] as? [String: Any], let d = src["data"] as? String else { continue }
                    src["data"] = String(d.prefix(keep)) + "… (\(d.count) chars)"
                    content[j]["source"] = src
                }
                msgs[i]["content"] = content
            }
            obj["messages"] = msgs
        }
        let out = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: response

enum CheckupError: Error, Equatable {
    case noKey
    case refusal
    case truncated                      // max_tokens even after the retry with lower effort
    case http(Int, String)
    case network(String)
    case noText
    case badJSON(String)
    case photoUnreadable

    var message: String {
        switch self {
        case .noKey: return "Add your API key in Settings first."
        case .refusal: return "The analysis couldn't be completed for these photos."
        case .truncated: return "The answer was cut off twice. Try again with fewer photos."
        case .http(let code, let m): return code == 401 ? "The API key was rejected." : "The service answered \(code)\(m.isEmpty ? "" : ": " + m)"
        case .network(let m): return "No connection to the service (\(m))."
        case .noText: return "The service returned no text."
        case .badJSON: return "The answer could not be read."
        case .photoUnreadable: return "One of the photos could not be read."
        }
    }
}

enum CheckupResponse {
    enum Kind: Equatable { case text(String), refusal, maxTokens }

    static func parse(_ data: Data) throws -> (kind: Kind, usage: CheckupUsage) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw CheckupError.badJSON("response") }
        let u = obj["usage"] as? [String: Any]
        let usage = CheckupUsage(inputTokens: (u?["input_tokens"] as? Int) ?? 0, outputTokens: (u?["output_tokens"] as? Int) ?? 0)
        switch obj["stop_reason"] as? String {
        case "refusal": return (.refusal, usage)
        case "max_tokens": return (.maxTokens, usage)
        default: break
        }
        let blocks = (obj["content"] as? [[String: Any]]) ?? []
        guard let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else { throw CheckupError.noText }
        return (.text(text), usage)
    }

    static func decode(_ json: String) throws -> CheckupResult {
        do { return try JSONDecoder().decode(CheckupResult.self, from: Data(json.utf8)) }
        catch { throw CheckupError.badJSON("\(error)") }
    }

    /// The API's error message, if the body has one.
    static func errorMessage(_ data: Data) -> String {
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String ?? ""
    }
}

// MARK: client

protocol CheckupTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: CheckupTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = CheckupRequest.timeout
        cfg.timeoutIntervalForResource = CheckupRequest.timeout * 2
        cfg.urlCache = nil
        let (data, resp) = try await URLSession(configuration: cfg).data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

struct CheckupOutcome {
    var result: CheckupResult
    var usage: CheckupUsage
    var effort: String
    var cost: Double { CheckupPricing.cost(usage) }
}

struct CheckupClient {
    var transport: CheckupTransport = URLSessionTransport()
    /// Pause before the single retry (injectable so tests do not wait).
    var sleep: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }

    /// One request, with one retry on 429 / 5xx / a network error (honouring `retry-after`, at most 60 s).
    func send(_ make: () throws -> URLRequest) async throws -> Data {
        var lastError: CheckupError = .network("unknown")
        for attempt in 0..<2 {
            do {
                let (data, http) = try await transport.send(try make())
                if http.statusCode == 200 { return data }
                let err = CheckupError.http(http.statusCode, CheckupResponse.errorMessage(data))
                guard http.statusCode == 429 || http.statusCode >= 500 else { throw err }
                lastError = err
                if attempt == 0 { await sleep(Self.retryDelay(http)) }
            } catch let e as CheckupError {
                throw e
            } catch {
                lastError = .network((error as? URLError).map { "\($0.code.rawValue)" } ?? "error")
                if attempt == 0 { await sleep(2) }
            }
        }
        throw lastError
    }

    static func retryDelay(_ http: HTTPURLResponse) -> TimeInterval {
        let v = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 2
        return min(60, max(0, v))
    }

    /// The full check-up. A max_tokens stop is retried once with effort "medium"; a refusal is an error; token usage is summed.
    func run(key: String, photos: [PreparedPhoto], contextJSON: String) async throws -> CheckupOutcome {
        var usage = CheckupUsage()
        var effort = "high"
        while true {
            let data = try await send { try CheckupRequest.build(key: key, photos: photos, contextJSON: contextJSON, effort: effort) }
            let parsed = try CheckupResponse.parse(data)
            usage = usage + parsed.usage
            switch parsed.kind {
            case .refusal: throw CheckupError.refusal
            case .maxTokens:
                guard effort == "high" else { throw CheckupError.truncated }
                effort = "medium"
            case .text(let json):
                return CheckupOutcome(result: try CheckupResponse.decode(json), usage: usage, effort: effort)
            }
        }
    }

    /// "Test key": a tiny request. Throws the same errors; success means the key works.
    func testKey(_ key: String) async throws {
        _ = try await send { try CheckupRequest.testRequest(key: key) }
    }
}
