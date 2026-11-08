#version 440

#if defined(QSHADER_GLSL) && QSHADER_GLSL_VERSION < 130
#define CONSTANT_SHAPE
#else
#define CONSTANT_SHAPE flat
#endif

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 local;
layout(location = 2) in vec2 size;
layout(location = 3) in vec2 shape;
layout(location = 4) in vec4 fill;
layout(location = 5) in vec4 border;
layout(location = 6) in vec4 backdrop;

layout(location = 0) out vec2 pixel;
layout(location = 1) CONSTANT_SHAPE out vec2 extent;
layout(location = 2) CONSTANT_SHAPE out vec2 outline;
layout(location = 3) out vec4 fill_color;
layout(location = 4) CONSTANT_SHAPE out vec4 border_color;
layout(location = 5) CONSTANT_SHAPE out vec4 backdrop_color;

layout(std140, binding = 0) uniform Uniforms {
    mat4 matrix;
    float opacity;
    float replace_background;
} uniforms;

void main() {
    gl_Position = uniforms.matrix * vec4(position, 0.0, 1.0);
    pixel = local;
    extent = size;
    outline = shape;
    fill_color = fill;
    border_color = border;
    backdrop_color = backdrop;
}
