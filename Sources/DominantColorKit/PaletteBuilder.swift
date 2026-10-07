import simd

/// Pure palette builder over an 8-bit RGBA (premultiplied-last, sRGB) buffer.
/// Histogram is 16³ bins storing count AND summed color, so every palette entry is the
/// mean of the real pixels in its bin — not the bin center.
enum PaletteBuilder {
    static let binsPerAxis = 16
    static let totalBins = binsPerAxis * binsPerAxis * binsPerAxis
    static let topK = 5
    static let alphaThreshold: UInt8 = 128

    /// `nil` when the buffer has no opaque pixels.
    static func build(rgba: [UInt8]) -> DominantColorResult? {
        var counts = [UInt32](repeating: 0, count: totalBins)
        var sums = [SIMD3<Float>](repeating: .zero, count: totalBins)

        var i = 0
        while i + 3 < rgba.count {
            let a = rgba[i + 3]
            if a >= alphaThreshold {
                let alpha = Float(a) / 255
                let raw = SIMD3<Float>(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255
                let color = simd_clamp(raw / alpha, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                let bin = binIndex(color)
                counts[bin] += 1
                sums[bin] += color
            }
            i += 4
        }

        struct Scored { let color: SIMD3<Float>; let score: Float }
        var bins: [Scored] = []
        bins.reserveCapacity(512)
        for b in 0..<totalBins where counts[b] > 0 {
            let mean = sums[b] / Float(counts[b])
            bins.append(Scored(color: mean, score: Float(counts[b]) * colorWeight(mean)))
        }
        guard !bins.isEmpty else { return nil }
        bins.sort { $0.score > $1.score }

        // Greedy diverse selection (unchanged rule): each pick ≥ 0.15 from every chosen color.
        var selected: [SIMD3<Float>] = []
        for bin in bins where selected.count < topK {
            if !selected.contains(where: { simd_distance($0, bin.color) < 0.15 }) {
                selected.append(bin.color)
            }
        }
        // Then fill with next-best non-duplicates.
        for bin in bins where selected.count < topK {
            if !selected.contains(where: { simd_distance($0, bin.color) < 0.001 }) {
                selected.append(bin.color)
            }
        }
        // Pad with the primary — never invent black.
        while selected.count < topK { selected.append(selected[0]) }

        let primary = selected[0]
        let secondary = selected[1]
        return DominantColorResult(
            colors: selected,
            primary: primary,
            secondary: secondary,
            gradientStops: GradientGenerator.makeStops(primary: primary, secondary: secondary)
        )
    }

    static func binIndex(_ c: SIMD3<Float>) -> Int {
        let n = Float(binsPerAxis)
        let r = min(Int(c.x * n), binsPerAxis - 1)
        let g = min(Int(c.y * n), binsPerAxis - 1)
        let b = min(Int(c.z * n), binsPerAxis - 1)
        return r * binsPerAxis * binsPerAxis + g * binsPerAxis + b
    }

    /// Perceptual weight (unchanged from the Metal version): penalize near-black,
    /// near-white and grays; boost saturation up to 4×.
    static func colorWeight(_ c: SIMD3<Float>) -> Float {
        let maxC = max(c.x, c.y, c.z)
        let minC = min(c.x, c.y, c.z)
        let saturation: Float = maxC > 0.001 ? (maxC - minC) / maxC : 0
        var w: Float = 1.0
        if maxC < 0.08 { w *= 0.1 }
        if maxC > 0.75 && saturation < 0.15 { w *= 0.2 }
        if saturation < 0.08 { w *= 0.3 }
        w *= (1.0 + saturation * 3.0)
        return w
    }
}
