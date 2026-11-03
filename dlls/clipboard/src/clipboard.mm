#include "clipboard.hpp"
#import <AppKit/AppKit.h>
#include <new>
#include <stdexcept>

namespace telar::clipboard {
  namespace {
    content copyData(NSData *data, std::string_view mime_type) {
      content result{.mime_type = mime_type, .bytes = {}};
      if (data.length != 0) {
        const auto *bytes = static_cast<const byte *>(data.bytes);
        result.bytes.assign(bytes, bytes + data.length);
      }

      return result;
    }

    std::expected<content, read_error> capture(NSPasteboard *board) {
      struct image_format {
        NSPasteboardType type;
        std::string_view mime_type;
      };

      const image_format formats[] = {
          {NSPasteboardTypePNG, "image/png"},
          {@"public.jpeg", "image/jpeg"},
          {NSPasteboardTypeTIFF, "image/tiff"},
      };

      // Prefer PNG/JPEG over TIFF, which AppKit can synthesize for legacy consumers.
      NSArray<NSPasteboardType> *types = board.types;
      for (const auto &format : formats) {
        if (![types containsObject:format.type]) {
          continue;
        }

        NSData *data = [board dataForType:format.type];
        if (data == nil || data.length == 0) {
          continue;
        }

        return copyData(data, format.mime_type);
      }

      NSString *text = [board stringForType:NSPasteboardTypeString];
      if (text == nil) {
        return std::unexpected(read_error::no_supported_content);
      }

      NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
      if (data == nil) {
        return std::unexpected(read_error::encoding_failed);
      }

      return copyData(data, "text/plain;charset=utf-8");
    }
  }

  std::expected<content, read_error> read() {
    @autoreleasepool {
      NSPasteboard *board = [NSPasteboard generalPasteboard];
      const auto revision = board.changeCount;

      try {
        auto result = capture(board);
        if (board.changeCount != revision) {
          return std::unexpected(read_error::changed);
        }

        return result;
      } catch (const std::bad_alloc &) {
        return std::unexpected(read_error::allocation_failed);
      } catch (const std::length_error &) {
        return std::unexpected(read_error::allocation_failed);
      }
    }
  }
}
