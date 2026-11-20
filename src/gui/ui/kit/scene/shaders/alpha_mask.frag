#version 440

layout(location = 0) in vec2 mask_coordinate;
layout(location = 1) in float mask_opacity;
layout(location = 0) out vec4 fragment_color;
layout(binding = 1) uniform sampler2D alpha_mask;

layout(std140, binding = 0) uniform MaskUniforms {
    mat4 qt_Matrix;
    vec4 foreground;
    float qt_Opacity;
} uniforms;

void main() {
#if TELAR_STRAIGHT_ALPHA
    float coverage = texture(alpha_mask, mask_coordinate).a;
    fragment_color = vec4(uniforms.foreground.rgb, uniforms.foreground.a * coverage * mask_opacity * uniforms.qt_Opacity);
#else
    fragment_color = uniforms.foreground * (texture(alpha_mask, mask_coordinate).a * mask_opacity * uniforms.qt_Opacity);
#endif
}
