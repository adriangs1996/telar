#include <metal_stdlib>

using namespace metal;

// Mirrors `telar_gui_quad`: rect, uv, fill color, shape (radius, border, 0, 0)
// and border color.
struct Quad {
    float4 rect;
    float4 uv;
    float4 color;
    float4 shape;
    float4 border_color;
};

struct Vertex {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 local;
    float2 size [[flat]];
    float2 shape [[flat]];
    float4 border_color [[flat]];
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
    out.local = corner * q.rect.zw;
    out.size = q.rect.zw;
    out.shape = q.shape.xy;
    out.border_color = q.border_color;
    return out;
}

// Signed distance from the pixel center to the rounded rectangle outline, in
// pixels; negative inside. Straight edges land exactly on -0.5 at the outer
// pixel centers, so integer rectangles keep full coverage.
static float rounded_distance(float2 local, float2 size, float radius) {
    float2 half_size = size * 0.5;
    float2 q = abs(local - half_size) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

fragment float4 quad_fragment(Vertex in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float coverage = atlas.sample(nearest, in.uv).r;
    if (in.shape.x == 0.0 && in.shape.y == 0.0) {
        return float4(in.color.rgb, in.color.a * coverage);
    }

    float distance = rounded_distance(in.local, in.size, in.shape.x);
    float outer = 1.0 - clamp(distance + 0.5, 0.0, 1.0);
    float inner = 1.0 - clamp(distance + in.shape.y + 0.5, 0.0, 1.0);
    float fill_alpha = in.color.a * inner;
    float border_alpha = in.border_color.a * (outer - inner);
    float alpha = fill_alpha + border_alpha;
    float3 rgb = alpha > 0.0 ? (in.color.rgb * fill_alpha + in.border_color.rgb * border_alpha) / alpha : float3(0.0);
    return float4(rgb, alpha * coverage);
}
