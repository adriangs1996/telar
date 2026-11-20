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
    const float binary32_mantissa_bits = 23.0;
    const float interpolation_rounding_steps = 1.0;
    const float coordinate_tolerance = exp2(-binary32_mantissa_bits) * interpolation_rounding_steps;
    vec2 sample_coordinate = mask_coordinate - vec2(coordinate_tolerance);
    float coverage = texture(alpha_mask, sample_coordinate).a;
#if TELAR_STRAIGHT_ALPHA
    fragment_color = vec4(uniforms.foreground.rgb, uniforms.foreground.a * coverage * mask_opacity * uniforms.qt_Opacity);
#else
    fragment_color = uniforms.foreground * (coverage * mask_opacity * uniforms.qt_Opacity);
#endif
}
