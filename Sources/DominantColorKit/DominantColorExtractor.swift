import Metal
import CoreGraphics
import simd

#if canImport(UIKit)
import UIKit
#endif

/// Extracts a 5-colour dominant palette from an image entirely on the GPU.
///
/// ## Pipeline
/// 1. **Downscale** — bilinear downsample to 128×128 via a Metal compute kernel.
/// 2. **Histogram** — 3-D RGB histogram (16×16×16 = 4 096 bins) built with
///    atomic increments in threadgroup memory, then flushed to device memory.
/// 3. **Select** — CPU reads the 4 096-bin histogram (~16 KiB), scores each
///    bin by `count × saturation_weight`, and greedily picks 5 diverse colours
///    with a minimum-distance constraint so the palette has variety.
/// 4. **Gradient** — 3-stop Spotify-style gradient computed from top 2 colours.
///
/// GPU work (downscale + histogram) is encoded into **one command buffer**.
/// The CPU selection pass over 4 096 bins is negligible (~0.01 ms).
public final class DominantColorExtractor: @unchecked Sendable {

    // MARK: - Constants

    private static let downscaleSize = 128
    private static let binsPerAxis: UInt32 = 16
    private static let totalBins: Int = 16 * 16 * 16  // 4 096
    private static let topK = 5

    // MARK: - Metal objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let downsamplePSO: MTLComputePipelineState
    private let histogramPSO: MTLComputePipelineState

    // MARK: - Reusable buffers

    /// Histogram buffer: 4 096 × `uint32` = 16 KiB.
    private let histogramBuffer: MTLBuffer

    // MARK: - Init

