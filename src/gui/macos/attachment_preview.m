#import "../../host/macos/clipboard_image.h"
#include <math.h>

// Decode on the media worker. ImageIO handles grayscale, profiles and 16-bit PNGs;
// the retained preview is at most 2048 squared, irrespective of source size.
unsigned char *telar_gui_decode_attachment(const unsigned char *bytes, size_t len, uint32_t *width, uint32_t *height) {
    if (bytes == NULL || len == 0 || len > 16 * 1024 * 1024) return NULL;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:len freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (source == NULL) return NULL;
        uint32_t source_width = 0, source_height = 0;
        if (source_dimensions(source, &source_width, &source_height, 16000000) != TELAR_CLIPBOARD_OK) {
            CFRelease(source);
            return NULL;
        }
        // Four draft previews fit together inside the shared eight-megapixel cache.
        double longest = fmax(source_width, source_height);
        double budget_scale = sqrt((1024.0 * 1024.0 - 4096.0) / ((double)source_width * source_height));
        unsigned side = (unsigned)fmax(1, floor(fmin(2048, longest * fmin(1, budget_scale))));
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(side),
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (image == NULL) return NULL;
        size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
        if (w == 0 || h == 0 || w > 2048 || h > 2048 || w * h > 1024 * 1024) { CGImageRelease(image); return NULL; }
        unsigned char *pixels = calloc(w * h, 4);
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context = pixels && space ? CGBitmapContextCreate(pixels, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
        if (space) CGColorSpaceRelease(space);
        if (context == NULL) { free(pixels); CGImageRelease(image); return NULL; }
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
        CGImageRelease(image);
        *width = (uint32_t)w;
        *height = (uint32_t)h;
        return pixels;
    }
}
