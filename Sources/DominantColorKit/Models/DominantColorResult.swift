import simd

/// The result of a dominant-colour extraction pass.
///
/// All colours are **gamma-encoded sRGB** (the values you'd write as `#RRGGBB / 255`),
/// components in `[0, 1]`. Do NOT apply a gamma curve before display.
public struct DominantColorResult: Sendable {
    /// The 5 most dominant colours sorted by descending pixel coverage.
    public let colors: [SIMD3<Float>]

    /// The most dominant colour (alias for `colors[0]`).
    public let primary: SIMD3<Float>

    /// The second-most dominant colour (alias for `colors[1]`).
    public let secondary: SIMD3<Float>

    /// 3 gradient stops suitable for a Spotify-style vertical background.
    ///
    /// - `[0]` — primary colour (top)
    /// - `[1]` — secondary colour (middle)
    /// - `[2]` — perceptually darkened primary (bottom)
    public let gradientStops: [SIMD3<Float>]
}
