import Testing
import simd
@testable import DominantColorKit

/// Task 2 changes this to the non-throwing `DominantColorExtractor()`.
func makeExtractor() throws -> DominantColorExtractor { try DominantColorExtractor() }

struct ExtractorCorrectnessTests {
    static let navy = TestImages.RGB(r: 0x1A, g: 0x2B, b: 0x3C)
    static let red = TestImages.RGB(r: 0xD0, g: 0x20, b: 0x1A)
    static let lightGray = TestImages.RGB(r: 0xD8, g: 0xD8, b: 0xD8)

    @Test("Solid color comes back as itself (gamma-encoded sRGB, not a bin center)")
    func solidColorRoundTrips() async throws {
        let result = try await makeExtractor().extract(from: TestImages.solid(Self.navy))
        #expect(result.primary.maxChannelDelta255(Self.navy) <= 1.5)
    }

    @Test("A saturated object beats a larger neutral background")
    func saturatedObjectWins() async throws {
        let image = TestImages.split(background: Self.lightGray, object: Self.red, objectFraction: 0.3)
        let result = try await makeExtractor().extract(from: image)
        #expect(result.primary.maxChannelDelta255(Self.red) <= 1.5)
    }

    @Test("Transparent pixels never enter the palette")
    func transparentPixelsIgnored() async throws {
        let result = try await makeExtractor().extract(from: TestImages.halfTransparent(Self.red))
        for color in result.colors {
            #expect(color.maxChannelDelta255(Self.red) <= 1.5, "unexpected palette color \(color)")
        }
    }

    @Test("Concurrent extractions don't corrupt each other")
    func concurrentExtractionsAgree() async throws {
        let extractor = try makeExtractor()
        let image = TestImages.split(background: Self.lightGray, object: Self.red, objectFraction: 0.3)
        let reference = try await extractor.extract(from: image).primary
        let results = try await withThrowingTaskGroup(of: SIMD3<Float>.self) { group in
            for _ in 0..<50 { group.addTask { try await extractor.extract(from: image).primary } }
            return try await group.reduce(into: [SIMD3<Float>]()) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0 == reference })
    }
}
