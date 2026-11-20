module;
#include "tbc/annotations.hpp"

export module telar.runtime.terminal.control:classification;

import std;
import :sequence;
import telar.base.ds;

export namespace telar::runtime::control {

  // The bytes of text, as the terminal's byte paths take them.
  TBC_HOT_PATH inline std::span<const std::uint8_t> byteView(std::string_view text) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the bytes may alias char, and no cast-free view reads text as bytes
#pragma clang unsafe_buffer_usage end
  }

  // The text of bytes, as the parsers of a sequence's body read them.
  TBC_HOT_PATH inline std::string_view textView(std::span<const std::uint8_t> bytes) noexcept {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view reads bytes as text
  }

  inline constexpr ds::Array<std::uint16_t, 5> desktop_modes{1004, 2031, 2033, 2048, 5522};

  // Generic over the caller's writer, so it stays here. The final byte is a char and nothing that
  // converts to one, so a mode number cannot take its place.
  template <typename Writer>
  TBC_GENERIC void forwardPrivateMode(std::uint16_t mode, std::same_as<char> auto final, Writer&& write) {
    // ESC [ ? and a final byte around five decimal digits.
    constexpr std::size_t command_capacity = 16;
    constexpr std::string_view prefix = "\x1b[?";
    ds::Array<char, command_capacity> command{};
    const auto output = command.viewMut();

    std::ranges::copy(prefix, output.begin());
    const auto digits = output.subspan(prefix.size()).first(output.size() - prefix.size() - 1);
    const auto number = std::to_chars(digits.data(), std::to_address(digits.end()), mode);
    const auto length = static_cast<std::size_t>(number.ptr - output.data());

    output[length] = final;
    std::forward<Writer>(write)(byteView(std::string_view{std::span<const char>{output}.first(length + 1)}));
  }

  // The OSC operations ghostty answers itself: colors, palette and clipboard.
  constexpr bool nativeOsc(unsigned number) noexcept {
    constexpr unsigned palette = 4;
    constexpr unsigned special_color = 5;
    constexpr unsigned first_dynamic_color = 10;
    constexpr unsigned last_dynamic_color = 21;
    constexpr unsigned clipboard = 52;
    constexpr unsigned first_color_reset = 104;
    constexpr unsigned last_color_reset = 119;
    constexpr unsigned kitty_colors = 5522;

    return number == palette || number == special_color || (number >= first_dynamic_color && number <= last_dynamic_color) || number == clipboard || (number >= first_color_reset && number <= last_color_reset) || number == kitty_colors;
  }

  constexpr ds::Option<unsigned> decimal(std::string_view text) noexcept {
    if (text.empty()) {
      return ds::none;
    }

    constexpr unsigned base = 10;
    unsigned value = 0;

    for (const auto byte : text) {
      if (byte < '0' || byte > '9' || value > (std::numeric_limits<std::uint16_t>::max() - static_cast<unsigned>(byte - '0')) / base) {
        return ds::none;
      }

      value = (value * base) + static_cast<unsigned>(byte - '0');
    }

    return value;
  }

  constexpr ds::Option<unsigned> oscOperation(std::string_view text) noexcept {
    if (text.size() > 1 && text.front() == '0') {
      return ds::none;
    }

    return decimal(text);
  }

  bool graphicsQuery(std::string_view body) noexcept;

  bool streamable(Sequence sequence) noexcept;

  bool query(Sequence sequence) noexcept;

  // The first `count` characters of text, or all of it: substr(0, count) without its throw.
  constexpr std::string_view textPrefix(std::string_view text, std::size_t count) noexcept {
    text.remove_suffix(text.size() - std::min(count, text.size()));
    return text;
  }

  // Text past its first `offset` characters, or nothing: substr(offset) without its throw.
  constexpr std::string_view textAfter(std::string_view text, std::size_t offset) noexcept {
    text.remove_prefix(std::min(offset, text.size()));
    return text;
  }

}
