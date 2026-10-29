#pragma once

#include "telar_client/codecs/telar_wire.hpp"
#include <cstddef>
#include <span>

namespace telar::gui {

class PlainText {
public:
  static std::size_t strip(std::span<const Byte> bytes, std::span<char> output) noexcept {
    State state = State::ground;
    std::size_t written = 0;
    for (const auto byte : bytes) {
      if (state != State::ground) {
        state = advance(state, byte);

        continue;
      }

      if (byte == escape) {
        state = State::escape;

        continue;
      }

      if (byte != '\n' && byte != '\t' && (byte < first_printable || byte == delete_control)) {
        continue;
      }

      if (written == output.size()) {
        return written;
      }

      output[written++] = static_cast<char>(byte);
    }

    return written;
  }

private:
  enum class State : Byte {
    ground,
    escape,
    intermediate,
    csi,
    string,
    string_escape,
  };

  static constexpr Byte escape = 0x1b;
  static constexpr Byte bell = 0x07;
  static constexpr Byte first_printable = 0x20;
  static constexpr Byte delete_control = 0x7f;
  static constexpr Byte first_intermediate = 0x20;
  static constexpr Byte last_intermediate = 0x2f;
  static constexpr Byte first_escape_final = 0x30;
  static constexpr Byte first_csi_final = 0x40;
  static constexpr Byte last_csi_final = 0x7e;

  static State escapeState(Byte byte) noexcept {
    switch (byte) {
    case '[':
      return State::csi;
    case ']':
    case 'P':
    case 'X':
    case '^':
    case '_':
      return State::string;
    case escape:
      return State::escape;
    default:
      return byte >= first_intermediate && byte <= last_intermediate ? State::intermediate : State::ground;
    }
  }

  static State advance(State state, Byte byte) noexcept {
    switch (state) {
    case State::escape:
      return escapeState(byte);
    case State::intermediate:
      if (byte == escape) {
        return State::escape;
      }

      return byte >= first_escape_final ? State::ground : State::intermediate;
    case State::csi:
      if (byte == escape) {
        return State::escape;
      }

      return byte >= first_csi_final && byte <= last_csi_final ? State::ground : State::csi;
    case State::string:
      if (byte == bell) {
        return State::ground;
      }

      return byte == escape ? State::string_escape : State::string;
    case State::string_escape:
      if (byte == '\\') {
        return State::ground;
      }

      return byte == escape ? State::string_escape : State::string;
    default:
      return State::ground;
    }
  }
};

}
