#include <metal_stdlib>
using namespace metal;

/// Bilinear downsample kernel.
/// Reads from a source texture at fractionally-mapped coordinates and writes
/// the bilinearly-interpolated result into a smaller destination texture.
/// The destination is typically 128×128 regardless of source dimensions.
kernel void downsample(
    texture2d<float, access::sample>  srcTexture  [[texture(0)]],
    texture2d<float, access::write>   dstTexture  [[texture(1)]],
    uint2                             gid         [[thread_position_in_grid]])
{
    if (gid.x >= dstTexture.get_width() || gid.y >= dstTexture.get_height()) {
        return;
    }

    constexpr sampler bilinearSampler(
        mag_filter::linear,
        min_filter::linear,
        s_address::clamp_to_edge,
        t_address::clamp_to_edge
    );

    // Map destination pixel centre to normalised source coordinates.
    float2 uv = float2(
        (float(gid.x) + 0.5f) / float(dstTexture.get_width()),
        (float(gid.y) + 0.5f) / float(dstTexture.get_height())
    );

    float4 color = srcTexture.sample(bilinearSampler, uv);
    dstTexture.write(color, gid);
}
