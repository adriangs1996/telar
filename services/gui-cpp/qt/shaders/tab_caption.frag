#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float fadeStart;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    const float minimum_fade_span = 0.0001;
    float opacity = clamp((1.0 - qt_TexCoord0.x) / max(1.0 - fadeStart, minimum_fade_span), 0.0, 1.0);
    fragColor = texture(source, qt_TexCoord0) * qt_Opacity * opacity;
}
