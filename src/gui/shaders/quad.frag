#version 450
layout(set = 0, binding = 1) uniform sampler2D atlas;

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 0) out vec4 out_color;

void main() {
    float coverage = texture(atlas, in_uv).r;
    out_color = vec4(in_color.rgb, in_color.a * coverage);
}
