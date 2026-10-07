import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Synthetic test images — no binary fixtures. All colors are 8-bit sRGB.
enum TestImages {
    struct RGB: Equatable { let r: UInt8, g: UInt8, b: UInt8 }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
    }

    static func cg(_ c: RGB, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: sRGB, components: [CGFloat(c.r) / 255, CGFloat(c.g) / 255, CGFloat(c.b) / 255, alpha])!
    }

    /// Single flat color.
    static func solid(_ c: RGB, size: Int = 256) -> CGImage {
        let ctx = context(width: size, height: size)
        ctx.setFillColor(cg(c))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    /// `background` everywhere except a centered square of `object` covering `objectFraction` of the area.
    static func split(background: RGB, object: RGB, objectFraction: Double, size: Int = 256) -> CGImage {
        let ctx = context(width: size, height: size)
        ctx.setFillColor(cg(background))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let side = Double(size) * objectFraction.squareRoot()
        let origin = (Double(size) - side) / 2
        ctx.setFillColor(cg(object))
        ctx.fill(CGRect(x: origin, y: origin, width: side, height: side))
        return ctx.makeImage()!
    }

    /// Left half fully transparent, right half opaque `c`.
    static func halfTransparent(_ c: RGB, size: Int = 256) -> CGImage {
        let ctx = context(width: size, height: size)
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(cg(c))
        ctx.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return ctx.makeImage()!
    }

    /// Photo-sized image with gradients + many rects, JPEG-encoded (q 0.9). Deterministic.
    static func photoLikeJPEG(width: Int = 4032, height: Int = 3024) -> Data {
        let ctx = context(width: width, height: height)
        let colors = [cg(RGB(r: 30, g: 60, b: 120)), cg(RGB(r: 220, g: 180, b: 60))] as CFArray
        let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var seed: UInt64 = 0x5EED
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        for _ in 0..<400 {
            let c = RGB(r: UInt8(next() % 256), g: UInt8(next() % 256), b: UInt8(next() % 256))
            ctx.setFillColor(cg(c))
            ctx.fill(CGRect(x: Int(next() % UInt64(width)), y: Int(next() % UInt64(height)),
                            width: Int(next() % 400) + 20, height: Int(next() % 400) + 20))
        }
        return encode(ctx.makeImage()!, type: .jpeg, quality: 0.9)
    }

    static func png(_ image: CGImage) -> Data { encode(image, type: .png, quality: 1) }

    private static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        return data as Data
    }
}

extension SIMD3 where Scalar == Float {
    /// Max per-channel distance in 8-bit units.
    func maxChannelDelta255(_ c: TestImages.RGB) -> Float {
        let target = SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b)) / 255
        let d = abs(self - target) * 255
        return Swift.max(d.x, d.y, d.z)
    }
}
