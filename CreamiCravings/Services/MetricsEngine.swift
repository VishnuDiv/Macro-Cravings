import Foundation
import CoreGraphics

// Pure photo-metric math (HEALTH_SPEC §10a): colour conversion, masked blur, skin redness / evenness / spots, hairline height,
// crown scalp visibility, the lighting guard and the trend rule. No Vision or UIKit here, so the logic checks run it on macOS.

enum ColorMath {
    private static let toLinear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// sRGB (0...255) to CIELAB, D65 white.
    static func lab(r: UInt8, g: UInt8, b: UInt8) -> (L: Double, a: Double, b: Double) {
        let lr = toLinear[Int(r)], lg = toLinear[Int(g)], lb = toLinear[Int(b)]
        let x = (0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb) / 0.95047
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = (0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Mean Rec. 709 luma of the gamma-coded pixels, 0...1.
    static func meanLuma(_ img: RGBAImage) -> Double {
        let n = img.width * img.height
        guard n > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<n { sum += 0.2126 * Double(img.data[i * 4]) + 0.7152 * Double(img.data[i * 4 + 1]) + 0.0722 * Double(img.data[i * 4 + 2]) }
        return sum / Double(n) / 255
    }

    static func labPlanes(_ img: RGBAImage) -> (L: [Double], a: [Double], b: [Double]) {
        let n = img.width * img.height
        var L = [Double](repeating: 0, count: n), A = L, B = L
        for i in 0..<n { let c = lab(r: img.data[i * 4], g: img.data[i * 4 + 1], b: img.data[i * 4 + 2]); L[i] = c.L; A[i] = c.a; B[i] = c.b }
        return (L, A, B)
    }
}

enum Blur {
    /// Summed-area table with a zero first row and column.
    static func integral(_ v: [Double], _ w: Int, _ h: Int) -> [Double] {
        var out = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w { row += v[y * w + x]; out[(y + 1) * (w + 1) + x + 1] = out[y * (w + 1) + x + 1] + row }
        }
        return out
    }

    /// Mean of `values` over a (2r+1) square window, counting only pixels with weight > 0 (so masked-out pixels do not bleed in).
    static func weightedMean(_ values: [Double], weights: [Double], _ w: Int, _ h: Int, radius r: Int) -> [Double] {
        let iv = integral(zip(values, weights).map { $0 * $1 }, w, h), iw = integral(weights, w, h)
        var out = [Double](repeating: 0, count: w * h)
        let s = w + 1
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h - 1, y + r)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                let sw = iw[(y1 + 1) * s + x1 + 1] - iw[y0 * s + x1 + 1] - iw[(y1 + 1) * s + x0] + iw[y0 * s + x0]
                if sw > 1e-9 {
                    let sv = iv[(y1 + 1) * s + x1 + 1] - iv[y0 * s + x1 + 1] - iv[(y1 + 1) * s + x0] + iv[y0 * s + x0]
                    out[y * w + x] = sv / sw
                }
            }
        }
        return out
    }
}

enum Stats {
    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
    /// 1.4826 x the median absolute deviation: a robust standard deviation.
    static func robustSigma(_ v: [Double]) -> Double {
        guard let m = median(v) else { return 0 }
        return 1.4826 * (median(v.map { abs($0 - m) }) ?? 0)
    }
}

// MARK: skin

struct SkinMeasure: Equatable {
    var redness: Double        // mean a*
    var evenness: Double       // std-dev of blurred L*
    var spots: Int
    var pixels: Int
}

enum SkinMetrics {
    static let minPixels = 200
    /// Evenness blur window (px) and the spot size range (px, equivalent diameter) at the analysis scale.
    static let blurWindow = 15
    static let spotDiameter = 2.0...12.0

