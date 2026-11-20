#include "glyph_rasterizer.h"
#include "cf_reference.hpp"
#include "font_smoothing.h"
#include "tbc/view.hpp"
#include "telar_base/ds/values.hpp"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <cmath>
#include <memory>
#include <new>

#include <cstdlib>

using telar::gui::platform::NativeReference;

// Each owned reference is released with the rasterizer.
struct telar_glyph_rasterizer {
  NativeReference<CTFontRef> base, regular, italic;
  NativeReference<CGContextRef> context;
  uint32_t side = 0, pixel_height = 0;
  bool thicken = false;
};

namespace {

  constexpr CFIndex maximum_font_faces = 256;
  constexpr uint32_t synthetic_bold_style = 1;
  constexpr uint32_t synthetic_italic_style = 2;
  constexpr uint32_t maximum_glyph_style = synthetic_bold_style | synthetic_italic_style;
  constexpr CGFloat synthetic_bold_divisor = 24;
  constexpr CGFloat synthetic_italic_slant = 0.21256;

  CTFontRef createFontFromData(const telar_glyph_rasterizer_options* options) {
    const NativeReference data{CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, options->font, (CFIndex)options->font_len, kCFAllocatorNull)};
    if (!data) {
      return nullptr;
    }

    const NativeReference descriptors{CTFontManagerCreateFontDescriptorsFromData(data.get())};
    if (!descriptors) {
      return nullptr;
    }

    const NativeReference name{options->postscript != nullptr ? CFStringCreateWithCString(kCFAllocatorDefault, options->postscript, kCFStringEncodingUTF8) : nullptr};
    if (options->postscript != nullptr && !name) {
      return nullptr;
    }

    const CFIndex count = CFArrayGetCount(descriptors.get());
    if (count <= maximum_font_faces) {
      for (CFIndex i = 0; i < count; i++) {
        const auto* descriptor = static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(descriptors.get(), i));
        const NativeReference candidate{static_cast<CFStringRef>(CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute))};
        const bool matches = name ? candidate && (CFEqual(name.get(), candidate.get()) != 0U) : i == options->face_index;
        if (matches) {
          return CTFontCreateWithFontDescriptor(descriptor, 1, nullptr);
        }
      }
    }

    return nullptr;
  }

  // The font with the variation applied, or none; the font itself is consumed. The result is a new
  // reference the caller owns, borrowing none of the arguments.
  tbc::val_static<CTFontRef> vary(CF_CONSUMED CTFontRef consumed, const telar_font_variation* variation) {
    NativeReference font{consumed};
    if (!font || variation == nullptr || variation->count == 0) {
      return tbc::raw(font.release());
    }

    if (variation->count > telar_font_max_axes) {
      return nullptr;
    }

    const NativeReference axes{CFDictionaryCreateMutable(kCFAllocatorDefault, variation->count, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)};

    for (uint32_t i = 0; axes && i < variation->count; i++) {
      const NativeReference tag{CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &variation->tags[i])};
      const NativeReference value{CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &variation->values[i])};
      if (tag && value) {
        CFDictionarySetValue(axes.get(), tag.get(), value.get());
      }
    }

    if (!axes || std::cmp_not_equal(CFDictionaryGetCount(axes.get()), variation->count)) {
      return nullptr;
    }

    telar::ds::Array<const void*, 1> keys{kCTFontVariationAttribute};
    telar::ds::Array<const void*, 1> values{axes.get()};
    const NativeReference attributes{CFDictionaryCreate(kCFAllocatorDefault, keys.dataMut(), values.dataMut(), static_cast<CFIndex>(keys.size()), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)};
    const NativeReference descriptor{attributes ? CTFontDescriptorCreateWithAttributes(attributes.get()) : nullptr};

    return descriptor ? tbc::raw(CTFontCreateCopyWithAttributes(font.get(), CTFontGetSize(font.get()), nullptr, descriptor.get())) : nullptr;
  }

}

void telarGlyphRasterizerDestroy(const telar_glyph_rasterizer* self) {
  std::default_delete<const telar_glyph_rasterizer>{}(self);
}

