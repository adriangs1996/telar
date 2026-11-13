#include "tbc/view.hpp"
#include "glyph_rasterizer.h"
#include "font_smoothing.h"
#include "cf_reference.hpp"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>
#include <memory>
#include <new>

using telar::gui::platform::NativeReference;

enum NativeGlyphOptions {
  maximum_font_faces = 256,
  synthetic_bold_style = 1,
  synthetic_italic_style = 2,
  maximum_glyph_style = synthetic_bold_style | synthetic_italic_style,
  synthetic_bold_divisor = 24,
};

static const CGFloat synthetic_italic_slant = 0.21256;

// Each owned reference is released with the rasterizer.
struct telar_glyph_rasterizer {
  NativeReference<CTFontRef> base, regular, italic;
  NativeReference<CGContextRef> context;
  uint32_t side = 0, pixel_height = 0;
  bool thicken = false;
};

static CTFontRef font_from_data(const telar_glyph_rasterizer_options *options) {
  const NativeReference data{CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, options->font, (CFIndex)options->font_len, kCFAllocatorNull)};
  if (!data) {
    return NULL;
  }

  const NativeReference descriptors{CTFontManagerCreateFontDescriptorsFromData(data.get())};
  if (!descriptors) {
    return NULL;
  }

  const NativeReference name{options->postscript != NULL
                                 ? CFStringCreateWithCString(kCFAllocatorDefault, options->postscript, kCFStringEncodingUTF8)
                                 : nullptr};
  if (options->postscript != NULL && !name) {
    return NULL;
  }

  CFIndex count = CFArrayGetCount(descriptors.get());
  if (count <= maximum_font_faces) {
    for (CFIndex i = 0; i < count; i++) {
      CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors.get(), i);
      const NativeReference candidate{(CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute)};
      bool matches = name ? candidate && CFEqual(name.get(), candidate.get()) : i == options->face_index;
      if (matches) {
        return CTFontCreateWithFontDescriptor(descriptor, 1, NULL);
      }
    }
  }

  return NULL;
}

// The font with the variation applied, or none; the font itself is consumed. The result is a new
// reference the caller owns, borrowing none of the arguments.
static tbc::view<CTFontRef, tbc::lt::static_storage> vary(CTFontRef consumed, const telar_font_variation *variation) {
  NativeReference font{consumed};
  if (!font || variation == NULL || variation->count == 0) {
    return tbc::raw(font.release());
  }

  if (variation->count > telar_font_max_axes) {
    return NULL;
  }

  const NativeReference axes{CFDictionaryCreateMutable(kCFAllocatorDefault, variation->count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)};

  for (uint32_t i = 0; axes && i < variation->count; i++) {
    const NativeReference tag{CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &variation->tags[i])};
    const NativeReference value{CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &variation->values[i])};
    if (tag && value) {
      CFDictionarySetValue(axes.get(), tag.get(), value.get());
    }
  }

  if (!axes || (uint32_t)CFDictionaryGetCount(axes.get()) != variation->count) {
    return NULL;
  }

  const void *keys[] = {kCTFontVariationAttribute};
  const void *values[] = {axes.get()};
  const NativeReference attributes{CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)};
  const NativeReference descriptor{attributes ? CTFontDescriptorCreateWithAttributes(attributes.get()) : nullptr};

  return descriptor ? tbc::raw(CTFontCreateCopyWithAttributes(font.get(), CTFontGetSize(font.get()), NULL, descriptor.get())) : NULL;
}

void telarGlyphRasterizerDestroy(telar_glyph_rasterizer *self) {
  delete self;
}

telar_glyph_rasterizer *telarGlyphRasterizerCreate(const telar_glyph_rasterizer_options *options) {
  if (options->font_len == 0 || options->font_len > telar_font_max_bytes ||
      options->side < 2 || options->side > telar_glyph_atlas_max_side || options->strength > UINT8_MAX) {
    return NULL;
  }

  std::unique_ptr<telar_glyph_rasterizer> self{new (std::nothrow) telar_glyph_rasterizer{}};
  if (self == nullptr) {
    return NULL;
  }

  self->side = options->side;
  self->thicken = options->thicken != 0;
  self->base.reset(vary(font_from_data(options), options->variation));
  const NativeReference space{CGColorSpaceCreateWithName(kCGColorSpaceLinearGray)};
  if (self->base && space) {
    self->context.reset(CGBitmapContextCreate(options->pixels, options->side, options->side, 8, options->side, space.get(), (CGBitmapInfo)kCGImageAlphaOnly));
  }

  if (!self->context) {
    return NULL;
  }

  telarFontSmoothing(self->context.get(), self->thicken, (uint8_t)options->strength);
  return self.release();
}