    /// Create a new extractor.
    ///
    /// - Parameter device: The `MTLDevice` to use. Defaults to the system
    ///   default device.
    /// - Throws: If Metal is unavailable or shader compilation fails.
    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw DominantColorError.metalUnavailable
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw DominantColorError.metalUnavailable
        }
        self.commandQueue = queue

        let library = try Self.loadLibrary(device: device)

        guard let downsampleFn = library.makeFunction(name: "downsample"),
              let histogramFn  = library.makeFunction(name: "buildHistogram") else {
            throw DominantColorError.functionNotFound
        }

        self.downsamplePSO = try device.makeComputePipelineState(function: downsampleFn)
        self.histogramPSO  = try device.makeComputePipelineState(function: histogramFn)

        let histBytes = Self.totalBins * MemoryLayout<UInt32>.size
        guard let histBuf = device.makeBuffer(length: histBytes, options: .storageModeShared) else {
            throw DominantColorError.bufferAllocationFailed
        }
        self.histogramBuffer = histBuf
    }

    // MARK: - Public API

    /// Extract dominant colours from a `MTLTexture`.
    ///
    /// The texture can be any size; it will be downscaled internally.
    ///
    /// - Parameter texture: The source texture (`.rgba8Unorm` recommended).
    /// - Returns: A ``DominantColorResult`` with 5 colours and gradient stops.
    public func extract(from texture: MTLTexture) async throws -> DominantColorResult {
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DominantColorError.commandBufferCreationFailed
        }

        // 1. Downscale
        let downscaled = try makeDownscaleTexture()
        encodeDownscale(commandBuffer: commandBuffer, source: texture, destination: downscaled)

        // 2. Histogram
        encodeHistogram(commandBuffer: commandBuffer, texture: downscaled)

        // Register the completion handler BEFORE commit so it is never missed.
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { [histogramBuffer] _ in
                let result = Self.selectPalette(histogramBuffer: histogramBuffer)
                continuation.resume(returning: result)
            }
            commandBuffer.commit()
        }
    }

    #if canImport(UIKit)
    /// Convenience: extract from a `UIImage`.
    public func extract(from image: UIImage) async throws -> DominantColorResult {
        let texture = try loadTexture(from: image)
        return try await extract(from: texture)
    }
    #endif

    /// Convenience: extract from a `CGImage`.
    public func extract(from cgImage: CGImage) async throws -> DominantColorResult {
        let texture = try loadTexture(from: cgImage)
        return try await extract(from: texture)
    }

    /// Convenience: extract from a `CVPixelBuffer`.
    public func extract(from pixelBuffer: CVPixelBuffer) async throws -> DominantColorResult {
        let texture = try createTexture(from: pixelBuffer)
        return try await extract(from: texture)
    }

    // MARK: - Encoding helpers

    private func encodeDownscale(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(downsamplePSO)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)

        let w = destination.width
        let h = destination.height
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width:  (w + 15) / 16,
            height: (h + 15) / 16,
            depth:  1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    private func encodeHistogram(
        commandBuffer: MTLCommandBuffer,
        texture: MTLTexture
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(histogramPSO)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(histogramBuffer, offset: 0, index: 0)

        let localHistBytes = Self.totalBins * MemoryLayout<UInt32>.size  // 16 KiB
        encoder.setThreadgroupMemoryLength(localHistBytes, index: 0)

        let w = texture.width
        let h = texture.height
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let tgCount = MTLSize(
            width:  (w + 15) / 16,
            height: (h + 15) / 16,
            depth:  1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()
    }

    // MARK: - Texture helpers

    private func makeDownscaleTexture() throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Self.downscaleSize,
            height: Self.downscaleSize,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw DominantColorError.textureCreationFailed
        }
        return tex
    }

    #if canImport(UIKit)
    private func loadTexture(from image: UIImage) throws -> MTLTexture {
        guard let cgImage = image.cgImage else {
            throw DominantColorError.invalidImage
        }
        return try loadTexture(from: cgImage)
    }
    #endif

    /// Load a CGImage into an `rgba8Unorm` shared texture by rasterising
    /// through a CGContext with an explicit sRGB colour space.
    ///
    /// This avoids MTKTextureLoader which linearises sRGB data when
    /// creating non-sRGB textures, shifting all histogram bins dark.
    private func loadTexture(from cgImage: CGImage) throws -> MTLTexture {
        let width  = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DominantColorError.invalidImage
        }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                       | CGBitmapInfo.byteOrder32Big.rawValue

        let data = UnsafeMutableRawPointer.allocate(
            byteCount: height * bytesPerRow,
            alignment: 16
        )
        defer { data.deallocate() }

        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw DominantColorError.invalidImage
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw DominantColorError.textureCreationFailed
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    private func createTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw DominantColorError.textureCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DominantColorError.invalidImage
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    // MARK: - Smart palette selection (CPU, ~0.01 ms on 4 096 bins)

    /// Score each non-empty histogram bin and greedily select 5 diverse colours.
    private static func selectPalette(histogramBuffer: MTLBuffer) -> DominantColorResult {
        let histPtr = histogramBuffer.contents()
            .bindMemory(to: UInt32.self, capacity: totalBins)

        // Build scored list of non-empty bins.
        struct ScoredBin: Comparable {
            let color: SIMD3<Float>
            let score: Float
            static func < (lhs: ScoredBin, rhs: ScoredBin) -> Bool {
                lhs.score < rhs.score
            }
        }

        var bins: [ScoredBin] = []
        bins.reserveCapacity(512)

        for i in 0..<totalBins {
            let count = histPtr[i]
            guard count > 0 else { continue }

            let color = binToRGB(UInt32(i))
            let weight = colorWeight(color)
            let score = Float(count) * weight
            bins.append(ScoredBin(color: color, score: score))
        }

        // Descending by score.
        bins.sort(by: >)

        // Greedy diverse selection: each pick must be at least `minDist`
        // from every already-chosen colour.
        var selected: [SIMD3<Float>] = []
        selected.reserveCapacity(topK)
        let minDist: Float = 0.15

        for bin in bins {
            guard selected.count < topK else { break }
            let tooClose = selected.contains { simd_distance($0, bin.color) < minDist }
            if !tooClose {
                selected.append(bin.color)
            }
        }

        // If strict distance left gaps, fill with next-best that aren't duplicates.
        if selected.count < topK {
            for bin in bins {
                guard selected.count < topK else { break }
                let duplicate = selected.contains { simd_distance($0, bin.color) < 0.001 }
                if !duplicate {
                    selected.append(bin.color)
                }
            }
        }

        // Final fallback.
        while selected.count < topK {
            selected.append(SIMD3<Float>(0, 0, 0))
        }

        let primary   = selected[0]
        let secondary = selected[1]
        let stops     = GradientGenerator.makeStops(primary: primary, secondary: secondary)

        return DominantColorResult(
            colors: selected,
            primary: primary,
            secondary: secondary,
            gradientStops: stops
        )
    }

    /// Compute a perceptual weight for a bin colour.
    ///
    /// - Near-white (bright + desaturated): heavy penalty
    /// - Near-black: heavy penalty
    /// - Grays: moderate penalty
    /// - Saturated colours: boosted
    private static func colorWeight(_ c: SIMD3<Float>) -> Float {
        let maxC = max(c.x, c.y, c.z)
        let minC = min(c.x, c.y, c.z)
        let saturation: Float = maxC > 0.001 ? (maxC - minC) / maxC : 0

        var w: Float = 1.0

        // Near-black.
        if maxC < 0.08 {
            w *= 0.1
        }

        // Near-white (bright AND desaturated).
        if maxC > 0.75 && saturation < 0.15 {
            w *= 0.2
        }

        // Overall gray penalty.
        if saturation < 0.08 {
            w *= 0.3
        }

        // Saturation boost — vivid colours score up to 4× over neutrals.
        w *= (1.0 + saturation * 3.0)

        return w
    }

    // MARK: - Bin ↔ RGB conversion

    /// Convert a linear histogram bin index back to an RGB colour in [0, 1].
    private static func binToRGB(_ binIdx: UInt32) -> SIMD3<Float> {
        let bins = binsPerAxis
        let b = binIdx % bins
        let g = (binIdx / bins) % bins
        let r = binIdx / (bins * bins)

        return SIMD3<Float>(
            (Float(r) + 0.5) / Float(bins),
            (Float(g) + 0.5) / Float(bins),
            (Float(b) + 0.5) / Float(bins)
        )
    }

    // MARK: - Metal library loading

    private static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle.module.url(forResource: "default", withExtension: "metallib") else {
            throw DominantColorError.metalLibraryNotFound
        }
        return try device.makeLibrary(URL: url)
    }
}

// MARK: - Errors

/// Errors that can occur during colour extraction.
public enum DominantColorError: Error, CustomStringConvertible {
    case metalUnavailable
    case metalLibraryNotFound
    case functionNotFound
    case bufferAllocationFailed
    case textureCreationFailed
    case commandBufferCreationFailed
    case invalidImage

    public var description: String {
        switch self {
        case .metalUnavailable:            return "Metal is not available on this device."
        case .metalLibraryNotFound:        return "Could not locate the compiled Metal library."
        case .functionNotFound:            return "One or more Metal kernel functions were not found."
        case .bufferAllocationFailed:      return "Failed to allocate a Metal buffer."
        case .textureCreationFailed:       return "Failed to create a Metal texture."
        case .commandBufferCreationFailed: return "Failed to create a Metal command buffer."
        case .invalidImage:                return "The provided image could not be converted."
        }
    }
}
