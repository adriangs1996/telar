#include "pasteboard_fixture.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <cstddef>
#include <cstdint>

namespace {

  constexpr std::size_t components = 4;
  constexpr std::size_t component_bits = 8;

  CFStringRef utiOf(std::uint8_t format) noexcept {
    switch (format) {
    case telar_test_image_tiff:
      return CFSTR("public.tiff");
    case telar_test_image_jpeg:
      return CFSTR("public.jpeg");
    default:
      return CFSTR("public.png");
    }
  }

  NSPasteboardType pasteboardTypeOf(std::uint8_t format) {
    switch (format) {
    case telar_test_image_tiff:
      return NSPasteboardTypeTIFF;
    case telar_test_image_jpeg:
      return @"public.jpeg";
    default:
      return NSPasteboardTypePNG;
    }
  }

  NSData* encodeSample(CFStringRef kind, const std::uint8_t* rgba_pixels, std::uint32_t width, std::uint32_t height) {
    auto* const color = CGColorSpaceCreateDeviceRGB();
    const auto byte_count = static_cast<std::size_t>(width) * static_cast<std::size_t>(height) * components;
    auto* const provider = CGDataProviderCreateWithData(nullptr, rgba_pixels, byte_count, nullptr);
    auto* const image = CGImageCreate(width, height, component_bits, component_bits * components, width * components, color, kCGImageAlphaLast, provider, nullptr, false, kCGRenderingIntentDefault);
    if (image == nullptr) {
      CGDataProviderRelease(provider);
      CGColorSpaceRelease(color);
      return nil;
    }

    NSMutableData* const data = [NSMutableData data];
    auto* const destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kind, 1, nullptr);
    bool success = false;

    if (destination != nullptr) {
      CGImageDestinationAddImage(destination, image, nullptr);
      success = CGImageDestinationFinalize(destination);
      CFRelease(destination);
    }

    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color);
    return success ? data : nil;
  }

}

void* telarTestPasteboardCreate(void) {
  @autoreleasepool {
    NSPasteboard* const board = [NSPasteboard pasteboardWithUniqueName];

    return (__bridge_retained void*)board;
  }
}

void telarTestPasteboardDestroy(void* board_handle) {
  if (board_handle == nullptr) {
    return;
  }

  @autoreleasepool {
    NSPasteboard* const board = (__bridge_transfer NSPasteboard*)board_handle;

    [board releaseGlobally];
  }
}

void telarTestPasteboardClear(void* board_handle) {
  @autoreleasepool {
    [(__bridge NSPasteboard*)board_handle clearContents];
  }
}

bool telarTestPasteboardSetSampleImage(void* board_handle, uint8_t format, const uint8_t* rgba_pixels, uint32_t width, uint32_t height) {
  @autoreleasepool {
    NSPasteboard* const board = (__bridge NSPasteboard*)board_handle;
    NSData* const data = encodeSample(utiOf(format), rgba_pixels, width, height);
    if (data == nil) {
      return false;
    }

    [board clearContents];
    return [board setData:data forType:pasteboardTypeOf(format)] == YES;
  }
}

bool telarTestPasteboardWritePngFile(const char* path_utf8, const uint8_t* rgba_pixels, uint32_t width, uint32_t height) {
  @autoreleasepool {
    NSString* const path = [NSString stringWithUTF8String:path_utf8];
    NSData* const data = encodeSample(CFSTR("public.png"), rgba_pixels, width, height);

    return path != nil && data != nil && [data writeToFile:path atomically:YES] == YES;
  }
}

bool telarTestPasteboardSetFileUrl(void* board_handle, const char* path_utf8) {
  @autoreleasepool {
    NSString* const path = [NSString stringWithUTF8String:path_utf8];
    if (path == nil) {
      return false;
    }

    NSPasteboard* const board = (__bridge NSPasteboard*)board_handle;

    [board clearContents];
    return [board writeObjects:@[ [NSURL fileURLWithPath:path] ]] == YES;
  }
}

bool telarTestBytesArePng(const void* bytes, size_t size) {
  @autoreleasepool {
    NSData* const data = [NSData dataWithBytes:bytes length:size];
    auto* const png = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    const bool valid = png != nullptr && CFEqual(CGImageSourceGetType(png), CFSTR("public.png")) != 0;

    if (png != nullptr) {
      CFRelease(png);
    }

    return valid;
  }
}
