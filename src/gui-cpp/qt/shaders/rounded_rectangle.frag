#version 440

#if defined(QSHADER_GLSL) && QSHADER_GLSL_VERSION < 130
#define CONSTANT_SHAPE
#else
#define CONSTANT_SHAPE flat
#endif

layout(location = 0) in vec2 pixel;
layout(location = 1) CONSTANT_SHAPE in vec2 extent;
layout(location = 2) CONSTANT_SHAPE in vec2 outline;
layout(location = 3) in vec4 fill_color;
layout(location = 4) CONSTANT_SHAPE in vec4 border_color;
layout(location = 5) CONSTANT_SHAPE in vec4 backdrop_color;
layout(location = 0) out vec4 fragment;

layout(std140, binding = 0) uniform Uniforms {
    mat4 matrix;
    float opacity;
    float replace_background;
} uniforms;

float roundedDistance(vec2 local, vec2 size, float radius) {
    vec2 half_size = size * 0.5;
    vec2 offset = abs(local - half_size) - half_size + radius;

    return length(max(offset, 0.0)) + min(max(offset.x, offset.y), 0.0) - radius;
}

void main() {
    if (outline.x == 0.0 && outline.y == 0.0) {
        float alpha = fill_color.a * uniforms.opacity;
        fragment = vec4(uniforms.replace_background > 0.0 ? fill_color.rgb * alpha : fill_color.rgb, alpha);
        return;
    }

    float radius = outline.x < 0.0 && pixel.y > extent.y * 0.5 ? 0.0 : abs(outline.x);
    float distance = roundedDistance(pixel, extent, radius);
    float outer = 1.0 - clamp(distance + 0.5, 0.0, 1.0);
    float inner = 1.0 - clamp(distance + outline.y + 0.5, 0.0, 1.0);
    float fill_alpha = fill_color.a * inner;
    float border_alpha = border_color.a * (outer - inner);
    float alpha = fill_alpha + border_alpha;
    vec3 ink = fill_color.rgb * fill_alpha + border_color.rgb * border_alpha;
    if (uniforms.replace_background > 0.0) {
        float backdrop_alpha = backdrop_color.a * (1.0 - outer);
        fragment = vec4(ink + backdrop_color.rgb * backdrop_alpha, alpha + backdrop_alpha) * uniforms.opacity;
    } else {
        vec3 rgb = alpha > 0.0 ? ink / alpha : vec3(0.0);
        fragment = vec4(rgb, alpha * uniforms.opacity);
    }
}
