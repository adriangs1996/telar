#include <metal_stdlib>

using namespace metal;

struct Quad {
    float4 rect;
    float4 uv;
    float4 color;
};

struct Vertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// One instanced draw: six vertices per quad, quads read from buffer 0.
vertex Vertex quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Quad *quads [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    constant Quad &q = quads[iid];
    float2 corner = float2(
        vid == 1 || vid == 2 || vid == 4 ? 1.0 : 0.0,
        vid == 2 || vid == 4 || vid == 5 ? 1.0 : 0.0
    );
    float2 pixel = q.rect.xy + corner * q.rect.zw;

    Vertex out;
    out.position = float4(
        pixel.x / viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / viewport.y * 2.0,
        0.0,
        1.0
    );
    out.uv = q.uv.xy + corner * (q.uv.zw - q.uv.xy);
    out.color = q.color;
    return out;
}

fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float coverage = atlas.sample(nearest, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}
