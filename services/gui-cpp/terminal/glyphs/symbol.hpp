#pragma once

#include "core/unicode_scalar.hpp"
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui::glyphs {

enum class SymbolKind : std::uint8_t {
  box,
  block,
  braille,
};

struct Symbol {
  static constexpr std::uint32_t first_box = 0x2500;
  static constexpr std::uint32_t last_box = 0x257f;
  static constexpr std::uint32_t first_box_curve = 0x256d;
  static constexpr std::uint32_t last_box_curve = 0x2573;
  static constexpr std::uint32_t first_block = 0x2580;
  static constexpr std::uint32_t last_block = 0x259f;
  static constexpr std::uint32_t first_braille = 0x2800;
  static constexpr std::uint32_t last_braille = 0x28ff;

  SymbolKind kind = SymbolKind::box;
  std::uint32_t codepoint = 0;

  [[nodiscard]] static std::optional<Symbol> parse(std::string_view text) noexcept {
    constexpr std::uint8_t symbol_prefix = 0xe2;
    constexpr unsigned continuation_prefix_mask = 0xc0;
    constexpr std::size_t symbol_bytes = 3;
    if (text.size() != symbol_bytes || static_cast<std::uint8_t>(text[0]) != symbol_prefix) {
      return {};
    }

    const auto middle = static_cast<std::uint8_t>(text[1]);
    const auto last = static_cast<std::uint8_t>(text[2]);
    if ((middle & continuation_prefix_mask) != Utf8Scalar::continuation_prefix || (last & continuation_prefix_mask) != Utf8Scalar::continuation_prefix) {
      return {};
    }

    const auto codepoint = ((symbol_prefix & Utf8Scalar::leading_masks[symbol_bytes - 1]) << (2 * Utf8Scalar::continuation_bits)) | ((middle & Utf8Scalar::continuation_mask) << Utf8Scalar::continuation_bits) | (last & Utf8Scalar::continuation_mask);
    if (codepoint >= first_box && codepoint <= last_box) {
      return Symbol{.kind = SymbolKind::box, .codepoint = codepoint};
    }

    if (codepoint >= first_block && codepoint <= last_block) {
      return Symbol{.kind = SymbolKind::block, .codepoint = codepoint};
    }

    if (codepoint >= first_braille && codepoint <= last_braille) {
      return Symbol{.kind = SymbolKind::braille, .codepoint = codepoint};
    }

    return {};
  }
};

}
