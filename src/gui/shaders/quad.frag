#version 450
layout(set = 0, binding = 1) uniform sampler2D atlas;
// Premultiplied RGBA cells sampled linearly; the tint's alpha fades a sprite
// and its RGB multiplies the artwork.
layout(set = 0, binding = 2) uniform sampler2D sprites;
layout(set = 0, binding = 3) uniform sampler2D diagram0;
layout(set = 0, binding = 4) uniform sampler2D diagram1;
layout(set = 0, binding = 5) uniform sampler2D diagram2;
layout(set = 0, binding = 6) uniform sampler2D diagram3;
layout(set = 0, binding = 7) uniform sampler2D diagram4;
layout(set = 0, binding = 8) uniform sampler2D diagram5;
layout(set = 0, binding = 9) uniform sampler2D diagram6;
layout(set = 0, binding = 10) uniform sampler2D diagram7;


layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec2 in_local;
layout(location = 3) flat in vec2 in_size;
layout(location = 4) flat in vec2 in_shape;
layout(location = 5) flat in vec4 in_border_color;
layout(location = 6) flat in float in_texture;
layout(location = 0) out vec4 out_color;

// Signed distance from the pixel center to the rounded rectangle outline, in
// pixels; negative inside. Straight edges land exactly on -0.5 at the outer
// pixel centers, so integer rectangles keep full coverage.
float rounded_distance(vec2 local, vec2 size, float radius) {
    vec2 half_size = size * 0.5;
    vec2 q = abs(local - half_size) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    if (in_texture > 0.5) {
        // The blend state expects straight alpha, so the premultiplied texel
        // is divided back before the tint applies.
        vec4 texel;
        // Fixed bindings avoid requiring dynamically indexed sampled images.
        switch (int(in_texture)) {
            case 2: texel = texture(diagram0, in_uv); break;
            case 3: texel = texture(diagram1, in_uv); break;
            case 4: texel = texture(diagram2, in_uv); break;
            case 5: texel = texture(diagram3, in_uv); break;
            case 6: texel = texture(diagram4, in_uv); break;
            case 7: texel = texture(diagram5, in_uv); break;
            case 8: texel = texture(diagram6, in_uv); break;
            case 9: texel = texture(diagram7, in_uv); break;
            default: texel = texture(sprites, in_uv); break;
        }
        vec3 straight = texel.a > 0.0 ? texel.rgb / texel.a : vec3(0.0);
        out_color = vec4(straight * in_color.rgb, texel.a * in_color.a);
        return;
    }

    float coverage = texture(atlas, in_uv).r;
    if (in_shape.x == 0.0 && in_shape.y == 0.0) {
        out_color = vec4(in_color.rgb, in_color.a * coverage);
        return;
    }

    float distance = rounded_distance(in_local, in_size, in_shape.x);
    float outer = 1.0 - clamp(distance + 0.5, 0.0, 1.0);
    float inner = 1.0 - clamp(distance + in_shape.y + 0.5, 0.0, 1.0);
    float fill_alpha = in_color.a * inner;
    float border_alpha = in_border_color.a * (outer - inner);
    float alpha = fill_alpha + border_alpha;
    vec3 rgb = alpha > 0.0 ? (in_color.rgb * fill_alpha + in_border_color.rgb * border_alpha) / alpha : vec3(0.0);
    out_color = vec4(rgb, alpha * coverage);
}