int telarGlyphRasterizerSelect(telar_glyph_rasterizer *self, uint32_t pixel_height) {
  if (pixel_height == 0 || pixel_height > UINT16_MAX) {
    return -1;
  }

  if (self->pixel_height == pixel_height) {
    return 0;
  }

  CGAffineTransform skew = CGAffineTransformMake(1, 0, synthetic_italic_slant, 1, 0, 0);
  NativeReference regular{CTFontCreateCopyWithAttributes(self->base.get(), pixel_height, NULL, NULL)};
  NativeReference italic{CTFontCreateCopyWithAttributes(self->base.get(), pixel_height, &skew, NULL)};
  if (!regular || !italic) {
    return -1;
  }

  self->regular = std::move(regular);
  self->italic = std::move(italic);
  self->pixel_height = pixel_height;
  return 0;
}

int telarGlyphRasterizerMeasure(telar_glyph_rasterizer *self, telar_glyph_raster *glyph) {
  if (!self->regular || glyph->index > UINT16_MAX || glyph->style > maximum_glyph_style) {
    return -1;
  }

  CTFontRef font = glyph->style & synthetic_italic_style ? self->italic.get() : self->regular.get();
  CGGlyph index = (CGGlyph)glyph->index;
  CGRect rect = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &index, NULL, 1);
  if (CGRectIsEmpty(rect)) {
    glyph->width = glyph->height = 0;
    return 0;
  }

  CGFloat stroke = glyph->style & synthetic_bold_style ? (CGFloat)self->pixel_height / synthetic_bold_divisor : 0;
  CGFloat extra = stroke / 2 + (self->thicken ? 1 : 0);
  CGFloat left = floor(CGRectGetMinX(rect) - extra);
  CGFloat bottom = floor(CGRectGetMinY(rect) - extra);
  CGFloat right = ceil(CGRectGetMaxX(rect) + extra);
  CGFloat top = ceil(CGRectGetMaxY(rect) + extra);
  if (!isfinite(left) || !isfinite(bottom) || !isfinite(right) || !isfinite(top) ||
      left < INT32_MIN || right > INT32_MAX || bottom < INT32_MIN || top > INT32_MAX ||
      right - left > self->side || top - bottom > self->side) {
    return -1;
  }

  glyph->left = (int32_t)left;
  glyph->top = (int32_t)top;
  glyph->width = (uint32_t)(right - left);
  glyph->height = (uint32_t)(top - bottom);
  return 0;
}

void telarGlyphRasterizerDraw(telar_glyph_rasterizer *self, const telar_glyph_raster *glyph) {
  if (glyph->x > self->side || glyph->y > self->side ||
      glyph->width > self->side - glyph->x || glyph->height > self->side - glyph->y ||
      glyph->width == 0 || glyph->height == 0) {
    return;
  }

  CGContextRef context = self->context.get();

  CGContextSaveGState(context);
  CGRect region = CGRectMake(glyph->x, self->side - glyph->y - glyph->height, glyph->width, glyph->height);

  CGContextClipToRect(context, region);
  CGContextClearRect(context, region);
  CGContextSetTextDrawingMode(context, glyph->style & synthetic_bold_style ? kCGTextFillStroke : kCGTextFill);
  CGContextSetLineWidth(context, (CGFloat)self->pixel_height / synthetic_bold_divisor);
  CTFontRef font = glyph->style & synthetic_italic_style ? self->italic.get() : self->regular.get();
  CGGlyph index = (CGGlyph)glyph->index;
  CGPoint point = {(CGFloat)glyph->x - glyph->left, (CGFloat)self->side - glyph->y - glyph->top};

  CTFontDrawGlyphs(font, &index, &point, 1, context);
  CGContextRestoreGState(context);
  CGContextFlush(context);
}
