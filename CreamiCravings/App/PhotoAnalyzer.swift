import Foundation
#if os(iOS)
import UIKit
import Vision
import ImageIO
import AVFoundation

/// Measures a saved progress photo on the phone (Vision landmarks + the pure math in MetricsEngine). Nothing leaves the device.
/// Call from a background task: it decodes the photo and runs Vision.
enum PhotoAnalyzer {
    /// The photo is analysed at this long edge; the spot sizes in MetricsEngine are in pixels at this scale.
    static let longEdge = 768

    static func analyze(photo: URL, series: PhotoSeries, hairMatte: URL?, skinMatte: URL?) -> PhotoMetrics? {
        guard let src = CGImageSourceCreateWithURL(photo as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: longEdge]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary), let rgba = rgbaImage(cg) else { return nil }
        let w = cg.width, h = cg.height
        let hair = hairMatte.flatMap { grayMask($0, width: w, height: h) }
        let skin = skinMatte.flatMap { grayMask($0, width: w, height: h) }
        let face = series == .crown ? nil : faceGeometry(cg)
        return MetricsEngine.compute(series: series, image: rgba, face: face, hairMatte: hair, skinMatte: skin)
    }

    private static func rgbaImage(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBAImage(width: w, height: h, data: data) : nil
    }

    /// A matte PNG scaled to the analysed photo's size.
    private static func grayMask(_ url: URL, width w: Int, height h: Int) -> GrayMask? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var data = [UInt8](repeating: 0, count: w * h)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? GrayMask(width: w, height: h, data: data) : nil
    }

    /// The largest face's landmarks in pixel coordinates (top-left origin). nil when no face is found (also when Vision is unavailable).
    private static func faceGeometry(_ cg: CGImage) -> FaceGeometry? {
        let req = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, orientation: .up).perform([req])) != nil,
              let obs = (req.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              let lm = obs.landmarks else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) } ?? [] }
        func center(_ p: [CGPoint]) -> CGPoint? { p.isEmpty ? nil : CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)) }
        let eyes = [pts(lm.leftEye), pts(lm.rightEye)]
        guard let a = center(pts(lm.leftPupil)) ?? center(eyes[0]), let b = center(pts(lm.rightPupil)) ?? center(eyes[1]) else { return nil }
        let bb = obs.boundingBox
        let box = CGRect(x: bb.minX * size.width, y: (1 - bb.maxY) * size.height, width: bb.width * size.width, height: bb.height * size.height)
        let (l, r) = a.x <= b.x ? (a, b) : (b, a)
        return FaceGeometry(box: box, leftPupil: l, rightPupil: r, brows: [pts(lm.leftEyebrow), pts(lm.rightEyebrow)], eyes: eyes, lips: pts(lm.outerLips))
    }
}

/// Capture-time semantic segmentation mattes, saved as 8-bit grayscale PNG next to the photo.
enum MatteExport {
    static let types: [AVSemanticSegmentationMatte.MatteType] = [.hair, .skin]

    static func kind(_ t: AVSemanticSegmentationMatte.MatteType) -> String { t == .hair ? "hair" : "skin" }

    /// PNG data for one matte, rotated to match the photo's EXIF orientation. nil when the matte is missing or not 8-bit.
    static func png(from photo: AVCapturePhoto, type: AVSemanticSegmentationMatte.MatteType) -> Data? {
        guard var matte = photo.semanticSegmentationMatte(for: type) else { return nil }
        if let raw = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32, let o = CGImagePropertyOrientation(rawValue: raw) {
            matte = matte.applyingExifOrientation(o)
        }
        let pb = matte.mattingImage
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), stride = CVPixelBufferGetBytesPerRow(pb)
        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { memcpy(&bytes[y * w], base + y * stride, w) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
#endif
