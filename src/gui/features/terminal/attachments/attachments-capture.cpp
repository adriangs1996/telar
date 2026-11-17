module telar.gui.features.terminal.attachments;

import std;

import telar.gui.foundation.actions;
import telar.gui.foundation.keys;
import telar.wire.vocabulary;

namespace telar::gui::features::terminal::attachments {

  ClipboardCaptureState::ClipboardCaptureState(std::uint64_t next_id) noexcept
      : next_id_(next_id) {}

  const std::optional<ClipboardCapture>& ClipboardCaptureState::current() const noexcept {
    return capture_;
  }

  std::uint64_t ClipboardCaptureState::nextId() const noexcept {
    return next_id_;
  }

  std::optional<ClipboardCapture> ClipboardCaptureState::reserve(AttachmentTarget target) {
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

  std::optional<ClipboardCapture> ClipboardCaptureState::finish(std::uint64_t id) noexcept {
    if (!capture_ || capture_->id != id) {
      return std::nullopt;
    }

    const auto completed = capture_;

    capture_.reset();

    return completed;
  }

  bool ClipboardCaptureState::cancel(AttachmentTarget target) noexcept {
    if (!capture_ || capture_->target != target) {
      return false;
    }

    capture_.reset();

    return true;
  }

  AttachmentMarkerInput::AttachmentMarkerInput(AttachmentMarkerRemoval removal, const InputModes& modes) {
    if (removal.keyCount() > AttachmentLimits::maximum_removal_keys) {
      throw std::length_error{"AttachmentMarkerRemovalTooManyKeys"};
    }

    const auto movement = removal.direction == AttachmentMarkerDirection::left ? KeyChord::Key::left : KeyChord::Key::right;
    const auto restoration = removal.direction == AttachmentMarkerDirection::left ? KeyChord::Key::right : KeyChord::Key::left;
    const auto deletion = removal.deletion == AttachmentMarkerDeletion::backward ? KeyChord::Key::backspace : KeyChord::Key::erase;

    append(movement, removal.steps, modes);
    append(deletion, removal.deletions, modes);
    append(restoration, removal.steps, modes);
  }

  std::string_view AttachmentMarkerInput::view() const noexcept {
    return {bytes_.data(), used_};
  }

  void AttachmentMarkerInput::append(KeyChord::Key code, std::uint16_t count, const InputModes& modes) {
    KeyEncoder encoder;
    const auto bytes = encoder.encode(TerminalKey{.code = code}, modes);

    for (std::uint16_t index = 0; index < count; ++index) {
      if (bytes.size() > bytes_.size() - used_) {
        throw std::length_error{"AttachmentMarkerRemovalInputTooLarge"};
      }

      std::ranges::copy(bytes, bytes_.begin() + static_cast<std::ptrdiff_t>(used_));
      used_ += bytes.size();
    }
  }

  AttachmentPreviewSize AttachmentPreviewSize::fit(std::uint32_t width, std::uint32_t height, AttachmentPreviewBounds bounds) {
    if (width == 0 || height == 0) {
      throw std::invalid_argument{"InvalidClipboardImage"};
    }

    const auto source_width = static_cast<double>(width);
    const auto source_height = static_cast<double>(height);
    const auto side_scale = static_cast<double>(bounds.side) / std::max(source_width, source_height);
    const auto area_scale = std::sqrt(static_cast<double>(bounds.pixels) / (source_width * source_height));
    const auto scale = std::min({1.0, side_scale, area_scale});

    return {.width = std::max(1U, std::min(width, static_cast<std::uint32_t>(std::floor(source_width * scale)))), .height = std::max(1U, std::min(height, static_cast<std::uint32_t>(std::floor(source_height * scale))))};
  }

}
