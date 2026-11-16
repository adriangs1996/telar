#version 440

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 texture_coordinate;
layout(location = 2) in float quad_opacity;
layout(location = 0) out vec2 mask_coordinate;
layout(location = 1) out float mask_opacity;

layout(std140, binding = 0) uniform MaskUniforms {
    mat4 qt_Matrix;
    vec4 foreground;
    float qt_Opacity;
} uniforms;

void main() {
    gl_Position = uniforms.qt_Matrix * vec4(position, 0.0, 1.0);
    mask_coordinate = texture_coordinate;
    mask_opacity = quad_opacity;
}
