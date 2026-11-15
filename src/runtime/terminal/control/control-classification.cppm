module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:classification;

import std;
import :sequence;

export namespace telar::runtime::control {

  inline constexpr std::array<std::uint16_t, 5> desktop_modes{1004, 2031, 2033, 2048, 5522};

  // Generic over the caller's writer, so it stays here.
  template <typename Writer>
  TBC_GENERIC void forwardPrivateMode(std::uint16_t mode, char final, Writer&& write) {
    std::array<char, 16> command;
    constexpr std::string_view prefix = "\x1b[?";

    std::copy(prefix.begin(), prefix.end(), command.begin());
    const auto number = std::to_chars(command.data() + prefix.size(), command.data() + command.size() - 1, mode);

    *number.ptr = final;
    write(std::span<const std::uint8_t>{reinterpret_cast<const std::uint8_t*>(command.data()), static_cast<std::size_t>(number.ptr + 1 - command.data())});
  }

  constexpr bool nativeOsc(unsigned number) noexcept {
    return number == 4 || number == 5 || (number >= 10 && number <= 21) || number == 52 || (number >= 104 && number <= 119) || number == 5522;
  }

  constexpr std::optional<unsigned> decimal(std::string_view text) noexcept {
    if (text.empty()) {
      return std::nullopt;
    }

    unsigned value = 0;

    for (const auto byte : text) {
      if (byte < '0' || byte > '9' || value > (std::numeric_limits<std::uint16_t>::max() - static_cast<unsigned>(byte - '0')) / 10) {
        return std::nullopt;
      }

      value = value * 10 + static_cast<unsigned>(byte - '0');
    }

    return value;
  }

  constexpr std::optional<unsigned> oscOperation(std::string_view text) noexcept {
    if (text.size() > 1 && text.front() == '0') {
      return std::nullopt;
    }

    return decimal(text);
  }

  bool graphicsQuery(std::string_view body) noexcept;

  bool streamable(Sequence sequence) noexcept;

  bool query(Sequence sequence) noexcept;

}
