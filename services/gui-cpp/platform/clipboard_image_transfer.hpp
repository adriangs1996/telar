#pragma once

#include "platform/clipboard_image_source.hpp"
#include <atomic>
#include <optional>

namespace telar::gui::platform {

class ClipboardImageTransfer {
public:
  void fail(ClipboardImageError error) noexcept {
    if (failed_.load(std::memory_order_relaxed)) {
      return;
    }

    error_ = error;
    failed_.store(true, std::memory_order_release);
  }

  [[nodiscard]] std::optional<ClipboardImageError> failure() const noexcept {
    if (failed_.load(std::memory_order_acquire)) {
      return error_;
    }

    return std::nullopt;
  }

private:
  ClipboardImageError error_ = ClipboardImageError::read_failed;
  std::atomic<bool> failed_ = false;
};

}
