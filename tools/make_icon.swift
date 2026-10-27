// Draws the Macro Kitchen app icon (1024x1024, opaque PNG): a pint with a spoon and a leaf.
// Usage: swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <out.png> [light|dark|tinted]
// dark/tinted are the iOS 18+/26 appearance variants (tinted also drives the Clear icon style).
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "light"
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

struct Palette { var bg: [CGColor]; var shadow, body, band, dome, spoon, leaf, vein: CGColor }
let palette: Palette = {
    switch variant {
    case "dark":   // deep plum background, same colorful pint
        return Palette(bg: [rgb(70, 26, 58), rgb(30, 12, 34)], shadow: rgb(0, 0, 0, 0.35), body: rgb(242, 238, 244),
                       band: rgb(232, 93, 144), dome: rgb(255, 228, 214), spoon: rgb(178, 150, 230), leaf: rgb(72, 199, 106), vein: rgb(225, 245, 230))
    case "tinted": // grayscale on black: the system uses luminance as the glyph for Tinted/Clear
        return Palette(bg: [rgb(0, 0, 0), rgb(0, 0, 0)], shadow: rgb(0, 0, 0, 0), body: rgb(255, 255, 255),
                       band: rgb(120, 120, 120), dome: rgb(200, 200, 200), spoon: rgb(170, 170, 170), leaf: rgb(255, 255, 255), vein: rgb(120, 120, 120))
    default:       // light: pink → coral (accent #E85D90)
        return Palette(bg: [rgb(255, 138, 128), rgb(232, 93, 144)], shadow: rgb(120, 20, 60, 0.18), body: rgb(255, 255, 255),
                       band: rgb(255, 214, 226), dome: rgb(255, 240, 225), spoon: rgb(120, 92, 160), leaf: rgb(52, 168, 83), vein: rgb(225, 245, 230))
    }
}()
let bg = CGGradient(colorsSpace: cs, colors: palette.bg as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

// Soft shadow under the pint.
ctx.setFillColor(palette.shadow)
ctx.fillEllipse(in: CGRect(x: 262, y: 150, width: 500, height: 70))

// Pint body: slightly tapered cup.
let body = CGMutablePath()
body.move(to: CGPoint(x: 300, y: 690))
body.addLine(to: CGPoint(x: 724, y: 690))
body.addLine(to: CGPoint(x: 690, y: 210))
body.addQuadCurve(to: CGPoint(x: 334, y: 210), control: CGPoint(x: 512, y: 180))
body.closeSubpath()
ctx.addPath(body)
ctx.setFillColor(palette.body)
ctx.fillPath()

// Label band.
ctx.saveGState()
ctx.addPath(body)
ctx.clip()
ctx.setFillColor(palette.band)
ctx.fill(CGRect(x: 0, y: 360, width: 1024, height: 150))
ctx.restoreGState()

// Ice cream dome peeking over the rim, then the rim.
ctx.setFillColor(palette.dome)
ctx.fillEllipse(in: CGRect(x: 318, y: 640, width: 388, height: 120))
let lid = CGPath(roundedRect: CGRect(x: 280, y: 668, width: 464, height: 56), cornerWidth: 28, cornerHeight: 28, transform: nil)
ctx.addPath(lid)
ctx.setFillColor(palette.body)
ctx.fillPath()

// Spoon: handle + bowl, tilted, stuck into the pint.
ctx.saveGState()
ctx.translateBy(x: 600, y: 700)
ctx.rotate(by: -0.45)
ctx.setFillColor(palette.spoon)
ctx.addPath(CGPath(roundedRect: CGRect(x: -22, y: 40, width: 44, height: 250), cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.fillPath()
ctx.fillEllipse(in: CGRect(x: -58, y: -40, width: 116, height: 150))
ctx.restoreGState()

// Leaf on the label band.
ctx.saveGState()
ctx.translateBy(x: 512, y: 435)
ctx.rotate(by: 0.6)
let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 0, y: -70))
leaf.addQuadCurve(to: CGPoint(x: 0, y: 70), control: CGPoint(x: 75, y: 0))
leaf.addQuadCurve(to: CGPoint(x: 0, y: -70), control: CGPoint(x: -75, y: 0))
ctx.addPath(leaf)
ctx.setFillColor(palette.leaf)
ctx.fillPath()
ctx.setStrokeColor(palette.vein)
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: 0, y: -62))
ctx.addLine(to: CGPoint(x: 0, y: 62))
ctx.strokePath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
