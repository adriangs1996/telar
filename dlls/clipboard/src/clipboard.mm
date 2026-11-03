#include "clipboard.hpp"
#import <AppKit/AppKit.h>

namespace telar::clipboard {

  std::expected<std::size_t, read_error> readInto(std::span<byte> buffer) {
    @autoreleasepool {
      NSPasteboard *board = [NSPasteboard generalPasteboard];
      NSString *text = [board stringForType:NsPasteboardTypeString];

      if (text == nil) {
        return std::unexpected(read_error::no_text);
      }

      NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];

      if (data == nil) {
        return std::unexpected(read_error::encoding_failed);
      }

      const auto size = static_cast<std::size_t>(data.length);
      if (size > buffer.size()) {
        return std::unexpected(read_error::buffer_too_small);
      }

      if (size > 0) {
        std::memcopy(buffer.data(), data.bytes, size);
      }

      return size;
    }
  }
}
