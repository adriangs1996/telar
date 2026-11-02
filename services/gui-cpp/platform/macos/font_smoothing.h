#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

static inline void telarFontSmoothing(CGContextRef context, bool enabled, uint8_t strength) {
  const CGFloat maximum_channel = UINT8_MAX;
  CGContextSetAllowsFontSmoothing(context, true);
  CGContextSetShouldSmoothFonts(context, enabled);
  CGContextSetAllowsFontSubpixelPositioning(context, true);
  CGContextSetShouldSubpixelPositionFonts(context, true);
  CGContextSetAllowsFontSubpixelQuantization(context, false);
  CGContextSetShouldSubpixelQuantizeFonts(context, false);
  CGContextSetAllowsAntialiasing(context, true);
  CGContextSetShouldAntialias(context, true);
  CGContextSetGrayFillColor(context, strength / maximum_channel, 1);
  CGContextSetGrayStrokeColor(context, strength / maximum_channel, 1);
}
