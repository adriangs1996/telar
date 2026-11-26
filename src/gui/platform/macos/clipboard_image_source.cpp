module;
#include "platform/macos/clipboard_image_bridge.h"

module telar.gui.platform;

import std;
import telar.tbc;

namespace telar::gui::platform {

  namespace {

    // Bytes a C API hands over as a pointer and a length: the one place the two meet a span.
    template <typename Byte>
    std::span<Byte> cBytes(Byte* data, std::size_t size) noexcept {
#pragma clang unsafe_buffer_usage begin
      return {data, size};
#pragma clang unsafe_buffer_usage end
    }

    struct PngWriter {
      SensitiveBytes<ApplicationAllocator> bytes;
      std::exception_ptr failure;

      static std::size_t write(void* writer_context, const void* writer_bytes, std::size_t size) noexcept {
        return append(*static_cast<PngWriter*>(writer_context), cBytes(static_cast<const std::byte*>(writer_bytes), size));
      }

      static std::size_t append(PngWriter& writer, std::span<const std::byte> bytes) noexcept {
        if (writer.failure != nullptr) {
          return 0;
        }

        try {
          writer.bytes.append(bytes, AttachmentLimits::maximum_png_bytes);
        } catch (...) {
          writer.failure = std::current_exception();
          return 0;
        }

        return bytes.size();
      }
    };

    [[noreturn]] void throwClipboardStatus(std::uint8_t status) {
      switch (status) {
      case telar_gui_clipboard_no_image:
        throw ClipboardImageFailure{ClipboardImageError::no_image};
      case telar_gui_clipboard_changed:
        throw ClipboardImageFailure{ClipboardImageError::changed};
      case telar_gui_clipboard_source_bytes:
        throw ClipboardImageFailure{ClipboardImageError::source_bytes};
      case telar_gui_clipboard_png_bytes:
        throw ClipboardImageFailure{ClipboardImageError::png_bytes};
      case telar_gui_clipboard_pixels:
        throw ClipboardImageFailure{ClipboardImageError::pixels};
      case telar_gui_clipboard_invalid_image:
        throw ClipboardImageFailure{ClipboardImageError::invalid_image};
      case telar_gui_clipboard_bad_alloc:
        throw std::bad_alloc{};
      default:
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }
    }

  }

  ClipboardImageSource::ClipboardImageSource(void* native, std::int64_t revision) noexcept
      : native_(native),
        revision_(revision) {}

  ClipboardImageSource ClipboardImageSource::snapshot([[maybe_unused]] ApplicationAllocator& memory) {
    std::int64_t revision = 0;
    void* const native = telarGuiClipboardGeneralPasteboard(&revision);
    if (native == nullptr) {
      throw ClipboardImageFailure{ClipboardImageError::no_image};
    }

    return ClipboardImageSource{native, revision};
  }

  ClipboardImageSource ClipboardImageSource::retainPasteboard(void* pasteboard) {
    std::int64_t revision = 0;
    void* const native = telarGuiClipboardRetainPasteboard(pasteboard, &revision);
    if (native == nullptr) {
      throw ClipboardImageFailure{ClipboardImageError::no_image};
    }

    return ClipboardImageSource{native, revision};
  }

  ClipboardImageSource::~ClipboardImageSource() {
    clear();
  }

  ClipboardImageSource::ClipboardImageSource(ClipboardImageSource&& other) noexcept
      : native_(std::exchange(other.native_, nullptr)),
        revision_(other.revision_) {}

  ClipboardImageSource& ClipboardImageSource::operator=(ClipboardImageSource&& other) noexcept {
    if (this != &other) {
      clear();
      native_ = std::exchange(other.native_, nullptr);
      revision_ = other.revision_;
    }

    return *this;
  }

  void ClipboardImageSource::clear() noexcept {
    if (native_ != nullptr) {
      telarGuiClipboardReleasePasteboard(native_);
      native_ = nullptr;
    }
  }

  tbc::val_a<AttachmentCapture<ApplicationAllocator>> ClipboardImageSource::read(tbc::mut_a<ApplicationAllocator> memory, ClipboardCaptureRequest request) const {
    PngWriter writer{.bytes = SensitiveBytes<ApplicationAllocator>{memory}, .failure = nullptr};
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    const auto status = telarGuiClipboardReadPng(
        native_,
        revision_,
        AttachmentLimits::maximum_source_bytes,
        AttachmentLimits::maximum_pixels,
        &PngWriter::write,
        tbc::raw(&writer),
        &width,
        &height
    );

    if (writer.failure != nullptr) {
      try {
        std::rethrow_exception(writer.failure);
      } catch (const std::length_error&) {
        throw ClipboardImageFailure{ClipboardImageError::png_bytes};
      }
    }

    if (status != telar_gui_clipboard_ok) {
      throwClipboardStatus(status);
    }

    if (writer.bytes.size() == 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    request.capture.target.validate();
    return {.request = request, .png = std::move(writer.bytes), .width = width, .height = height};
  }

}
