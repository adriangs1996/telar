#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// The GUI atlas and desktop use alpha-only contexts: gray controls optical weight, not opacity.
static inline void telar_font_smoothing(CGContextRef context, bool enabled, uint8_t strength) {
    CGContextSetAllowsFontSmoothing(context, true);
    CGContextSetShouldSmoothFonts(context, enabled);
    CGContextSetAllowsFontSubpixelPositioning(context, true);
    CGContextSetShouldSubpixelPositionFonts(context, true);
    CGContextSetAllowsFontSubpixelQuantization(context, false);
    CGContextSetShouldSubpixelQuantizeFonts(context, false);
    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetShouldAntialias(context, true);
    CGContextSetGrayFillColor(context, strength / 255.0, 1);
    CGContextSetGrayStrokeColor(context, strength / 255.0, 1);
}
