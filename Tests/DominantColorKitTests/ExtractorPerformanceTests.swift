import XCTest
import UIKit
@testable import DominantColorKit

final class ExtractorPerformanceTests: XCTestCase {
    static let jpeg = TestImages.photoLikeJPEG()   // 12 MP, built once

    private var options: XCTMeasureOptions {
        let o = XCTMeasureOptions(); o.iterationCount = 10; return o
    }

    /// What the app does today: decode the full photo, then extract.
    func testDecodeThenExtractUIImage12MP() throws {
        let extractor = try makeExtractor()
        let data = Self.jpeg
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let done = expectation(description: "extract")
            Task {
                let image = UIImage(data: data)!
                _ = try await extractor.extract(from: image)
                done.fulfill()
            }
            wait(for: [done], timeout: 30)
        }
    }
}
