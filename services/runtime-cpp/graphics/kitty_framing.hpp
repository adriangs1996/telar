#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>

namespace telar::runtime {

class KittyFraming {
public:
  enum class Transition {
    started,
    ended
  };

  bool inside() const noexcept {
    return state_ == State::kitty;
  }

  bool touches(std::span<const std::uint8_t> bytes) noexcept {
    bool kitty = inside();
    std::size_t position = 0;
    while (advance(bytes, position)) {
      kitty = true;
    }
    return kitty;
  }

  std::optional<Transition> advance(std::span<const std::uint8_t> bytes, std::size_t &position) noexcept {
    while (position < bytes.size()) {
      if (state_ == State::ground) {
        const auto *escape = static_cast<const std::uint8_t *>(std::memchr(bytes.data() + position, escape_byte, bytes.size() - position));
        if (escape == nullptr) {
          position = bytes.size();
          return std::nullopt;
        }
        position = static_cast<std::size_t>(escape - bytes.data()) + 1;
        state_ = State::escape;
        continue;
      }

      const auto byte = bytes[position++];
      if (state_ == State::escape) {
        state_ = opens(byte) ? State::identify : byte == escape_byte ? State::escape
                                                                     : State::ground;
        continue;
      }
      if (ends(byte)) {
        const bool kitty = inside();
        state_ = byte == escape_byte ? State::escape : State::ground;
        if (kitty) {
          return Transition::ended;
        }
        continue;
      }
      if (state_ == State::identify && content(byte)) {
        state_ = byte == 'G' ? State::kitty : State::other;
        if (inside()) {
          return Transition::started;
        }
      }
    }
    return std::nullopt;
  }

  static bool content(std::uint8_t byte) noexcept {
    return byte < first_c1 && byte != cancel_byte && byte != substitute_byte && byte != escape_byte;
  }

private:
  enum class State {
    ground,
    escape,
    identify,
    kitty,
    other
  };

  static bool opens(std::uint8_t byte) noexcept {
    return byte == 'X' || byte == '^' || byte == '_' || byte == 0x98 || byte == 0x9e || byte == 0x9f;
  }

  static bool ends(std::uint8_t byte) noexcept {
    return byte == cancel_byte || byte == substitute_byte || byte == escape_byte || (byte >= first_c1 && byte <= 0x97) || (byte >= 0x99 && byte <= 0x9d);
  }

  static constexpr std::uint8_t escape_byte = 0x1b;
  static constexpr std::uint8_t cancel_byte = 0x18;
  static constexpr std::uint8_t substitute_byte = 0x1a;
  static constexpr std::uint8_t first_c1 = 0x80;
  State state_ = State::ground;
};

}
