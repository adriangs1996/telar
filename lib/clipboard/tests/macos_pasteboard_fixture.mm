#include "macos_pasteboard_fixture.h"
#import <AppKit/AppKit.h>
#include <cstdint>
#include <random>

namespace {

  NSPasteboardType pasteboardTypeOf(std::uint8_t format) {
    switch (format) {
    case telar_test_clipboard_tiff:
      return NSPasteboardTypeTIFF;
    case telar_test_clipboard_jpeg:
      return @"public.jpeg";
    default:
      return NSPasteboardTypePNG;
    }
  }

  NSBitmapImageFileType encodingOf(std::uint8_t format) {
    switch (format) {
    case telar_test_clipboard_tiff:
      return NSBitmapImageFileTypeTIFF;
    case telar_test_clipboard_jpeg:
      return NSBitmapImageFileTypeJPEG;
    default:
      return NSBitmapImageFileTypePNG;
    }
  }

}

bool telarTestClipboardSetUtf8(const char* utf8, size_t size) {
  @autoreleasepool {
    NSString* const text = [[NSString alloc] initWithBytes:utf8 length:size encoding:NSUTF8StringEncoding];
    if (text == nil) {
      return false;
    }

    return [[NSPasteboard generalPasteboard] setString:text forType:NSPasteboardTypeString] == YES;
  }
}

bool telarTestClipboardSetEncodedImage(uint8_t format, bool also_set_text, TelarTestClipboardBytesCallback on_encoded, void* context) {
  @autoreleasepool {
    NSBitmapImageRep* const image = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:128 pixelsHigh:128 bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (image == nil || image.bitmapData == nullptr) {
      return false;
    }

    std::mt19937 random(0); // NOLINT(bugprone-random-generator-seed,cert-msc32-c,cert-msc51-cpp): a fixed seed keeps a failing image reproducible.

    for (NSInteger index = 0; index < image.bytesPerRow * image.pixelsHigh; ++index) {
      image.bitmapData[index] = static_cast<unsigned char>(random());
    }

    NSData* const data = [image representationUsingType:encodingOf(format) properties:@{}];
    if (data == nil || data.length <= 2048) {
      return false;
    }

    NSPasteboard* const board = [NSPasteboard generalPasteboard];
    if (![board setData:data forType:pasteboardTypeOf(format)]) {
      return false;
    }

    if (also_set_text && ![board setString:@"alternate text" forType:NSPasteboardTypeString]) {
      return false;
    }

    if (on_encoded != nullptr) {
      on_encoded(context, static_cast<const unsigned char*>(data.bytes), data.length);
    }

    return true;
  }
}

bool telarTestClipboardSetUnsupported(void) {
  @autoreleasepool {
    return [[NSPasteboard generalPasteboard] setData:[NSData dataWithBytes:"unsupported" length:11] forType:@"org.telar.unsupported"] == YES;
  }
}
