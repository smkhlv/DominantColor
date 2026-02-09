#include <metal_stdlib>
using namespace metal;

/// Number of bits used per channel for quantisation.
constant uint kBitsPerChannel = 4;
/// Bins per axis: 2^4 = 16.
constant uint kBinsPerAxis    = 1 << kBitsPerChannel;
/// Total histogram size: 16 × 16 × 16 = 4 096 bins.
constant uint kTotalBins      = kBinsPerAxis * kBinsPerAxis * kBinsPerAxis;

/// Build a 3-D RGB histogram from the downscaled texture.
///
/// Each thread reads one pixel, quantises it to 5 bits per channel, computes
/// a linear bin index (R * 32*32 + G * 32 + B), and atomically increments
/// the corresponding counter.
///
/// Two-level accumulation:
///   1. Threadgroup-shared histogram (zero-initialised at dispatch start).
///   2. After the barrier, each thread writes its local bin to the global
///      histogram via `atomic_fetch_add_explicit`.
kernel void buildHistogram(
    texture2d<float, access::read>            inTexture   [[texture(0)]],
    device atomic_uint*                       histogram   [[buffer(0)]],
    threadgroup atomic_uint*                  localHist   [[threadgroup(0)]],
    uint2                                     gid         [[thread_position_in_grid]],
    uint2                                     lid2        [[thread_position_in_threadgroup]],
    uint2                                     tgDim       [[threads_per_threadgroup]])
{
    // Compute linear thread index and threadgroup size from 2-D values.
    uint lid    = lid2.y * tgDim.x + lid2.x;
    uint tgSize = tgDim.x * tgDim.y;

    // --- Zero the threadgroup histogram ---
    for (uint i = lid; i < kTotalBins; i += tgSize) {
        atomic_store_explicit(&localHist[i], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // --- Accumulate into threadgroup histogram ---
    uint w = inTexture.get_width();
    uint h = inTexture.get_height();

    if (gid.x < w && gid.y < h) {
        float4 px = inTexture.read(gid);

        // Quantise each channel to 4 bits (0..15).
        uint rBin = min(uint(px.r * float(kBinsPerAxis)), kBinsPerAxis - 1);
        uint gBin = min(uint(px.g * float(kBinsPerAxis)), kBinsPerAxis - 1);
        uint bBin = min(uint(px.b * float(kBinsPerAxis)), kBinsPerAxis - 1);

        uint binIdx = rBin * kBinsPerAxis * kBinsPerAxis + gBin * kBinsPerAxis + bBin;

        atomic_fetch_add_explicit(&localHist[binIdx], 1, memory_order_relaxed);
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    // --- Flush non-zero bins to global histogram ---
    for (uint i = lid; i < kTotalBins; i += tgSize) {
        uint count = atomic_load_explicit(&localHist[i], memory_order_relaxed);
        if (count > 0) {
            atomic_fetch_add_explicit(&histogram[i], count, memory_order_relaxed);
        }
    }
}
