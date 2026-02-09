#include <metal_stdlib>
using namespace metal;

/// Must match the histogram parameters in Histogram.metal.
constant uint kBins  = 16;
constant uint kTotal = kBins * kBins * kBins; // 4 096
constant uint kTopK  = 5;

struct Entry {
    uint count;
    uint binIdx;
};

/// Insert `e` into a descending-sorted array of length kTopK.
inline void insertSorted(thread Entry (&top)[kTopK], Entry e) {
    if (e.count <= top[kTopK - 1].count) return;
    for (uint i = 0; i < kTopK; i++) {
        if (e.count > top[i].count) {
            for (uint j = kTopK - 1; j > i; j--) {
                top[j] = top[j - 1];
            }
            top[i] = e;
            return;
        }
    }
}

/// Single-pass top-5 reduction over the 4 096-bin histogram.
///
/// Dispatch: 1 threadgroup, 256 threads.
/// Each thread scans 16 bins (4096 / 256), keeps a private top-5,
/// then writes to shared memory. Thread 0 merges all partial top-5 lists.
///
/// Output: `result` buffer with 5 × uint2(count, binIndex).
kernel void reduceTopColors(
    device const uint*     histogram  [[buffer(0)]],
    device uint2*          result     [[buffer(1)]],
    threadgroup uint2*     shared     [[threadgroup(0)]],
    uint                   lid        [[thread_index_in_threadgroup]],
    uint                   tgSize     [[threads_per_threadgroup]])
{
    Entry top[kTopK];
    for (uint i = 0; i < kTopK; i++) {
        top[i] = { 0, 0 };
    }

    // Each thread scans a strided slice of the histogram.
    for (uint idx = lid; idx < kTotal; idx += tgSize) {
        uint c = histogram[idx];
        if (c > top[kTopK - 1].count) {
            insertSorted(top, { c, idx });
        }
    }

    // Write per-thread top-5 to shared memory.
    for (uint i = 0; i < kTopK; i++) {
        shared[lid * kTopK + i] = uint2(top[i].count, top[i].binIdx);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Thread 0 merges all partial top-5 lists.
    if (lid == 0) {
        Entry merged[kTopK];
        for (uint i = 0; i < kTopK; i++) {
            merged[i] = { 0, 0 };
        }

        for (uint t = 0; t < tgSize; t++) {
            for (uint k = 0; k < kTopK; k++) {
                uint2 packed = shared[t * kTopK + k];
                insertSorted(merged, { packed.x, packed.y });
            }
        }

        for (uint i = 0; i < kTopK; i++) {
            result[i] = uint2(merged[i].count, merged[i].binIdx);
        }
    }
}
