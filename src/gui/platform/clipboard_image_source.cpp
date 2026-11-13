#include "platform/clipboard_image_source.hpp"

namespace telar::gui::platform {

const char *ClipboardImageFailure::what() const noexcept {
  switch (code_) {
  case ClipboardImageError::no_image:
    return "NoImageOnClipboard";
  case ClipboardImageError::changed:
    return "ClipboardChanged";
  case ClipboardImageError::source_bytes:
    return "ClipboardSourceTooLarge";
  case ClipboardImageError::png_bytes:
    return "ClipboardPngTooLarge";
  case ClipboardImageError::pixels:
    return "ClipboardPixelsTooLarge";
  case ClipboardImageError::invalid_image:
    return "InvalidClipboardImage";
  case ClipboardImageError::read_failed:
    return "ClipboardReadFailed";
  }

  return "ClipboardReadFailed";
}

}
