import Foundation
import simd

/// Tinted text colour that keeps the background's hue and reaches WCAG AA (≥ 4.5:1).
///
/// Works in OKLCH (perceptually even lightness, hue-stable). Inputs/outputs are
/// gamma-encoded sRGB in [0, 1].
public enum ContrastText {
    public static let minimumRatio: Float = 4.5
    /// Search target with headroom for `#RRGGBB` rounding.
    static let searchRatio: Double = 4.6
    static let chromaCap = 0.06
    static let lightStartL = 0.96
    static let darkStartL = 0.26
    static let neutralChroma = 0.02

    public static func color(on background: SIMD3<Float>) -> SIMD3<Float> {
        let bg = SIMD3<Double>(background)
        let bgY = luminance(bg)
        let white = SIMD3<Double>(repeating: 1), black = SIMD3<Double>(repeating: 0)
        let light = ratio(luminance(white), bgY) >= ratio(luminance(black), bgY)

        let bgLCH = OKLCH(srgbDouble: bg)
        let chroma = bgLCH.c < neutralChroma ? 0 : min(bgLCH.c, chromaCap)
        let hue = bgLCH.h

        func candidate(_ l: Double) -> SIMD3<Double> { gamutMapped(l: l, c: chroma, h: hue) }
        func meets(_ l: Double) -> Bool { ratio(luminance(candidate(l)), bgY) >= searchRatio }

        let start = light ? lightStartL : darkStartL
        let edge: Double = light ? 1 : 0
        if meets(start) { return SIMD3<Float>(candidate(start)) }
        // Even the extreme can't reach 4.6 → pure white/black (always ≥ 4.58 by WCAG math).
        guard meets(edge) else { return SIMD3<Float>(light ? white : black) }

        // Binary search for the lightness closest to `start` that still meets the target.
        var failing = start, passing = edge
        for _ in 0..<24 {
            let mid = (failing + passing) / 2
            if meets(mid) { passing = mid } else { failing = mid }
        }
        return SIMD3<Float>(candidate(passing))
    }

    /// WCAG 2.x contrast ratio between two gamma-encoded sRGB colours.
    public static func contrastRatio(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        Float(ratio(luminance(SIMD3<Double>(a)), luminance(SIMD3<Double>(b))))
    }

    // MARK: - Internals

    static func ratio(_ y1: Double, _ y2: Double) -> Double {
        (max(y1, y2) + 0.05) / (min(y1, y2) + 0.05)
    }

    static func luminance(_ srgb: SIMD3<Double>) -> Double {
        let l = OKLCH.linearize(srgb)
        return 0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z
    }

    /// Reduce chroma (binary search) until the colour fits in sRGB; then clamp.
    static func gamutMapped(l: Double, c: Double, h: Double) -> SIMD3<Double> {
        func linear(_ c: Double) -> SIMD3<Double> { OKLCH.toLinear(l: l, c: c, h: h) }
        func inGamut(_ v: SIMD3<Double>) -> Bool {
            v.min() >= -1e-6 && v.max() <= 1 + 1e-6
        }
        var chroma = c
        if !inGamut(linear(chroma)) {
            var lo = 0.0, hi = c
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if inGamut(linear(mid)) { lo = mid } else { hi = mid }
            }
            chroma = lo
        }
        let lin = simd_clamp(linear(chroma), SIMD3<Double>(repeating: 0), SIMD3<Double>(repeating: 1))
        return OKLCH.encode(lin)
    }
}

/// OKLCH (Björn Ottosson's OKLab in polar form). `h` in degrees [0, 360).
struct OKLCH {
    let l: Double, c: Double, h: Double

    init(srgb: SIMD3<Float>) { self.init(srgbDouble: SIMD3<Double>(srgb)) }

    init(srgbDouble srgb: SIMD3<Double>) {
        let lin = Self.linearize(srgb)
        let lms = SIMD3<Double>(
            0.4122214708 * lin.x + 0.5363325363 * lin.y + 0.0514459929 * lin.z,
            0.2119034982 * lin.x + 0.6806995451 * lin.y + 0.1073969566 * lin.z,
            0.0883024619 * lin.x + 0.2817188376 * lin.y + 0.6299787005 * lin.z
        )
        let r = SIMD3<Double>(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        let L = 0.2104542553 * r.x + 0.7936177850 * r.y - 0.0040720468 * r.z
        let a = 1.9779984951 * r.x - 2.4285922050 * r.y + 0.4505937099 * r.z
        let b = 0.0259040371 * r.x + 0.7827717662 * r.y - 0.8086757660 * r.z
        l = L
        c = (a * a + b * b).squareRoot()
        var hue = atan2(b, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        h = hue
    }

    static func toLinear(l: Double, c: Double, h: Double) -> SIMD3<Double> {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        return SIMD3<Double>(
             4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S,
            -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S,
            -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        )
    }

    static func linearize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return SIMD3(f(v.x), f(v.y), f(v.z))
    }

    static func encode(_ v: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return SIMD3(f(v.x), f(v.y), f(v.z))
    }
}