    /// Redness, evenness and spot count over the pixels where `mask` >= 128.
    static func measure(_ img: RGBAImage, mask: GrayMask) -> SkinMeasure? {
        let w = img.width, h = img.height
        guard mask.width == w, mask.height == h else { return nil }
        let m = mask.data.map { $0 >= 128 ? 1.0 : 0.0 }
        let idx = m.indices.filter { m[$0] > 0 }
        guard idx.count >= minPixels else { return nil }
        let (L, A, _) = ColorMath.labPlanes(img)

        let redness = idx.reduce(0) { $0 + A[$1] } / Double(idx.count)

        let blurred = Blur.weightedMean(L, weights: m, w, h, radius: blurWindow / 2)
        let meanB = idx.reduce(0) { $0 + blurred[$1] } / Double(idx.count)
        let evenness = (idx.reduce(0) { $0 + (blurred[$1] - meanB) * (blurred[$1] - meanB) } / Double(idx.count)).squareRoot()

        return SkinMeasure(redness: redness, evenness: evenness, spots: countSpots(L: L, a: A, mask: m, w: w, h: h), pixels: idx.count)
    }

    /// Difference of two box blurs (3 px minus 25 px). Dark spots (relative L* drop, so it follows the lighting) and red spots
    /// (a* rise) above a threshold of 3 robust sigmas (floors: 5 % of L*, 4 a* units) are grouped; blobs 2-12 px across are counted.
    static func countSpots(L: [Double], a: [Double], mask m: [Double], w: Int, h: Int) -> Int {
        let smallL = Blur.weightedMean(L, weights: m, w, h, radius: 1), bigL = Blur.weightedMean(L, weights: m, w, h, radius: 12)
        let smallA = Blur.weightedMean(a, weights: m, w, h, radius: 1), bigA = Blur.weightedMean(a, weights: m, w, h, radius: 12)
        var relL = [Double](repeating: 0, count: w * h), dA = relL
        var inL: [Double] = [], inA: [Double] = []
        for i in 0..<(w * h) where m[i] > 0 {
            relL[i] = (smallL[i] - bigL[i]) / max(bigL[i], 1); dA[i] = smallA[i] - bigA[i]
            inL.append(relL[i]); inA.append(dA[i])
        }
        let thL = max(0.05, 3 * Stats.robustSigma(inL)), thA = max(4.0, 3 * Stats.robustSigma(inA))
        var cand = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) where m[i] > 0 { cand[i] = relL[i] < -thL || dA[i] > thA }

        let minArea = Double.pi * pow(spotDiameter.lowerBound / 2, 2) * 0.75
        let maxArea = Double.pi * pow(spotDiameter.upperBound / 2, 2)
        var seen = [Bool](repeating: false, count: w * h)
        var count = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where cand[start] && !seen[start] {
            var area = 0, minX = w, maxX = 0, minY = h, maxY = 0
            seen[start] = true; stack.append(start)
            while let p = stack.popLast() {
                area += 1
                let x = p % w, y = p / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let q = ny * w + nx
                    if cand[q] && !seen[q] { seen[q] = true; stack.append(q) }
                } }
            }
            let side = Double(max(maxX - minX, maxY - minY) + 1)
            if Double(area) >= minArea && Double(area) <= maxArea && side <= spotDiameter.upperBound + 3 { count += 1 }
        }
        return count
    }
}

enum SkinRegions {
    /// The skin mask from face landmarks alone (no skin matte): forehead plus both cheeks, with eyes, brows and lips cut out.
    static func fallbackMask(width w: Int, height h: Int, face: FaceGeometry) -> GrayMask {
        var mask = GrayMask(width: w, height: h)
        let ip = face.interPupil, box = face.box
        let browTop = face.brows.flatMap { $0 }.map { Double($0.y) }.min() ?? face.browY
        mask.fillEllipse(CGRect(x: box.minX + 0.22 * box.width, y: browTop - 0.20 * box.height, width: 0.56 * box.width, height: 0.17 * box.height), 255)
        let eyeBottomY = Double((face.leftPupil.y + face.rightPupil.y) / 2) + 0.30 * ip
        for (cx, sign) in [(Double(face.leftPupil.x), -1.0), (Double(face.rightPupil.x), 1.0)] {
            let c = cx + sign * 0.10 * ip
            mask.fillEllipse(CGRect(x: c - 0.35 * ip, y: eyeBottomY + 0.20 * ip, width: 0.7 * ip, height: 0.7 * ip), 255)
        }
        cutOutFeatures(&mask, face: face)
        return mask
    }

