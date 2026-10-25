#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <optional>

namespace telar::runtime {

class CommandInputScanner {
public:
  struct Event {
    bool submitted = false;
    bool cancelled = false;
  };

  Event feed(std::span<const Byte> bytes) noexcept {
    Event event;
    for (const auto byte : bytes) {
      switch (state_) {
      case State::ground:
        ground(byte, event);
        break;
      case State::escape:
        beginSequence(byte, false);
        break;
      case State::sequence:
        sequence(byte, false);
        break;
      case State::paste:
        if (byte == escape) {
          state_ = State::paste_escape;
        }
        break;
      case State::paste_escape:
        beginSequence(byte, true);
        break;
      case State::paste_sequence:
        sequence(byte, true);
        break;
      }
    }

    return event;
  }

  void reset() noexcept {
    state_ = State::ground;
    parameter_ = 0;
    has_parameter_ = false;
    typed_count_ = 0;
    typed_exact_ = true;
  }

  std::optional<std::string_view> typedText() const noexcept {
    return typed_exact_ ? std::optional<std::string_view>{{typed_.data(), typed_count_}} : std::nullopt;
  }

private:
  enum class State {
    ground,
    escape,
    sequence,
    paste,
    paste_escape,
    paste_sequence
  };
  static constexpr Byte escape = 0x1b;
  static constexpr unsigned paste_start = 200;
  static constexpr unsigned paste_end = 201;

  void ground(Byte byte, Event &event) noexcept {
    switch (byte) {
    case escape:
      state_ = State::escape;
      typed_exact_ = false;
      break;
    case '\r':
    case '\n':
      event.submitted = true;
      break;
    case 0x03:
      event.cancelled = true;
      break;
    case 0x08:
    case 0x7f:
      typed_count_ -= typed_count_ != 0;
      break;
    case 0x0c:
      break;
    default:
      if (byte >= 0x20 && byte <= 0x7e && typed_count_ < typed_.size()) {
        typed_[typed_count_++] = static_cast<char>(byte);
      } else {
        typed_exact_ = false;
      }
      break;
    }
  }

  void beginSequence(Byte byte, bool pasted) noexcept {
    if (byte == '[') {
      state_ = pasted ? State::paste_sequence : State::sequence;
      parameter_ = 0;
      has_parameter_ = false;
    } else {
      state_ = pasted ? State::paste : State::ground;
    }
  }

  void sequence(Byte byte, bool pasted) noexcept {
    if (byte >= '0' && byte <= '9') {
      parameter_ = std::min<unsigned>(UINT16_MAX, parameter_ * 10 + byte - '0');
      has_parameter_ = true;
      return;
    }

    if (byte == '~' && has_parameter_) {
      if (!pasted && parameter_ == paste_start) {
        state_ = State::paste;
        return;
      }

      if (pasted && parameter_ == paste_end) {
        state_ = State::ground;
        return;
      }
    }

    state_ = pasted ? State::paste : State::ground;
  }

  State state_ = State::ground;
  unsigned parameter_ = 0;
  bool has_parameter_ = false;
  std::array<char, 255> typed_{};
  std::size_t typed_count_ = 0;
  bool typed_exact_ = true;
};

}
