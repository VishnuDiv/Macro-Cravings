// Extracts the main food photo of each recipe page from the two cookbook PDFs.
//
// Build + run (macOS frameworks only):
//   swiftc -O tools/extract_book_photos.swift -o /tmp/extract_book_photos && /tmp/extract_book_photos [--only id1,id2]
//
// For every recipe in data/books/*.json it opens the book PDF (source.title picks the file; source.page is the 1-based page),
// walks the page's XObject images (including nested Form XObjects), scores each one with a detail test (see `detail`) so page
// backgrounds, gradients, solid fills and banners are rejected, takes the survivor with the highest area x edge energy,
// downsizes it to 900 px wide, and writes CreamiCravings/Resources/Photos/<recipe id>.jpg (JPEG quality 0.72).
// Personal-copy content: Resources/Photos is gitignored.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().path
let projectDir = FileManager.default.fileExists(atPath: "data/books") ? FileManager.default.currentDirectoryPath : root
let booksDir = projectDir + "/data/books"
let outDir = projectDir + "/CreamiCravings/Resources/Photos"
let pdfPaths: [String: String] = [
    "The Ultimate High Protein Chef Cookbook": ProcessInfo.processInfo.environment["CHEF_PDF"] ?? "",
    "The Ultimate Guide to Lean Bulking": ProcessInfo.processInfo.environment["BULK_PDF"] ?? "",
]
let minShortSide = 250
let outWidth = 900
let quality = 0.72

struct Candidate { var width: Int; var height: Int; var stream: CGPDFStreamRef; var dict: CGPDFDictionaryRef }

/// Collects image XObjects of a resource dictionary, following Form XObjects.
func collectImages(resources: CGPDFDictionaryRef, into list: inout [Candidate], depth: Int = 0) {
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xo = xobjects, depth < 4 else { return }
    final class Box { var items: [(CGPDFStreamRef, CGPDFDictionaryRef)] = [] }
    let box = Box()
    CGPDFDictionaryApplyBlock(xo, { _, object, info in
        var stream: CGPDFStreamRef?
        if CGPDFObjectGetValue(object, .stream, &stream), let s = stream, let d = CGPDFStreamGetDictionary(s) {
            Unmanaged<Box>.fromOpaque(info!).takeUnretainedValue().items.append((s, d))
        }
        return true
    }, Unmanaged.passUnretained(box).toOpaque())
    for (stream, dict) in box.items {
        var subtype: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let st = subtype else { continue }
        let kind = String(cString: st)
        if kind == "Image" {
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dict, "Width", &w), CGPDFDictionaryGetInteger(dict, "Height", &h) {
                list.append(Candidate(width: Int(w), height: Int(h), stream: stream, dict: dict))
            }
        } else if kind == "Form" {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let r = res { collectImages(resources: r, into: &list, depth: depth + 1) }
        }
    }
}

