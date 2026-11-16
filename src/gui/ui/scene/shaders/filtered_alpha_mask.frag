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

// Averages the texels one screen pixel covers on a 4x4 grid aligned with the glyph's
// transform, so an oversampled, rotated or scaled icon keeps smooth edges instead of the
// steps a single nearest sample leaves.
void main() {
    vec2 across = dFdx(mask_coordinate);
    vec2 down = dFdy(mask_coordinate);
    float coverage = 0.0;
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 4; ++column) {
            vec2 offset = (vec2(float(column), float(row)) + 0.5) / 4.0 - 0.5;
            coverage += texture(alpha_mask, mask_coordinate + across * offset.x + down * offset.y).a;
        }
    }

    coverage /= 16.0;
#if TELAR_STRAIGHT_ALPHA
    fragment_color = vec4(uniforms.foreground.rgb, uniforms.foreground.a * coverage * mask_opacity * uniforms.qt_Opacity);
#else
    fragment_color = uniforms.foreground * (coverage * mask_opacity * uniforms.qt_Opacity);
#endif
}
