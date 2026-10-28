import Foundation
import CoreGraphics

// On-device photo metrics (HEALTH_SPEC §10a). Everything here is Foundation / CoreGraphics only, so it runs in the macOS logic checks.

/// Numbers measured on one progress photo. Stored in the entry's JSON next to the photo; never uploaded.
struct PhotoMetrics: Codable, Hashable {
    var luminance: Double = 0              // mean luma of the whole photo, 0...1
    var redness: Double?                   // mean CIELAB a* over the skin region (higher = redder)
    var evenness: Double?                  // std-dev of L* after a 15 px blur (lower = more even)
    var spots: Int?                        // local-contrast blobs, 2-12 px
    var hairlineRatio: Double?             // hairline-to-brow distance at the midline / inter-pupil distance
    var hairlineTempleRatio: Double?       // the same at the two temple columns (mean)
    var scalpVisibility: Double?           // 1 - hair coverage in a centered circle (crown photos)
    var lowerConfidence = false            // true when no hair / skin matte was used (landmark or colour fallback)
    var version = 1

    init() {}
    enum CodingKeys: String, CodingKey { case luminance, redness, evenness, spots, hairlineRatio, hairlineTempleRatio, scalpVisibility, lowerConfidence, version }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        luminance = (try? c.decode(Double.self, forKey: .luminance)) ?? 0
        redness = (try? c.decodeIfPresent(Double.self, forKey: .redness)) ?? nil
        evenness = (try? c.decodeIfPresent(Double.self, forKey: .evenness)) ?? nil
        spots = (try? c.decodeIfPresent(Int.self, forKey: .spots)) ?? nil
        hairlineRatio = (try? c.decodeIfPresent(Double.self, forKey: .hairlineRatio)) ?? nil
        hairlineTempleRatio = (try? c.decodeIfPresent(Double.self, forKey: .hairlineTempleRatio)) ?? nil
        scalpVisibility = (try? c.decodeIfPresent(Double.self, forKey: .scalpVisibility)) ?? nil
        lowerConfidence = (try? c.decode(Bool.self, forKey: .lowerConfidence)) ?? false
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
    }
}

/// An 8-bit RGBA pixel buffer (row-major, origin top-left).
struct RGBAImage {
    var width: Int
    var height: Int
    var data: [UInt8]                      // width * height * 4

    init(width: Int, height: Int, data: [UInt8]) { self.width = width; self.height = height; self.data = data }
    /// A flat-colour image.
    init(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) {
        self.width = width; self.height = height
        data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { data[i * 4] = r; data[i * 4 + 1] = g; data[i * 4 + 2] = b }
    }
    mutating func fill(_ rect: CGRect, r: UInt8, g: UInt8, b: UInt8) {
        let x0 = max(0, Int(rect.minX.rounded())), x1 = min(width, Int(rect.maxX.rounded()))
        let y0 = max(0, Int(rect.minY.rounded())), y1 = min(height, Int(rect.maxY.rounded()))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 { let i = (y * width + x) * 4; data[i] = r; data[i + 1] = g; data[i + 2] = b } }
    }
    mutating func fillDisc(cx: Double, cy: Double, radius: Double, r: UInt8, g: UInt8, b: UInt8) {
        let x0 = max(0, Int(cx - radius - 1)), x1 = min(width - 1, Int(cx + radius + 1))
        let y0 = max(0, Int(cy - radius - 1)), y1 = min(height - 1, Int(cy + radius + 1))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 { for x in x0...x1 where hypot(Double(x) - cx, Double(y) - cy) <= radius { let i = (y * width + x) * 4; data[i] = r; data[i + 1] = g; data[i + 2] = b } }
    }
}

/// An 8-bit single-channel mask or matte (0...255), row-major, origin top-left.
struct GrayMask {
    var width: Int
    var height: Int
    var data: [UInt8]

    init(width: Int, height: Int, fill: UInt8 = 0) { self.width = width; self.height = height; data = [UInt8](repeating: fill, count: width * height) }
    init(width: Int, height: Int, data: [UInt8]) { self.width = width; self.height = height; self.data = data }
    subscript(x: Int, y: Int) -> UInt8 {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }
    mutating func fill(_ rect: CGRect, _ v: UInt8) {
        let x0 = max(0, Int(rect.minX.rounded())), x1 = min(width, Int(rect.maxX.rounded()))
        let y0 = max(0, Int(rect.minY.rounded())), y1 = min(height, Int(rect.maxY.rounded()))
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 { data[y * width + x] = v } }
    }
    mutating func fillEllipse(_ rect: CGRect, _ v: UInt8) {
        let cx = rect.midX, cy = rect.midY, rx = max(0.5, rect.width / 2), ry = max(0.5, rect.height / 2)
        let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(rect.maxX))
        let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(rect.maxY))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 { for x in x0...x1 {
            let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
            if dx * dx + dy * dy <= 1 { data[y * width + x] = v }
        } }
    }
}

/// Face landmarks in pixel coordinates of the analysed image (origin top-left). The iOS side converts Vision's output into this.
struct FaceGeometry {
    var box: CGRect
    var leftPupil: CGPoint                 // the smaller-x pupil
    var rightPupil: CGPoint
    var brows: [[CGPoint]]                 // one point list per eyebrow
    var eyes: [[CGPoint]]
    var lips: [CGPoint]

    var interPupil: Double { Double(hypot(rightPupil.x - leftPupil.x, rightPupil.y - leftPupil.y)) }
    var midlineX: Double { Double((leftPupil.x + rightPupil.x) / 2) }
    /// The brow line: mean y of all eyebrow points.
    var browY: Double {
        let ys = brows.flatMap { $0 }.map { Double($0.y) }
        return ys.isEmpty ? Double((leftPupil.y + rightPupil.y) / 2) - 0.35 * interPupil : ys.reduce(0, +) / Double(ys.count)
    }
    /// Outer ends of the brows (the temple columns).
    var templeColumns: [Double] {
        let xs = brows.compactMap { b -> (Double, Double)? in b.isEmpty ? nil : (Double(b.map(\.x).min()!), Double(b.map(\.x).max()!)) }
        guard xs.count == 2 else { return [] }
        let sorted = xs.sorted { $0.0 < $1.0 }
        return [sorted[0].0, sorted[1].1]
    }
    var hasBrows: Bool { brows.contains { !$0.isEmpty } }
}