    /// The skin matte limited to the face box (a little wider), with eyes, brows and lips cut out.
    static func matteMask(_ matte: GrayMask, face: FaceGeometry?) -> GrayMask {
        guard let face else { return matte }
        var out = GrayMask(width: matte.width, height: matte.height)
        let b = face.box.insetBy(dx: -0.08 * face.box.width, dy: -0.08 * face.box.height)
        let x0 = max(0, Int(b.minX)), x1 = min(matte.width, Int(b.maxX)), y0 = max(0, Int(b.minY)), y1 = min(matte.height, Int(b.maxY))
        if x0 < x1 && y0 < y1 { for y in y0..<y1 { for x in x0..<x1 { out[x, y] = matte[x, y] } } }
        cutOutFeatures(&out, face: face)
        return out
    }

    private static func bounds(_ pts: [CGPoint], pad: Double) -> CGRect? {
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return nil }
        return CGRect(x: x0 - pad, y: y0 - pad, width: x1 - x0 + 2 * pad, height: y1 - y0 + 2 * pad)
    }

    static func cutOutFeatures(_ mask: inout GrayMask, face: FaceGeometry) {
        let ip = face.interPupil
        for e in face.eyes { if let r = bounds(e, pad: 0.25 * ip) { mask.fill(r, 0) } }
        for b in face.brows { if let r = bounds(b, pad: 0.12 * ip) { mask.fill(r, 0) } }
        if let r = bounds(face.lips, pad: 0.12 * ip) { mask.fill(r, 0) }
    }
}

// MARK: hair

enum HairlineMath {
    /// Hairline height over inter-pupil distance (so camera distance cancels out). nil for a degenerate geometry.
    static func ratio(boundaryY: Double, browY: Double, interPupil: Double) -> Double? {
        guard interPupil > 1e-6, browY > boundaryY else { return nil }
        return (browY - boundaryY) / interPupil
    }

    /// The lower boundary of the hair matte in a column (3 px band): scanning down from the top, the end of the first hair run
    /// (gaps up to `gapTolerance` px are bridged). Only rows above `limitY` count, so brow hair is ignored. Returns the y just below the hair.
    static func boundary(matte: GrayMask, x: Int, above limitY: Int, halfWidth: Int = 1, gapTolerance: Int = 3) -> Double? {
        guard matte.width > 0, matte.height > 0 else { return nil }
        let x0 = max(0, x - halfWidth), x1 = min(matte.width - 1, x + halfWidth)
        guard x0 <= x1 else { return nil }
        var last: Int?, gap = 0
        for y in 0..<min(limitY, matte.height) {
            var sum = 0
            for xx in x0...x1 { sum += Int(matte[xx, y]) }
            if sum / (x1 - x0 + 1) >= 128 { last = y; gap = 0 }
            else if last != nil { gap += 1; if gap > gapTolerance { break } }
        }
        return last.map { Double($0 + 1) }
    }

