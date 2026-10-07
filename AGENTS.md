# DominantColorKit instructions

Swift Package Manager package for dominant-color extraction on the CPU via ImageIO thumbnails and a 16³ histogram. Supports iOS 16+ and macOS 13+; async APIs for `Data`, `CGImage` and `UIImage`. Also provides `ContrastText` (tinted WCAG-AA text color).

All colors are gamma-encoded sRGB in [0, 1]. The extractor is a stateless `Sendable` struct; keep it that way. Tests run on the iOS simulator: `xcodebuild test -scheme DominantColorKit -destination <sim>`.
