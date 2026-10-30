#pragma once

#include "attachments/types.hpp"
#include <cstdint>
#include <optional>
#include <stdexcept>

namespace telar::gui {

class ClipboardCaptureState {
public:
  explicit ClipboardCaptureState(std::uint64_t next_id = ClipboardCapture::first_id) noexcept
      : next_id_(next_id) {}

  [[nodiscard]] const std::optional<ClipboardCapture> &current() const noexcept {
    return capture_;
  }

  [[nodiscard]] std::uint64_t nextId() const noexcept {
    return next_id_;
  }

  [[nodiscard]] std::optional<ClipboardCapture> reserve(AttachmentTarget target) {
    if (capture_) {
      return std::nullopt;
    }

    if (next_id_ == ClipboardCapture::invalid_id) {
      throw std::overflow_error{"ClipboardCaptureIdExhausted"};
    }

    target.validate();
    capture_ = ClipboardCapture{.id = next_id_, .target = target};
    ++next_id_;

    return capture_;
  }

  [[nodiscard]] std::optional<ClipboardCapture> finish(std::uint64_t id) noexcept {
    if (!capture_ || capture_->id != id) {
      return std::nullopt;
    }

    const auto completed = capture_;
    capture_.reset();

    return completed;
  }

  bool cancel(AttachmentTarget target) noexcept {
    if (!capture_ || capture_->target != target) {
      return false;
    }

    capture_.reset();

    return true;
  }

private:
  std::uint64_t next_id_;
  std::optional<ClipboardCapture> capture_;
};

}