    /// Fallback without a hair matte: walks up from the brows and returns the first row (as a boundary y) whose colour departs from the
    /// skin just above the brows by more than 16 delta-E for 4 rows in a row. Lower confidence.
    static func boundaryByColor(_ img: RGBAImage, x: Int, browY: Double, interPupil ip: Double) -> Double? {
        let w = img.width, h = img.height
        guard ip > 1, x >= 0, x < w else { return nil }
        let x0 = max(0, x - 3), x1 = min(w - 1, x + 3)
        func rowLab(_ y: Int) -> (Double, Double, Double) {
            var l = 0.0, a = 0.0, b = 0.0
            for xx in x0...x1 { let i = (y * w + xx) * 4; let c = ColorMath.lab(r: img.data[i], g: img.data[i + 1], b: img.data[i + 2]); l += c.L; a += c.a; b += c.b }
            let n = Double(x1 - x0 + 1)
            return (l / n, a / n, b / n)
        }
        let refTop = Int(browY - 0.30 * ip), refBottom = Int(browY - 0.12 * ip)
        guard refTop >= 0, refBottom < h, refTop < refBottom else { return nil }
        var rl = 0.0, ra = 0.0, rb = 0.0
        for y in refTop...refBottom { let c = rowLab(y); rl += c.0; ra += c.1; rb += c.2 }
        let n = Double(refBottom - refTop + 1)
        rl /= n; ra /= n; rb /= n
        var run = 0
        var y = refTop - 1
        let stop = max(0, Int(browY - 1.6 * ip))
        while y >= stop {
            let c = rowLab(y)
            let de = ((c.0 - rl) * (c.0 - rl) + (c.1 - ra) * (c.1 - ra) + (c.2 - rb) * (c.2 - rb)).squareRoot()
            run = de > 16 ? run + 1 : 0
            if run >= 4 { return Double(y + 4) }       // the first row of the run, as a boundary below the hair
            y -= 1
        }
        return nil
    }
}

enum CrownMath {
    /// Fraction of the centered circle covered by hair, from the matte (soft values count proportionally).
    static func coverage(matte: GrayMask, radiusFraction: Double = 0.3) -> Double? {
        circle(matte.width, matte.height, radiusFraction) { x, y in Double(matte[x, y]) / 255 }
    }

    /// Scalp visibility = 1 - hair coverage.
    static func scalpVisibility(matte: GrayMask, radiusFraction: Double = 0.3) -> Double? { coverage(matte: matte, radiusFraction: radiusFraction).map { 1 - $0 } }

    /// Fallback without a matte: Otsu split of L* inside the circle, the darker class taken as hair (assumes hair darker than scalp; lower
    /// confidence). nil when the two classes are less than 15 L* apart.
    static func coverageByLuminance(_ img: RGBAImage, radiusFraction: Double = 0.3) -> Double? {
        let w = img.width, h = img.height
        let cx = Double(w) / 2, cy = Double(h) / 2, r = radiusFraction * Double(min(w, h))
        var hist = [Double](repeating: 0, count: 101)
        var total = 0.0
        for y in 0..<h { for x in 0..<w where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) <= r {
            let i = (y * w + x) * 4
            hist[min(100, max(0, Int(ColorMath.lab(r: img.data[i], g: img.data[i + 1], b: img.data[i + 2]).L.rounded())))] += 1; total += 1
        } }
        guard total > 50 else { return nil }
        var sumAll = 0.0
        for (i, c) in hist.enumerated() { sumAll += Double(i) * c }
        var w0 = 0.0, sum0 = 0.0, best = -1.0, bestT = 0, m0 = 0.0, m1 = 0.0
        for t in 0..<100 {
            w0 += hist[t]; sum0 += Double(t) * hist[t]
            let w1 = total - w0
            guard w0 > 0, w1 > 0 else { continue }
            let a = sum0 / w0, b = (sumAll - sum0) / w1
            let between = w0 * w1 * (a - b) * (a - b)
            if between > best { best = between; bestT = t; m0 = a; m1 = b }
        }
        guard best >= 0, abs(m1 - m0) >= 15 else { return nil }
        var dark = 0.0
        for t in 0...bestT { dark += hist[t] }
        return dark / total
    }

    private static func circle(_ w: Int, _ h: Int, _ f: Double, _ value: (Int, Int) -> Double) -> Double? {
        let cx = Double(w) / 2, cy = Double(h) / 2, r = f * Double(min(w, h))
        var sum = 0.0, n = 0.0
        guard w > 0, h > 0 else { return nil }
        for y in 0..<h { for x in 0..<w where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) <= r { sum += value(x, y); n += 1 } }
        return n > 0 ? sum / n : nil
    }
}

// MARK: lighting and trends

enum LightingGuard {
    /// A photo whose mean luminance differs from the series median by more than 15 %.
    static let threshold = 0.15

    static func differs(_ luminance: Double, median: Double) -> Bool { median > 0 && abs(luminance - median) / median > threshold }

