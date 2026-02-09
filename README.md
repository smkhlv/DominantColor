# DominantColorKit

GPU-accelerated dominant color extraction for iOS. Builds a 3D RGB histogram on the GPU via Metal compute shaders and selects a perceptually diverse 5-color palette with Spotify-style gradient generation.

## Features

- Full GPU pipeline: downscale + histogram in a single Metal command buffer
- Perceptual palette selection: saturation-weighted scoring with minimum-distance diversity constraint
- Spotify-style 3-stop vertical gradient from extracted colors
- Accepts `UIImage`, `CGImage`, `CVPixelBuffer`, or `MTLTexture`
- async/await API
- iOS 16+, Swift 5.9+

## Installation

Add via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/<you>/DominantColor.git", from: "1.0.0")
]
```

Or in Xcode: File > Add Package Dependencies, paste the repository URL.

## Usage

```swift
import DominantColorKit

let extractor = try DominantColorExtractor()
let result = try await extractor.extract(from: image)

// 5 dominant colors sorted by perceptual relevance
result.colors     // [SIMD3<Float>]
result.primary    // most dominant
result.secondary  // second most dominant

// Spotify-style gradient stops (top, middle, bottom)
result.gradientStops  // [SIMD3<Float>]
```

## Architecture

```
Input image
    |
    v
[GPU] Downscale (bilinear, 128x128)
    |
    v
[GPU] 3D Histogram (16^3 = 4096 bins, threadgroup atomics)
    |
    v
[CPU] Weighted diverse selection (4096 bins, ~0.01 ms)
    |
    v
DominantColorResult { colors, primary, secondary, gradientStops }
```

### Why hybrid GPU + CPU?

The histogram is the heavy part: 16K pixels with atomic increments across threadgroup-shared memory. Metal handles this in parallel across all GPU cores.

The palette selection over 4,096 bins is inherently sequential (each pick depends on previous picks for diversity). CPU processes this in ~0.01 ms, faster than the Metal kernel launch overhead alone.

### Palette selection algorithm

1. **Score** each bin: `count * weight(color)`
   - Near-black (brightness < 0.08): 0.1x penalty
   - Near-white (brightness > 0.75, saturation < 0.15): 0.2x penalty
   - Grays (saturation < 0.08): 0.3x penalty
   - Saturation boost: up to 4x for fully saturated colors
2. **Sort** bins by score descending
3. **Greedy pick**: select top scorer, then for each next pick require Euclidean RGB distance >= 0.15 from all already-chosen colors

This prevents palettes filled with 5 shades of white/gray and favors visually interesting, diverse colors.

## Project structure

```
DominantColor/
  Package.swift
  Sources/DominantColorKit/
    DominantColorExtractor.swift    # Main API, Metal pipeline orchestration
    GradientGenerator.swift         # Spotify-style 3-stop gradient
    Models/
      DominantColorResult.swift     # Output struct
    Metal/
      Downscale.metal               # Bilinear downsample compute kernel
      Histogram.metal               # 3D RGB histogram with threadgroup atomics
      ReduceTopColors.metal         # GPU top-K reduction (available, unused)
  Example/
    DominantColor.xcodeproj
    DominantColor/                  # SwiftUI demo app
```

## Example app

Open `Example/DominantColor.xcodeproj` in Xcode. The app demonstrates:

- Image selection via PhotosPicker
- Extracted 5-color palette display
- Fullscreen animated gradient background
- Extraction time measurement in milliseconds

## Performance

| Stage | Device | Time |
|-------|--------|------|
| GPU downscale + histogram | iPhone (simulator) | 50-200 ms |
| CPU palette selection | any | ~0.01 ms |

Real device performance is significantly better than simulator. Metal compute on A-series/M-series chips typically completes the full pipeline in under 10 ms.

## Metal shader details

**Downscale.metal** — Bilinear downsample using hardware texture sampler. Maps each destination pixel to normalized source coordinates for quality interpolation at any scale ratio.

**Histogram.metal** — Two-level atomic accumulation. Each 16x16 threadgroup zeros a local 4,096-bin histogram in shared memory, accumulates pixel contributions with `atomic_fetch_add`, then flushes non-zero bins to the global device buffer. This minimizes contention on device memory.

**ReduceTopColors.metal** — Single-threadgroup parallel top-5 scan. Available in the metallib but currently unused in favor of the CPU-side weighted selection which produces better perceptual results.

## Memory footprint

| Resource | Size |
|----------|------|
| Histogram buffer | 16 KiB |
| Downscale texture (128x128 RGBA) | 64 KiB |
| Source texture (shared, temporary) | varies |
| **Total pipeline overhead** | **~80 KiB** |

## License

MIT
