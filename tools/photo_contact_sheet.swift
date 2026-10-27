// Self-check for extract_book_photos: one contact-sheet JPEG of 24 random book photos (120 px each, with their ids),
// plus the number of book photos that still look like a gradient (per-column or per-row std-dev median < 3).
//   swiftc -O tools/photo_contact_sheet.swift -o /tmp/photo_contact_sheet && /tmp/photo_contact_sheet [seed] [out.jpg]
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let seed = UInt64(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 3 : 3)
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
    : NSTemporaryDirectory() + "contact_sheet.jpg"
let project = FileManager.default.currentDirectoryPath
let photoDir = project + "/CreamiCravings/Resources/Photos"

struct SplitMix { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
var rng = SplitMix(s: seed)

// ids of book recipes that have a photo
var ids: [String] = []
for f in ((try? FileManager.default.contentsOfDirectory(atPath: project + "/data/books")) ?? []).filter({ $0.hasSuffix(".json") }).sorted() {
    guard let d = FileManager.default.contents(atPath: project + "/data/books/" + f),
          let items = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { continue }
    for r in items { if let id = r["id"] as? String, FileManager.default.fileExists(atPath: photoDir + "/" + id + ".jpg") { ids.append(id) } }
}

func load(_ id: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: photoDir + "/" + id + ".jpg") as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func colRowMedians(_ image: CGImage) -> (Double, Double) {
    let n = 64
    var px = [UInt8](repeating: 0, count: n * n)
    px.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    }
    let g = px.map(Double.init)
    func std(_ a: [Double]) -> Double { let m = a.reduce(0, +) / Double(a.count); return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot() }
    func median(_ a: [Double]) -> Double { a.sorted()[a.count / 2] }
    return (median((0..<n).map { x in std((0..<n).map { g[$0 * n + x] }) }), median((0..<n).map { y in std((0..<n).map { g[y * n + $0] }) }))
}

var flat: [String] = []
for id in ids { if let img = load(id) { let (c, r) = colRowMedians(img); if c < 3 || r < 3 { flat.append(id) } } }
print("book photos: \(ids.count); still gradient-like (per-column or per-row std-dev median < 3): \(flat.count) \(flat.prefix(10))")

// contact sheet: 6 x 4 cells of 120 px + label
var pool = ids
var pick: [String] = []
while pick.count < 24 && !pool.isEmpty { pick.append(pool.remove(at: Int(rng.next() % UInt64(pool.count)))) }
let cols = 6, cell = 120, labelH = 22, pad = 6
let rows = (pick.count + cols - 1) / cols
let W = cols * (cell + pad) + pad, H = rows * (cell + labelH + pad) + pad
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gc
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7), .foregroundColor: NSColor.black]
for (i, id) in pick.enumerated() {
    let cx = pad + (i % cols) * (cell + pad), cy = H - pad - (i / cols + 1) * (cell + labelH + pad) + pad
    if let img = load(id) {
        let s = min(Double(cell) / Double(img.width), Double(cell) / Double(img.height))
        let w = Double(img.width) * s, h = Double(img.height) * s
        gc.cgContext.draw(img, in: CGRect(x: Double(cx) + (Double(cell) - w) / 2, y: Double(cy + labelH) + (Double(cell) - h) / 2, width: w, height: h))
    }
    let label = id.count > 26 ? String(id.prefix(26)) : id
    (label as NSString).draw(in: NSRect(x: cx, y: cy + 8, width: cell, height: 10), withAttributes: attrs)
    ((id.count > 26 ? String(id.dropFirst(26).prefix(26)) : "") as NSString).draw(in: NSRect(x: cx, y: cy, width: cell, height: 10), withAttributes: attrs)
}
NSGraphicsContext.restoreGraphicsState()
try? FileManager.default.createDirectory(atPath: (outPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
try! data.write(to: URL(fileURLWithPath: outPath))
print("contact sheet: \(outPath) (\(pick.count) photos, seed \(seed)): \(pick.joined(separator: ", "))")
