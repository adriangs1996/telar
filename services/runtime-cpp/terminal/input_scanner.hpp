#pragma once

#include "../memory/erase_sensitive.hpp"
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::runtime {

enum class ControlByte : std::uint8_t {
  cancel = 0x03,
  bell = 0x07,
  backspace = 0x08,
  newline = 0x0a,
  clear_screen = 0x0c,
  carriage_return = 0x0d,
  escape = 0x1b,
  delete_previous = 0x7f,
};

struct InputEvent {
  bool submitted = false;
  bool cancelled = false;
};

class InputScanner {
public:
  InputEvent feed(std::span<const std::uint8_t> bytes) noexcept {
    InputEvent event;
    for (const auto byte : bytes) {
      consume(byte, event);
    }

    return event;
  }

  void reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_length_ = 0;
    typed_exact_ = true;
  }

  void clearSensitive() noexcept {
    eraseSensitive(typed_.data(), typed_.size());
    reset();
  }

  std::optional<std::string_view> typedText() const noexcept {
    if (!typed_exact_) {
      return std::nullopt;
    }

    return std::string_view{typed_.data(), typed_length_};
  }

private:
  enum class State {
    ground,
    escape,
    csi,
    paste,
    paste_escape,
    paste_csi
  };
  enum class PasteMarker : std::uint16_t {
    begin = 200,
    end = 201
  };
  static constexpr std::size_t maximum_typed_bytes = 255;

  void consume(std::uint8_t byte, InputEvent &event) noexcept {
    const auto control = static_cast<ControlByte>(byte);
    switch (state_) {
    case State::ground:
      if (control == ControlByte::escape) {
        state_ = State::escape;
        typed_exact_ = false;
      } else if (control == ControlByte::carriage_return || control == ControlByte::newline) {
        event.submitted = true;
      } else if (control == ControlByte::cancel) {
        event.cancelled = true;
      } else if (control == ControlByte::backspace || control == ControlByte::delete_previous) {
        if (typed_length_ != 0) {
          --typed_length_;
        }
      } else if (control != ControlByte::clear_screen) {
        if (byte >= ' ' && byte <= '~' && typed_length_ < typed_.size()) {
          typed_[typed_length_++] = static_cast<char>(byte);
        } else {
          typed_exact_ = false;
        }
      }
      break;
    case State::escape:
      if (byte == '[') {
        startSequence(State::csi);
      } else {
        state_ = State::ground;
      }
      break;
    case State::csi:
      sequenceByte(byte, false);
      break;
    case State::paste:
      if (control == ControlByte::escape) {
        state_ = State::paste_escape;
      }
      break;
    case State::paste_escape:
      if (byte == '[') {
        startSequence(State::paste_csi);
      } else {
        state_ = State::paste;
      }
      break;
    case State::paste_csi:
      sequenceByte(byte, true);
      break;
    }
  }

  void startSequence(State state) noexcept {
    state_ = state;
    parameter_ = 0;
    has_parameter_ = false;
  }

  void sequenceByte(std::uint8_t byte, bool pasted) noexcept {
    if (byte >= '0' && byte <= '9') {
      has_parameter_ = true;
      const auto next = static_cast<std::uint32_t>(parameter_) * 10 + byte - '0';
      parameter_ = static_cast<std::uint16_t>(next > UINT16_MAX ? UINT16_MAX : next);
      return;
    }

    if (byte == '~' && has_parameter_) {
      if (!pasted && parameter_ == static_cast<std::uint16_t>(PasteMarker::begin)) {
        state_ = State::paste;
        return;
      }
      if (pasted && parameter_ == static_cast<std::uint16_t>(PasteMarker::end)) {
        state_ = State::ground;
        return;
      }
    }

    state_ = pasted ? State::paste : State::ground;
  }

  State state_ = State::ground;
  std::uint16_t parameter_ = 0;
  bool has_parameter_ = false;
  std::array<char, maximum_typed_bytes> typed_;
  std::size_t typed_length_ = 0;
  bool typed_exact_ = true;
};

}
