import CoreGraphics
import Foundation
import ImageIO
import simd

#if canImport(UIKit)
import UIKit
#endif

/// Extracts a 5-colour dominant palette from an image on the CPU.
///
/// ## Pipeline
/// 1. **Thumbnail** — ImageIO decodes straight to ≤96 px on the long side
///    (JPEG/HEIC are subsampled during decode; the full image is never materialised).
/// 2. **Raster** — draw into an 8-bit sRGB RGBA buffer (~37 KB).
/// 3. **Histogram** — 16³ bins with per-bin colour sums; pixels with alpha < 50 % are skipped.
/// 4. **Select** — saturation-weighted score, greedy diverse pick of 5 colours.
///
/// Stateless and `Sendable`: concurrent calls are safe.
/// All colours are **gamma-encoded sRGB** in `[0, 1]`.
public struct DominantColorExtractor: Sendable {

    static let sampleMaxPixelSize = 96

    public init() {}

    // MARK: - Public API

    /// Preferred: encoded image bytes (JPEG/PNG/HEIC/WebP…). Never decodes at full size.
    public func extract(from data: Data) async throws -> DominantColorResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw DominantColorError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.sampleMaxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DominantColorError.invalidImage
        }
        return try Self.palette(from: thumbnail)
    }

    /// An already-decoded image; drawn down to ≤96 px.
    public func extract(from cgImage: CGImage) async throws -> DominantColorResult {
        try Self.palette(from: cgImage)
    }

    #if canImport(UIKit)
    public func extract(from image: UIImage) async throws -> DominantColorResult {
        guard let cgImage = image.cgImage else { throw DominantColorError.invalidImage }
        return try Self.palette(from: cgImage)
    }
    #endif

    // MARK: - Raster

    static func palette(from image: CGImage) throws -> DominantColorResult {
        let longSide = max(image.width, image.height)
        guard longSide > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DominantColorError.invalidImage
        }
        let scale = min(1, Double(sampleMaxPixelSize) / Double(longSide))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw DominantColorError.invalidImage }
        guard let result = PaletteBuilder.build(rgba: rgba) else {
            throw DominantColorError.noOpaquePixels
        }
        return result
    }
}

// MARK: - Errors

/// Errors that can occur during colour extraction.
public enum DominantColorError: Error, Equatable, CustomStringConvertible {
    case invalidImage
    case noOpaquePixels

    public var description: String {
        switch self {
        case .invalidImage:   return "The provided image could not be decoded."
        case .noOpaquePixels: return "The image has no opaque pixels."
        }
    }
}
