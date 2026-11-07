#pragma once

#include "application/dependencies.hpp"
#include "attachments/capture.hpp"
#include "attachments/types.hpp"
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
  friend class ClipboardImageMonitor;
  friend class XcbClipboardImageMonitor;
  [[nodiscard]] static ClipboardImageSource snapshot(ApplicationAllocator &memory);
#ifndef __APPLE__
  [[nodiscard]] static ClipboardImageSource fromPipe(ApplicationAllocator &memory, runtime::FileDescriptor descriptor, std::shared_ptr<ClipboardImageTransfer> status = {});
#endif
  explicit ClipboardImageSource(void *native, std::int64_t revision) noexcept;
  void clear() noexcept;

  void *native_ = nullptr;
  std::int64_t revision_ = 0;
};

}
