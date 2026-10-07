#version 450
// One instance per quad, six vertices per instance. Quads arrive in a storage
// buffer with the layout of `telar_gui_quad`; the viewport is a push constant.
struct Quad {
    vec4 rect;
    vec4 uv;
    vec4 color;
    vec4 shape;
    vec4 border_color;
};

layout(std430, set = 0, binding = 0) readonly buffer Quads {
    Quad quads[];
};

layout(push_constant) uniform Push {
    vec2 viewport;
} push;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec2 out_local;
layout(location = 3) flat out vec2 out_size;
layout(location = 4) flat out vec2 out_shape;
layout(location = 5) flat out vec4 out_border_color;
layout(location = 6) flat out float out_texture;

void main() {
    Quad quad = quads[gl_InstanceIndex];
    uint vid = uint(gl_VertexIndex);
    vec2 corner = vec2((vid == 1u || vid == 2u || vid == 4u) ? 1.0 : 0.0,
                       (vid == 2u || vid == 4u || vid == 5u) ? 1.0 : 0.0);
    vec2 pixel = quad.rect.xy + corner * quad.rect.zw;
    // Vulkan clip space grows downwards like our pixel coordinates.
    gl_Position = vec4(pixel.x / push.viewport.x * 2.0 - 1.0, pixel.y / push.viewport.y * 2.0 - 1.0, 0.0, 1.0);
    out_uv = quad.uv.xy + corner * (quad.uv.zw - quad.uv.xy);
    out_color = quad.color;
    out_local = corner * quad.rect.zw;
    out_size = quad.rect.zw;
    out_shape = quad.shape.xy;
    out_border_color = quad.border_color;
    out_texture = quad.shape.z;
}