/// Decodes a PDF image stream to a CGImage (JPEG bytes as they are, otherwise raw samples with the stream's colour space).
func decode(_ c: Candidate) -> CGImage? {
    var format = CGPDFDataFormat.raw
    guard let data = CGPDFStreamCopyData(c.stream, &format) else { return nil }
    if format == .jpegEncoded || format == .JPEG2000 {
        guard let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    var bpc: CGPDFInteger = 8
    CGPDFDictionaryGetInteger(c.dict, "BitsPerComponent", &bpc)
    guard bpc == 8 else { return nil }
    var comps = 3
    var space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    var csName: UnsafePointer<CChar>?
    if CGPDFDictionaryGetName(c.dict, "ColorSpace", &csName), let n = csName {
        if String(cString: n) == "DeviceGray" { comps = 1; space = CGColorSpaceCreateDeviceGray() }
        else if String(cString: n) == "DeviceCMYK" { comps = 4; space = CGColorSpaceCreateDeviceCMYK() }
    } else {
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(c.dict, "ColorSpace", &arr), let a = arr {
            var nm: UnsafePointer<CChar>?
            if CGPDFArrayGetName(a, 0, &nm), let n = nm, String(cString: n) == "ICCBased" {
                var s: CGPDFStreamRef?
                if CGPDFArrayGetStream(a, 1, &s), let st = s, let d = CGPDFStreamGetDictionary(st) {
                    var n: CGPDFInteger = 3
                    CGPDFDictionaryGetInteger(d, "N", &n)
                    comps = Int(n)
                    space = comps == 1 ? CGColorSpaceCreateDeviceGray() : (comps == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB())
                }
            } else { return nil }                       // Indexed and other colour spaces are not handled
        }
    }
    let bytes = (data as Data)
    guard bytes.count >= c.width * c.height * comps, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
    return CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 8 * comps, bytesPerRow: c.width * comps,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// Detail test on a 64x64 grayscale downsample. Photos have edges and texture; page backgrounds are smooth gradients or fills.
struct Detail { var edge: Double; var stddev: Double; var colMedian: Double; var rowMedian: Double
    /// Rejected: little edge energy, or every column (left-to-right gradient) or every row (top-to-bottom gradient) is near-constant.
    var isPhoto: Bool { edge >= 4 && colMedian >= 3 && rowMedian >= 3 }
}

func detail(_ image: CGImage) -> Detail? {
    let n = 64
    var px = [UInt8](repeating: 0, count: n * n)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        return true
    }
    guard ok else { return nil }
    let g = px.map(Double.init)
    func at(_ x: Int, _ y: Int) -> Double { g[y * n + x] }
    var v = 0.0, h = 0.0
    for y in 0..<(n - 1) { for x in 0..<n { v += abs(at(x, y) - at(x, y + 1)) } }
    for y in 0..<n { for x in 0..<(n - 1) { h += abs(at(x, y) - at(x + 1, y)) } }
    let edge = v / Double(n * (n - 1)) + h / Double(n * (n - 1))
    func std(_ a: [Double]) -> Double { let m = a.reduce(0, +) / Double(a.count); return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot() }
    func median(_ a: [Double]) -> Double { let s = a.sorted(); return s[s.count / 2] }
    let cols = (0..<n).map { x in std((0..<n).map { at(x, $0) }) }
    let rows = (0..<n).map { y in std((0..<n).map { at($0, y) }) }
    return Detail(edge: edge, stddev: std(g), colMedian: median(cols), rowMedian: median(rows))
}

func writeJPEG(_ image: CGImage, to path: String) -> Int? {
    let scale = min(1.0, Double(outWidth) / Double(image.width))
    let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

// MARK: main

var only: Set<String>?
if let i = CommandLine.arguments.firstIndex(of: "--only"), i + 1 < CommandLine.arguments.count {
    only = Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
var docs: [String: PDFDocument] = [:]
var found: [String: Int] = [:], total: [String: Int] = [:], bytesOut = 0
var missing: [String] = [], samples: [String] = []

let files = ((try? FileManager.default.contentsOfDirectory(atPath: booksDir)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
for f in files {
    guard let data = FileManager.default.contents(atPath: booksDir + "/" + f),
          let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
    for r in items {
        guard let id = r["id"] as? String, let src = r["source"] as? [String: Any], let title = src["title"] as? String,
              let page = src["page"] as? Int, let path = pdfPaths[title] else { continue }
        if let only, !only.contains(id) { continue }
        total[title, default: 0] += 1
        if docs[title] == nil { docs[title] = PDFDocument(url: URL(fileURLWithPath: path)) }
        guard let pdfPage = docs[title]?.page(at: page - 1), let cg = pdfPage.pageRef, let pageDict = cg.dictionary else { missing.append(id + " (no page)"); continue }
        var list: [Candidate] = []
        var res: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(pageDict, "Resources", &res), let r = res { collectImages(resources: r, into: &list) }
        // Candidates: images with short side >= 250 px and aspect <= 4; keep those that pass the detail test; best = area x edge energy.
        var scored: [(img: CGImage, score: Double)] = []
        for cand in list where min(cand.width, cand.height) >= minShortSide && Double(max(cand.width, cand.height)) / Double(min(cand.width, cand.height)) <= 4 {
            guard let img = decode(cand), let d = detail(img), d.isPhoto else { continue }
            scored.append((img, Double(cand.width * cand.height) * d.edge))
        }
        scored.sort { $0.score > $1.score }
        var written = false
        if let top = scored.first, let size = writeJPEG(top.img, to: outDir + "/" + id + ".jpg") {
            found[title, default: 0] += 1; bytesOut += size; written = true
            if samples.count < 5 { samples.append(id) }
        }
        if !written { missing.append("\(id) (p\(page), \(list.count) images, none looked like a photo)") }
    }
}

print("Photos written to \(outDir)")
for (t, n) in total.sorted(by: { $0.key < $1.key }) { print("  \(t): \(found[t, default: 0]) of \(n)") }
print(String(format: "  total size: %.1f MB", Double(bytesOut) / 1_048_576))
print("  samples: " + samples.joined(separator: ", "))
print("  no photo (\(missing.count)): " + missing.prefix(40).joined(separator: "; "))
