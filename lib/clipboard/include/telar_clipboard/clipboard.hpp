#ifndef TELAR_CLIPBOARD_CLIPBOARD_HPP
#define TELAR_CLIPBOARD_CLIPBOARD_HPP

#include "tbc/view.hpp"
#include <cstddef>
#include <cstdint>
#include <expected>
#include <string_view>
#include <vector>

namespace telar::clipboard {
  using byte = unsigned char;

  enum class ReadError : std::uint8_t {
    no_supported_content,
    encoding_failed,
    changed,
    allocation_failed,
    session_unavailable,
    unsupported_protocol,
    read_failed,
    timed_out,
    content_too_large,
    backend_unavailable,
  };

  constexpr const char* errorMessage(ReadError error) noexcept {
    switch (error) {
    case ReadError::no_supported_content:
      return "Clipboard contains no supported text or image.";
    case ReadError::encoding_failed:
      return "Could not encode clipboard text as UTF-8.";
    case ReadError::changed:
      return "Clipboard changed while reading; try again.";
    case ReadError::allocation_failed:
      return "Not enough memory to read the clipboard.";
    case ReadError::session_unavailable:
      return "Cannot connect to the graphical session; check WAYLAND_DISPLAY, XDG_RUNTIME_DIR or DISPLAY.";
    case ReadError::unsupported_protocol:
      return "The Wayland compositor does not expose wlr-data-control clipboard access.";
    case ReadError::read_failed:
      return "Could not transfer clipboard content.";
    case ReadError::timed_out:
      return "Clipboard transfer timed out.";
    case ReadError::content_too_large:
      return "Clipboard content exceeds the byte limit.";
    case ReadError::backend_unavailable:
      return "This build has no native clipboard support.";
    }

    return "Unknown clipboard error.";
  }

  struct Content {
    std::string_view mime_type;
    std::vector<byte> bytes;
  };

  inline constexpr std::size_t default_maximum_bytes = std::size_t{32} * 1024 * 1024;

  // Every MIME type is a string literal, so the result outlives the backend that produced it.
  tbc::val_static<std::expected<Content, ReadError>> read(std::size_t maximum_bytes = default_maximum_bytes);
} // namespace telar::clipboard

#endif // TELAR_CLIPBOARD_CLIPBOARD_HPP
