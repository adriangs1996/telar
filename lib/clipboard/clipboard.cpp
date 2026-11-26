module;
#include "src/macos/clipboard_bridge.h"

module telar.clipboard;

import std;
import telar.tbc;

namespace telar::clipboard {

  namespace {

    struct CaptureTarget {
      Content content;
    };

    std::uint8_t storeCaptured(void* context, const char* mime_literal, const unsigned char* bytes, std::size_t size) noexcept {
      try {
        auto& target = *static_cast<CaptureTarget*>(context);

        target.content.mime_type = mime_literal;
        target.content.bytes.clear();
        if (size != 0) {
#pragma clang unsafe_buffer_usage begin
          const std::span<const byte> slice{bytes, size};
#pragma clang unsafe_buffer_usage end

          target.content.bytes.assign(slice.begin(), slice.end());
        }

        return telar_clipboard_ok;
      } catch (const std::bad_alloc&) {
        return telar_clipboard_allocation_failed;
      } catch (const std::length_error&) {
        return telar_clipboard_allocation_failed;
      }
    }

  }

  extern "C++" {
  tbc::val_static<std::expected<Content, ReadError>> read(std::size_t maximum_bytes) {
    CaptureTarget target;
    const auto status = telarClipboardMacosRead(maximum_bytes, &storeCaptured, &target);

    switch (status) {
    case telar_clipboard_ok:
      return target.content;
    case telar_clipboard_no_supported_content:
      return std::unexpected(ReadError::no_supported_content);
    case telar_clipboard_encoding_failed:
      return std::unexpected(ReadError::encoding_failed);
    case telar_clipboard_changed:
      return std::unexpected(ReadError::changed);
    case telar_clipboard_allocation_failed:
      return std::unexpected(ReadError::allocation_failed);
    case telar_clipboard_content_too_large:
      return std::unexpected(ReadError::content_too_large);
    default:
      return std::unexpected(ReadError::read_failed);
    }
  }
  }

}
