#pragma once

#include "core/unicode_scalar.hpp"
#include "face.hpp"
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

struct FontCoverage {
  [[nodiscard]] static bool covers(const Face &face, std::string_view text) {
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontCoverageUtf8"};
      }

      const auto codepoint = Utf8Scalar::decode(text.substr(0, length));
      if (!isSelectorOrJoiner(codepoint) && !face.covers(static_cast<char32_t>(codepoint))) {
        return false;
      }

      text.remove_prefix(length);
    }

    return true;
  }

  [[nodiscard]] static bool isSelectorOrJoiner(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t non_joiner = 0x200c;
    constexpr std::uint32_t joiner = 0x200d;
    constexpr std::uint32_t first_selector = 0xfe00;
    constexpr std::uint32_t last_selector = 0xfe0f;
    constexpr std::uint32_t first_extended_selector = 0xe0100;
    constexpr std::uint32_t last_extended_selector = 0xe01ef;

    return codepoint == non_joiner || codepoint == joiner || (codepoint >= first_selector && codepoint <= last_selector) || (codepoint >= first_extended_selector && codepoint <= last_extended_selector);
  }
};

}
