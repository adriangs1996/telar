#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#include "../native/glyph_rasterizer.h"
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

struct telar_glyph_rasterizer {
    CTFontRef base, regular, italic;
    CGContextRef context;
    uint32_t side, pixel_height;
    bool thicken;
};

static CTFontRef font_from_data(const telar_glyph_rasterizer_options *options) {
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, options->font,
                                               (CFIndex)options->font_len, kCFAllocatorNull);
    if (data == NULL) {
        return NULL;
    }
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromData(data);
    CFRelease(data);
    if (descriptors == NULL) {
        return NULL;
    }

    CTFontRef font = NULL;
    CFStringRef name = options->postscript != NULL
        ? CFStringCreateWithCString(kCFAllocatorDefault, options->postscript, kCFStringEncodingUTF8) : NULL;
    if (options->postscript != NULL && name == NULL) {
        CFRelease(descriptors);
        return NULL;
    }
    CFIndex count = CFArrayGetCount(descriptors);
    if (count <= 256) {
        for (CFIndex i = 0; i < count; i++) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, i);
            CFStringRef candidate = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
            bool matches = name != NULL ? candidate != NULL && CFEqual(name, candidate) : i == options->face_index;
            if (candidate != NULL) {
                CFRelease(candidate);
            }
            if (matches) {
                font = CTFontCreateWithFontDescriptor(descriptor, 1, NULL);
                break;
            }
        }
    }
    if (name != NULL) {
        CFRelease(name);
    }
    CFRelease(descriptors);
    return font;
}

void telar_glyph_rasterizer_destroy(telar_glyph_rasterizer *self) {
    if (self == NULL) {
        return;
    }
    if (self->context != NULL) {
        CGContextRelease(self->context);
    }
    if (self->italic != NULL) {
        CFRelease(self->italic);
    }
    if (self->regular != NULL) {
        CFRelease(self->regular);
    }
    if (self->base != NULL) {
        CFRelease(self->base);
    }
    free(self);
}

telar_glyph_rasterizer *telar_glyph_rasterizer_create(const telar_glyph_rasterizer_options *options) {
    if (options->font_len == 0 || options->font_len > 64 * 1024 * 1024 ||
        options->side < 2 || options->side > 1024 || options->strength > 255) {
        return NULL;
    }
    telar_glyph_rasterizer *self = calloc(1, sizeof *self);
    if (self == NULL) {
        return NULL;
    }
    self->side = options->side;
    self->thicken = options->thicken != 0;
    self->base = font_from_data(options);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceLinearGray);
    if (self->base != NULL && space != NULL) {
        self->context = CGBitmapContextCreate(options->pixels, options->side, options->side,
                                             8, options->side, space, (CGBitmapInfo)kCGImageAlphaOnly);
    }
    if (space != NULL) {
        CGColorSpaceRelease(space);
    }
    if (self->context == NULL) {
        telar_glyph_rasterizer_destroy(self);
        return NULL;
    }

    CGContextSetAllowsFontSmoothing(self->context, true);
    CGContextSetShouldSmoothFonts(self->context, self->thicken);
    CGContextSetAllowsFontSubpixelPositioning(self->context, true);
    CGContextSetShouldSubpixelPositionFonts(self->context, true);
    CGContextSetAllowsFontSubpixelQuantization(self->context, false);
    CGContextSetShouldSubpixelQuantizeFonts(self->context, false);
    CGContextSetAllowsAntialiasing(self->context, true);
    CGContextSetShouldAntialias(self->context, true);
    // CoreGraphics uses the gray value for optical weight even in an alpha-only
    // context. This is Ghostty's strength control; alpha itself remains one.
    CGContextSetGrayFillColor(self->context, options->strength / 255.0, 1);
    CGContextSetGrayStrokeColor(self->context, options->strength / 255.0, 1);
    return self;
}

int telar_glyph_rasterizer_select(telar_glyph_rasterizer *self, uint32_t pixel_height) {
    if (pixel_height == 0 || pixel_height > UINT16_MAX) {
        return -1;
    }
    if (self->pixel_height == pixel_height) {
        return 0;
    }
    CGAffineTransform skew = CGAffineTransformMake(1, 0, 0.21256, 1, 0, 0);
    CTFontRef regular = CTFontCreateCopyWithAttributes(self->base, pixel_height, NULL, NULL);
    CTFontRef italic = CTFontCreateCopyWithAttributes(self->base, pixel_height, &skew, NULL);
    if (regular == NULL || italic == NULL) {
        if (regular != NULL) {
            CFRelease(regular);
        }
        if (italic != NULL) {
            CFRelease(italic);
        }
        return -1;
    }
    if (self->regular != NULL) {
        CFRelease(self->regular);
    }
    if (self->italic != NULL) {
        CFRelease(self->italic);
    }
    self->regular = regular;
    self->italic = italic;
    self->pixel_height = pixel_height;
    return 0;
}

int telar_glyph_rasterizer_measure(telar_glyph_rasterizer *self, telar_glyph_raster *glyph) {
    if (self->regular == NULL || glyph->index > UINT16_MAX || glyph->style > 3) {
        return -1;
    }
    CTFontRef font = glyph->style & 2 ? self->italic : self->regular;
    CGGlyph index = (CGGlyph)glyph->index;
    CGRect rect = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &index, NULL, 1);
    if (CGRectIsEmpty(rect)) {
        glyph->width = glyph->height = 0;
        return 0;
    }
    // Match the existing synthetic weight's size scale, independent of smoothing.
    CGFloat stroke = glyph->style & 1 ? self->pixel_height / 24.0 : 0;
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

// The atlas reserves before drawing. Clip in bottom-left CoreGraphics coordinates
// so smoothing cannot touch adjacent glyphs or the solid-quad texel.
void telar_glyph_rasterizer_draw(telar_glyph_rasterizer *self, const telar_glyph_raster *glyph) {
    if (glyph->x > self->side || glyph->y > self->side ||
        glyph->width > self->side - glyph->x || glyph->height > self->side - glyph->y ||
        glyph->width == 0 || glyph->height == 0) {
        return;
    }
    CGContextRef context = self->context;
    CGContextSaveGState(context);
    CGRect region = CGRectMake(glyph->x, self->side - glyph->y - glyph->height, glyph->width, glyph->height);
    CGContextClipToRect(context, region);
    CGContextClearRect(context, region);
    CGContextSetTextDrawingMode(context, glyph->style & 1 ? kCGTextFillStroke : kCGTextFill);
    CGContextSetLineWidth(context, self->pixel_height / 24.0);
    CTFontRef font = glyph->style & 2 ? self->italic : self->regular;
    CGGlyph index = (CGGlyph)glyph->index;
    CGPoint point = { (CGFloat)glyph->x - glyph->left, (CGFloat)self->side - glyph->y - glyph->top };
    CTFontDrawGlyphs(font, &index, &point, 1, context);
    CGContextRestoreGState(context);
    CGContextFlush(context);
}
