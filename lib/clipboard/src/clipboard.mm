#include "telar_clipboard/clipboard.hpp"
#import <AppKit/AppKit.h>
#include <array>
#include <new>
#include <span>
#include <stdexcept>

namespace telar::clipboard {
  namespace {
    std::expected<Content, ReadError> copyData(NSData* data, std::string_view mime_type, std::size_t maximum_bytes) {
      if (data.length > maximum_bytes) {
        return std::unexpected(ReadError::content_too_large);
      }

      Content result{.mime_type = mime_type, .bytes = {}};

      if (data.length != 0) {
        // NSData hands out its bytes and their length.
#pragma clang unsafe_buffer_usage begin
        const std::span<const byte> bytes{static_cast<const byte*>(data.bytes), data.length};
#pragma clang unsafe_buffer_usage end

        result.bytes.assign(bytes.begin(), bytes.end());
      }

      return result;
    }

    std::expected<Content, ReadError> capture(NSPasteboard* board, std::size_t maximum_bytes) {
      struct ImageFormat {
        NSPasteboardType type;
        std::string_view mime_type;
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

        return copyData(data, format.mime_type, maximum_bytes);
      }

      NSString* const text = [board stringForType:NSPasteboardTypeString];
      if (text == nil) {
        return std::unexpected(ReadError::no_supported_content);
      }

      NSData* const data = [text dataUsingEncoding:NSUTF8StringEncoding];
      if (data == nil) {
        return std::unexpected(ReadError::encoding_failed);
      }

      return copyData(data, "text/plain;charset=utf-8", maximum_bytes);
    }
  }

  std::expected<Content, ReadError> read(std::size_t maximum_bytes) {
    @autoreleasepool {
      NSPasteboard* const board = [NSPasteboard generalPasteboard];
      const auto revision = board.changeCount;

      try {
        auto result = capture(board, maximum_bytes);

        if (board.changeCount != revision) {
          result = std::unexpected(ReadError::changed);
        }

        return result;
      } catch (const std::bad_alloc&) {
        return std::unexpected(ReadError::allocation_failed);
      } catch (const std::length_error&) {
        return std::unexpected(ReadError::allocation_failed);
      }
    }
  }
}
