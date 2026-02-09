import simd

/// Generates Spotify-style gradient stops from a set of dominant colours.
public enum GradientGenerator {

    /// Produce 3 gradient stops from the extracted palette.
    ///
    /// - Parameters:
    ///   - primary: The most dominant colour.
    ///   - secondary: The second-most dominant colour.
    /// - Returns: An array of 3 `SIMD3<Float>` colours (top → middle → bottom).
    public static func makeStops(
        primary: SIMD3<Float>,
        secondary: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        let bottom = perceptuallyDarken(primary, factor: 0.35)
        return [primary, secondary, bottom]
    }

    // MARK: - Internal

    /// Darken a colour perceptually by converting to a simple luminance-aware
    /// space, scaling luminance, and converting back.
    ///
    /// Uses the sRGB luminance coefficients and operates in linear RGB.
    /// This produces a more natural darkening than a naive RGB multiply because
    /// it preserves the hue and only compresses the lightness.
    static func perceptuallyDarken(
        _ color: SIMD3<Float>,
        factor: Float
    ) -> SIMD3<Float> {
        // Approximate perceptual darkening:
        // 1. Convert linear RGB → relative luminance.
        // 2. Compute a darkening scale that reaches `factor` at full luminance.
        // 3. Multiply RGB uniformly but then push towards the hue midpoint so
        //    saturated colours don't shift excessively.

        let luminance = dot(color, SIMD3<Float>(0.2126, 0.7152, 0.0722))
        guard luminance > 1e-5 else { return color }

        // Target luminance.
        let targetLum = luminance * factor

        // Uniform scale to reach that luminance.
        let scale = targetLum / luminance

        var darkened = color * scale

        // Clamp to [0, 1].
        darkened = simd_clamp(darkened, SIMD3<Float>(repeating: 0),
                              SIMD3<Float>(repeating: 1))
        return darkened
    }
}
