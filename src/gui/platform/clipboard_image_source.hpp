#pragma once

#include "features/terminal/attachments/capture.hpp"
#include "features/terminal/attachments/types.hpp"
#include "foundation/core/application_memory.hpp"
#include "tbc/view.hpp"
#include <cstdint>
#include <exception>
#ifndef __APPLE__
#include "telar_platform/file_descriptor.hpp"
#include <memory>
#endif

namespace telar::gui::platform {

  class ClipboardImageTransfer;
  class XcbClipboardImageMonitor;

  enum class ClipboardImageError : std::uint8_t {
    no_image,
    changed,
    source_bytes,
    png_bytes,
    pixels,
    invalid_image,
    read_failed,
  };

  // Header-only, as both platforms' sources, the pipe module and their tests throw or catch it; a
  // key function out of line would need a unit all of them link.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wweak-vtables"

  class ClipboardImageFailure final : public std::exception {
  public:
    explicit ClipboardImageFailure(ClipboardImageError code) noexcept
        : code_(code) {}

    [[nodiscard]] ClipboardImageError code() const noexcept {
      return code_;
    }

    [[nodiscard]] const char* what() const noexcept override {
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

  private:
    ClipboardImageError code_;
  };

#pragma clang diagnostic pop

  // Snapshot on the GUI thread; materialize and encode on one joined worker.
  // The source retains native clipboard ownership without retaining a window.
  class ClipboardImageSource {
  public:
#ifdef __APPLE__
    [[nodiscard]] static ClipboardImageSource retainPasteboard(void* pasteboard);
#endif
    ~ClipboardImageSource();
    ClipboardImageSource(const ClipboardImageSource&) = delete;
    ClipboardImageSource& operator=(const ClipboardImageSource&) = delete;
    ClipboardImageSource(ClipboardImageSource&& other) noexcept;
    ClipboardImageSource& operator=(ClipboardImageSource&& other) noexcept;

    // The capture is allocated from memory.
    [[nodiscard]] tbc::val_a<AttachmentCapture<ApplicationAllocator>> read(tbc::mut_a<ApplicationAllocator> memory, ClipboardCaptureRequest request) const;

  private:
    friend class ClipboardImageMonitor;
    friend class XcbClipboardImageMonitor;
    [[nodiscard]] static ClipboardImageSource snapshot(ApplicationAllocator& memory);
#ifndef __APPLE__
    [[nodiscard]] static ClipboardImageSource fromPipe(ApplicationAllocator& memory, runtime::FileDescriptor descriptor, std::shared_ptr<ClipboardImageTransfer> status = {});
#endif
    explicit ClipboardImageSource(void* native, std::int64_t revision) noexcept;
    void clear() noexcept;

    void* native_ = nullptr;
    std::int64_t revision_ = 0;
  };

}
