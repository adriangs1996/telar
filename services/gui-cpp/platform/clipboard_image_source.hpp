#pragma once

#include "application/dependencies.hpp"
#include "attachments/catalog.hpp"
#include "attachments/types.hpp"
#include <cstdint>
#include <exception>

namespace telar::gui::platform {

enum class ClipboardImageError : std::uint8_t {
  no_image,
  changed,
  source_bytes,
  png_bytes,
  pixels,
  invalid_image,
  read_failed,
};

class ClipboardImageFailure final : public std::exception {
public:
  explicit ClipboardImageFailure(ClipboardImageError code) noexcept
      : code_(code) {}

  [[nodiscard]] ClipboardImageError code() const noexcept {
    return code_;
  }

  [[nodiscard]] const char *what() const noexcept override;

private:
  ClipboardImageError code_;
};

// Snapshot on the GUI thread; materialize and encode on one joined worker.
// The source retains native clipboard ownership without retaining a window.
class ClipboardImageSource {
public:
  [[nodiscard]] static ClipboardImageSource snapshot(ApplicationAllocator &memory);
#ifdef __APPLE__
  [[nodiscard]] static ClipboardImageSource retainPasteboard(void *pasteboard);
#endif
  ~ClipboardImageSource();
  ClipboardImageSource(const ClipboardImageSource &) = delete;
  ClipboardImageSource &operator=(const ClipboardImageSource &) = delete;
  ClipboardImageSource(ClipboardImageSource &&other) noexcept;
  ClipboardImageSource &operator=(ClipboardImageSource &&other) noexcept;

  [[nodiscard]] AttachmentCapture<ApplicationAllocator> read(ApplicationAllocator &memory, ClipboardCaptureRequest request) const;

private:
  explicit ClipboardImageSource(void *native, std::int64_t revision) noexcept;
  void clear() noexcept;

  void *native_ = nullptr;
  std::int64_t revision_ = 0;
};

}
