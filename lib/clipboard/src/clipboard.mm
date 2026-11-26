#include "macos/clipboard_bridge.h"
#import <AppKit/AppKit.h>
#include <array>
#include <cstddef>
#include <cstdint>

namespace {

  std::uint8_t copyData(NSData* data, const char* mime_literal, std::size_t maximum_bytes, TelarClipboardStoreCallback store, void* context) {
    if (data.length > maximum_bytes) {
      return telar_clipboard_content_too_large;
    }

    return store(context, mime_literal, static_cast<const unsigned char*>(data.bytes), data.length);
  }

  std::uint8_t capture(NSPasteboard* board, std::size_t maximum_bytes, TelarClipboardStoreCallback store, void* context) {
    struct ImageFormat {
      NSPasteboardType type;
      const char* mime_type;
    };

    const std::array formats{
        ImageFormat{.type = NSPasteboardTypePNG, .mime_type = "image/png"},
        ImageFormat{.type = @"public.jpeg", .mime_type = "image/jpeg"},
        ImageFormat{.type = NSPasteboardTypeTIFF, .mime_type = "image/tiff"},
    };

    // Prefer PNG/JPEG over TIFF, which AppKit can synthesize for legacy consumers.
    NSArray<NSPasteboardType>* const types = board.types;

    for (const auto& format : formats) {
      if (![types containsObject:format.type]) {
        continue;
      }

      NSData* const data = [board dataForType:format.type];
      if (data == nil || data.length == 0) {
        continue;
      }

      return copyData(data, format.mime_type, maximum_bytes, store, context);
    }

    NSString* const text = [board stringForType:NSPasteboardTypeString];
    if (text == nil) {
      return telar_clipboard_no_supported_content;
    }

    NSData* const data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
      return telar_clipboard_encoding_failed;
    }

    return copyData(data, "text/plain;charset=utf-8", maximum_bytes, store, context);
  }

}

uint8_t telarClipboardMacosRead(size_t maximum_bytes, TelarClipboardStoreCallback store, void* context) {
  @autoreleasepool {
    NSPasteboard* const board = [NSPasteboard generalPasteboard];
    const auto revision = board.changeCount;
    const auto status = capture(board, maximum_bytes, store, context);

    if (board.changeCount != revision) {
      return telar_clipboard_changed;
    }

    return status;
  }
}
