#pragma once

#include "attachments/marker_removal.hpp"
#include "attachments/types.hpp"
#include "input/binding.hpp"
#include "input/key_encoder.hpp"
#include "input/terminal_key.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

class AttachmentMarkerInput {
public:
  explicit AttachmentMarkerInput(AttachmentMarkerRemoval removal, const InputModes &modes) {
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

  [[nodiscard]] std::string_view view() const noexcept {
    return {bytes_.data(), used_};
  }

private:
  void append(KeyChord::Key code, std::uint16_t count, const InputModes &modes) {
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

  std::array<char, AttachmentLimits::maximum_input_bytes> bytes_{};
  std::size_t used_ = 0;
};

}
