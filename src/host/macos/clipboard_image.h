#pragma once
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>

#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    TELAR_CLIPBOARD_OK = 0,
    TELAR_CLIPBOARD_NO_IMAGE = 1,
    TELAR_CLIPBOARD_TOO_LARGE = 2,
    TELAR_CLIPBOARD_FAILED = 3,
};

static int source_dimensions(
    CGImageSourceRef source,
    uint32_t *width,
    uint32_t *height,
    uint64_t max_pixels
) {
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (properties == NULL) return TELAR_CLIPBOARD_FAILED;

    CFNumberRef width_value = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    CFNumberRef height_value = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
    int64_t parsed_width = 0;
    int64_t parsed_height = 0;
    const bool valid = width_value != NULL && height_value != NULL &&
        CFNumberGetValue(width_value, kCFNumberSInt64Type, &parsed_width) &&
        CFNumberGetValue(height_value, kCFNumberSInt64Type, &parsed_height) &&
        parsed_width > 0 && parsed_height > 0 &&
        parsed_width <= UINT32_MAX && parsed_height <= UINT32_MAX &&
        (uint64_t)parsed_width <= max_pixels / (uint64_t)parsed_height;
    CFRelease(properties);
    if (!valid) return TELAR_CLIPBOARD_TOO_LARGE;

    *width = (uint32_t)parsed_width;
    *height = (uint32_t)parsed_height;
    return TELAR_CLIPBOARD_OK;
}

static CGImageSourceRef source_from_file(NSPasteboard *pasteboard, size_t max_source_bytes, int *failure) {
    NSDictionary *options = @{ NSPasteboardURLReadingFileURLsOnlyKey: @YES };
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:options];
    unsigned checked = 0;
    for (NSURL *url in urls) {
        if (++checked > 16) break;
        const char *path = url.fileSystemRepresentation;
        if (path == NULL) continue;
        int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        struct stat status;
        if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_uid != geteuid() || status.st_size <= 0) {
            close(fd);
            continue;
        }
        if ((uint64_t)status.st_size > max_source_bytes) {
            close(fd);
            *failure = TELAR_CLIPBOARD_TOO_LARGE;
            continue;
        }
        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
        if (data == nil) { close(fd); *failure = TELAR_CLIPBOARD_FAILED; return NULL; }
        size_t offset = 0;
        while (offset < data.length) {
            ssize_t count = read(fd, (unsigned char *)data.mutableBytes + offset, data.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) break;
            offset += (size_t)count;
        }
        close(fd);
        if (offset != data.length) { *failure = TELAR_CLIPBOARD_FAILED; continue; }
        CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
        if (source != NULL && CGImageSourceGetCount(source) != 0) return source;
        if (source != NULL) CFRelease(source);
    }
    return NULL;
}

static CGImageSourceRef source_from_data(NSPasteboard *pasteboard, size_t max_source_bytes, int *failure) {
    NSArray<NSPasteboardType> *types = @[
        NSPasteboardTypePNG,
        NSPasteboardTypeTIFF,
        @"public.jpeg",
    ];
    for (NSPasteboardType type in types) {
        NSData *data = [pasteboard dataForType:type];
        if (data == nil || data.length == 0) continue;
        if (data.length > max_source_bytes) { *failure = TELAR_CLIPBOARD_TOO_LARGE; continue; }
        *failure = TELAR_CLIPBOARD_FAILED;
        CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
        if (source != NULL && CGImageSourceGetCount(source) != 0) return source;
        if (source != NULL) CFRelease(source);
    }
    return NULL;
}

static int telar_clipboard_copy_png(
    NSPasteboard *pasteboard,
    unsigned char **bytes,
    size_t *len,
    uint32_t *width,
    uint32_t *height,
    size_t max_source_bytes,
    size_t max_png_bytes,
    uint64_t max_pixels
) {
    if (bytes == NULL || len == NULL || width == NULL || height == NULL ||
        max_source_bytes == 0 || max_png_bytes == 0 || max_pixels == 0)
        return TELAR_CLIPBOARD_FAILED;

    *bytes = NULL;
    *len = 0;
    *width = 0;
    *height = 0;

    @autoreleasepool {
        int failure = TELAR_CLIPBOARD_NO_IMAGE;
        CGImageSourceRef source = source_from_file(pasteboard, max_source_bytes, &failure);
        if (source == NULL) source = source_from_data(pasteboard, max_source_bytes, &failure);
        if (source == NULL) return failure;

        int dimension_result = source_dimensions(source, width, height, max_pixels);
        if (dimension_result != TELAR_CLIPBOARD_OK) {
            CFRelease(source);
            return dimension_result;
        }

        NSMutableData *encoded = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (CFMutableDataRef)encoded,
            CFSTR("public.png"),
            1,
            NULL
        );
        if (destination == NULL) {
            CFRelease(source);
            return TELAR_CLIPBOARD_FAILED;
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, NULL);
        const bool encoded_ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CFRelease(source);
        if (!encoded_ok || encoded.length == 0) return TELAR_CLIPBOARD_FAILED;
        if (encoded.length > max_png_bytes) return TELAR_CLIPBOARD_TOO_LARGE;

        unsigned char *copy = malloc(encoded.length);
        if (copy == NULL) {
            [encoded resetBytesInRange:NSMakeRange(0, encoded.length)];
            return TELAR_CLIPBOARD_FAILED;
        }
        memcpy(copy, encoded.bytes, encoded.length);
        [encoded resetBytesInRange:NSMakeRange(0, encoded.length)];
        *bytes = copy;
        *len = encoded.length;
        return TELAR_CLIPBOARD_OK;
    }
}
