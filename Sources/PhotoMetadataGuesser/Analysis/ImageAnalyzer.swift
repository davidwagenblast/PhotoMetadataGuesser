import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import DateGuessCore

/// On-device image analysis: color/border statistics, scene labels, face crops and JPEG encoding.
enum ImageAnalyzer {
    /// Downsamples and computes the color/border statistics used for era clues.
    static func statistics(_ image: CGImage) -> ImageStatistics? {
        let maxEdge = 192
        let scale = min(1, Double(maxEdge) / Double(max(image.width, image.height)))
        let w = max(16, Int(Double(image.width) * scale)), h = max(16, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return ImageStatistics.compute(rgba: pixels, width: w, height: h)
    }

    /// Vision scene classification labels with confidence.
    static func sceneLabels(_ image: CGImage) -> [(identifier: String, confidence: Double)] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? [])
            .filter { $0.confidence >= 0.2 }
            .prefix(25)
            .map { ($0.identifier, Double($0.confidence)) }
    }

    /// Crops to the largest face (with room for hair and shoulders), or returns the whole image.
    static func largestFaceCrop(_ image: CGImage) -> CGImage {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let face = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return image
        }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        let box = face.boundingBox
        // Vision's origin is bottom-left; CGImage cropping uses top-left.
        let faceRect = CGRect(x: box.minX * W, y: (1 - box.maxY) * H, width: box.width * W, height: box.height * H)
        let side = max(faceRect.width, faceRect.height) * 2.4
        var crop = CGRect(x: faceRect.midX - side / 2, y: faceRect.midY - side / 2, width: side, height: side)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
        return image.cropping(to: crop) ?? image
    }

    /// JPEG data scaled so the long edge is at most `maxEdge`.
    static func jpegData(_ image: CGImage, maxEdge: Int, quality: Double = 0.82) -> Data? {
        let scaled = resized(image, maxEdge: maxEdge) ?? image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func resized(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxEdge else { return image }
        let scale = Double(maxEdge) / Double(longEdge)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