telar_glyph_rasterizer* telarGlyphRasterizerCreate(const telar_glyph_rasterizer_options* options) {
  if (options->font_len == 0 || options->font_len > telar_font_max_bytes ||
      options->side < 2 || options->side > telar_glyph_atlas_max_side || options->strength > UINT8_MAX) {
    return nullptr;
  }

  std::unique_ptr<telar_glyph_rasterizer> self{new (std::nothrow) telar_glyph_rasterizer{}};
  if (self == nullptr) {
    return nullptr;
  }

  self->side = options->side;
  self->thicken = options->thicken != 0;
  self->base.reset(vary(createFontFromData(options), options->variation));
  const NativeReference space{CGColorSpaceCreateWithName(kCGColorSpaceLinearGray)};
  if (self->base && space) {
    // One byte of alpha per pixel.
    constexpr size_t bits_per_component = 8;

    // The caller's buffer, which the context draws into from now on: C's, by address.
    self->context.reset(CGBitmapContextCreate(tbc::raw(options->pixels), options->side, options->side, bits_per_component, options->side, space.get(), (CGBitmapInfo)kCGImageAlphaOnly));
  }

  if (!self->context) {
    return nullptr;
  }

  telarFontSmoothing(self->context.get(), self->thicken, (uint8_t)options->strength);
  return self.release();
}

int telarGlyphRasterizerSelect(telar_glyph_rasterizer* self, uint32_t pixel_height) {
  if (pixel_height == 0 || pixel_height > UINT16_MAX) {
    return -1;
  }

  if (self->pixel_height == pixel_height) {
    return 0;
  }

  const CGAffineTransform skew = CGAffineTransformMake(1, 0, synthetic_italic_slant, 1, 0, 0);
  NativeReference regular{CTFontCreateCopyWithAttributes(self->base.get(), pixel_height, nullptr, nullptr)};
  NativeReference italic{CTFontCreateCopyWithAttributes(self->base.get(), pixel_height, &skew, nullptr)};
  if (!regular || !italic) {
    return -1;
  }

  self->regular = std::move(regular);
  self->italic = std::move(italic);
  self->pixel_height = pixel_height;
  return 0;
}

int telarGlyphRasterizerMeasure(const telar_glyph_rasterizer* self, telar_glyph_raster* glyph) {
  if (!self->regular || glyph->index > UINT16_MAX || glyph->style > maximum_glyph_style) {
    return -1;
  }

  CTFontRef font = ((glyph->style & synthetic_italic_style) != 0U) ? self->italic.get() : self->regular.get();
  const auto index = (CGGlyph)glyph->index;
  const CGRect rect = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &index, nullptr, 1);
  if (CGRectIsEmpty(rect)) {
    glyph->width = glyph->height = 0;
    return 0;
  }

  const CGFloat stroke = ((glyph->style & synthetic_bold_style) != 0U) ? (CGFloat)self->pixel_height / synthetic_bold_divisor : 0;
  const CGFloat extra = (stroke / 2) + (self->thicken ? 1 : 0);
  const CGFloat left = floor(CGRectGetMinX(rect) - extra);
  const CGFloat bottom = floor(CGRectGetMinY(rect) - extra);
  const CGFloat right = ceil(CGRectGetMaxX(rect) + extra);
  const CGFloat top = ceil(CGRectGetMaxY(rect) + extra);
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

void telarGlyphRasterizerDraw(const telar_glyph_rasterizer* self, const telar_glyph_raster* glyph) {
  if (glyph->x > self->side || glyph->y > self->side ||
      glyph->width > self->side - glyph->x || glyph->height > self->side - glyph->y ||
      glyph->width == 0 || glyph->height == 0) {
    return;
  }

  CGContextRef context = self->context.get();

  CGContextSaveGState(context);
  const CGRect region = CGRectMake(glyph->x, self->side - glyph->y - glyph->height, glyph->width, glyph->height);

  CGContextClipToRect(context, region);
  CGContextClearRect(context, region);
  CGContextSetTextDrawingMode(context, ((glyph->style & synthetic_bold_style) != 0U) ? kCGTextFillStroke : kCGTextFill);
  CGContextSetLineWidth(context, (CGFloat)self->pixel_height / synthetic_bold_divisor);
  CTFontRef font = ((glyph->style & synthetic_italic_style) != 0U) ? self->italic.get() : self->regular.get();
  const auto index = (CGGlyph)glyph->index;
  const CGPoint point = {.x = (CGFloat)glyph->x - glyph->left, .y = (CGFloat)self->side - glyph->y - glyph->top};

  CTFontDrawGlyphs(font, &index, &point, 1, context);
  CGContextRestoreGState(context);
  CGContextFlush(context);
}
