# DominantColorKit instructions

Swift Package Manager package for GPU-accelerated dominant-color extraction using Metal. It supports iOS 16+ and macOS 13+ and exposes async/await APIs for `UIImage`, `CGImage`, `CVPixelBuffer`, and `MTLTexture` inputs.

Keep the GPU downscale/histogram pipeline and the CPU perceptual palette-selection boundary intact. Metal resources are part of the package target; changes must preserve resource processing in `Package.swift` and be tested on a supported Apple target.

```bash
swift build
swift test
```
