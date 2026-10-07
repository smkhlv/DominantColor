import Testing
import Foundation
import simd
@testable import DominantColorKit

struct ContrastTextTests {
    /// Round to 8-bit like `#RRGGBB` does on the wire.
    static func quantize(_ c: SIMD3<Float>) -> SIMD3<Float> { (c * 255).rounded(.toNearestOrAwayFromZero) / 255 }

    static func hex(_ v: UInt32) -> SIMD3<Float> {
        SIMD3(Float((v >> 16) & 0xFF), Float((v >> 8) & 0xFF), Float(v & 0xFF)) / 255
    }

    struct SplitMix { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    }

    @Test("10 000 random backgrounds: contrast ≥ 4.5 after 8-bit rounding")
    func contrastAlwaysAA() {
        var rng = SplitMix(s: 42)
        for _ in 0..<10_000 {
            let bg = Self.hex(UInt32(truncatingIfNeeded: rng.next()) & 0xFFFFFF)
            let text = Self.quantize(ContrastText.color(on: bg))
            let ratio = ContrastText.contrastRatio(text, bg)
            #expect(ratio >= 4.5, "bg \(bg) text \(text) ratio \(ratio)")
        }
    }

    @Test("Hue is preserved (±10°) whenever the text is chromatic")
    func huePreserved() {
        var rng = SplitMix(s: 7)
        for _ in 0..<2_000 {
            let bg = Self.hex(UInt32(truncatingIfNeeded: rng.next()) & 0xFFFFFF)
            let text = ContrastText.color(on: bg)
            let t = OKLCH(srgb: text), b = OKLCH(srgb: bg)
            guard t.c > 0.02, b.c >= 0.02 else { continue }
            var d = abs(t.h - b.h).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            #expect(d <= 10, "bg \(bg) text \(text) Δh \(d)")
        }
    }

    @Test("Deterministic")
    func deterministic() {
        let bg = Self.hex(0x3A7BD5)
        #expect(ContrastText.color(on: bg) == ContrastText.color(on: bg))
    }

    @Test("Dark navy → light, bluish text")
    func navy() {
        let text = ContrastText.color(on: Self.hex(0x1A2B3C))
        #expect(OKLCH(srgb: text).l > 0.8)
        #expect(text.z > text.x)
    }

    @Test("Saturated yellow → dark, warm (olive) text")
    func yellow() {
        let text = ContrastText.color(on: Self.hex(0xFFD60A))
        #expect(OKLCH(srgb: text).l < 0.45)
        #expect(text.x > text.z && text.y > text.z)
    }

    @Test("Neutral gray → achromatic text")
    func gray() {
        let text = ContrastText.color(on: Self.hex(0x777777))
        #expect(abs(text.x - text.y) < 0.004 && abs(text.y - text.z) < 0.004)
    }

    @Test("Palette result carries textColor computed from primary")
    func resultCarriesTextColor() async throws {
        let navy = TestImages.RGB(r: 0x1A, g: 0x2B, b: 0x3C)
        let result = try await DominantColorExtractor().extract(from: TestImages.solid(navy))
        #expect(result.textColor == ContrastText.color(on: result.primary))
    }
}