    /// One flag per photo (nil luminance = not flagged), against the median of the whole series.
    static func flags(_ luminances: [Double?]) -> [Bool] {
        guard let med = Stats.median(luminances.compactMap { $0 }) else { return luminances.map { _ in false } }
        return luminances.map { $0.map { differs($0, median: med) } ?? false }
    }
}

enum MetricTrend {
    enum Label: String { case notEnough = "not enough data", stable, improving, worsening }

    /// Relative change of the least-squares line from its first to its last point (oldest first). nil when it cannot be fitted.
    static func fittedChange(_ values: [Double]) -> Double? {
        let n = values.count
        guard n >= 2 else { return nil }
        let xs = (0..<n).map(Double.init), mx = xs.reduce(0, +) / Double(n), my = values.reduce(0, +) / Double(n)
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let slope = zip(xs, values).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx
        let start = my - slope * mx, end = start + slope * Double(n - 1)
        guard start > 0 else { return nil }
        return (end - start) / start
    }

    /// improving / worsening only with 4+ entries and a fitted change over 5 %; otherwise stable (or not enough data below 4).
    static func evaluate(_ values: [Double], lowerIsBetter: Bool = true) -> (label: Label, change: Double) {
        guard values.count >= 4 else { return (.notEnough, 0) }
        guard let c = fittedChange(values) else { return (.stable, 0) }
        guard abs(c) > 0.05 else { return (.stable, c) }
        return ((c < 0) == lowerIsBetter ? .improving : .worsening, c)
    }
}

// MARK: the whole thing

enum MetricsEngine {
    /// Measures one photo. `hairMatte` / `skinMatte` come from capture-time segmentation (same size as `image`); `face` from Vision landmarks.
    /// Without a matte the landmark / colour fallbacks are used and `lowerConfidence` is set.
    static func compute(series: PhotoSeries, image: RGBAImage, face: FaceGeometry?, hairMatte: GrayMask?, skinMatte: GrayMask?) -> PhotoMetrics {
        var m = PhotoMetrics()
        m.luminance = ColorMath.meanLuma(image)
        switch series {
        case .faceFront, .faceLeft, .faceRight:
            var mask: GrayMask?
            if let sk = skinMatte, sk.width == image.width, sk.height == image.height {
                mask = SkinRegions.matteMask(sk, face: face)
                m.lowerConfidence = face == nil
            } else if let face {
                mask = SkinRegions.fallbackMask(width: image.width, height: image.height, face: face)
                m.lowerConfidence = true
            } else { m.lowerConfidence = true }
            if let mask, let s = SkinMetrics.measure(image, mask: mask) { m.redness = s.redness; m.evenness = s.evenness; m.spots = s.spots }
        case .hairline:
            guard let face, face.hasBrows, face.interPupil > 1 else { m.lowerConfidence = true; break }
            let ip = face.interPupil, brow = face.browY
            let limit = Int(brow - 0.1 * ip)
            var useMatte = false
            func boundary(_ x: Double) -> Double? {
                if let hm = hairMatte, hm.width == image.width, hm.height == image.height { useMatte = true; return HairlineMath.boundary(matte: hm, x: Int(x.rounded()), above: limit) }
                return HairlineMath.boundaryByColor(image, x: Int(x.rounded()), browY: brow, interPupil: ip)
            }
            m.hairlineRatio = boundary(face.midlineX).flatMap { HairlineMath.ratio(boundaryY: $0, browY: brow, interPupil: ip) }
            let temples = face.templeColumns.compactMap { boundary($0) }.compactMap { HairlineMath.ratio(boundaryY: $0, browY: brow, interPupil: ip) }
            if !temples.isEmpty { m.hairlineTempleRatio = temples.reduce(0, +) / Double(temples.count) }
            m.lowerConfidence = !useMatte
        case .crown:
            if let hm = hairMatte { m.scalpVisibility = CrownMath.scalpVisibility(matte: hm) }
            else { m.scalpVisibility = CrownMath.coverageByLuminance(image).map { 1 - $0 }; m.lowerConfidence = true }
        default:
            break
        }
        return m
    }
}
