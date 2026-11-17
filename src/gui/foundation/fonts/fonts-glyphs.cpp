module telar.gui.foundation.fonts;

import std;

import telar.gui.foundation.core;

namespace telar::gui::inline foundation::inline fonts::glyphs {

  bool BoxEdges::empty() const noexcept {
    return up == BoxWeight::none && right == BoxWeight::none && down == BoxWeight::none && left == BoxWeight::none;
  }

  void BoxEdges::simplifyDoubles() noexcept {
    for (auto* edge : {&up, &right, &down, &left}) {
      if (*edge == BoxWeight::double_line) {
        *edge = BoxWeight::light;
      }
    }
  }

  float BoxStroke::pixels(std::uint16_t pixel_height) const noexcept {
    constexpr float fallback_divisor = 16;
    const auto height = static_cast<float>(pixel_height);
    const auto thickness = units_per_em == 0 || underline_thickness <= 0 ? height / fallback_divisor : static_cast<float>(underline_thickness) * height / static_cast<float>(units_per_em);

    return std::max(1.0F, std::ceil(thickness));
  }

  std::optional<Symbol> Symbol::parse(std::string_view text) noexcept {
    // Lead bytes of U+2000..U+2FFF (box, block, Braille) and U+E000..U+EFFF (Powerline).
    constexpr std::uint8_t symbol_prefix = 0xe2;
    constexpr std::uint8_t private_use_prefix = 0xee;
    constexpr unsigned continuation_prefix_mask = 0xc0;
    constexpr std::size_t symbol_bytes = 3;
    if (text.size() != symbol_bytes) {
      return {};
    }

    const auto lead = static_cast<std::uint8_t>(text[0]);
    if (lead != symbol_prefix && lead != private_use_prefix) {
      return {};
    }

    const auto middle = static_cast<std::uint8_t>(text[1]);
    const auto last = static_cast<std::uint8_t>(text[2]);
    if ((middle & continuation_prefix_mask) != Utf8Scalar::continuation_prefix || (last & continuation_prefix_mask) != Utf8Scalar::continuation_prefix) {
      return {};
    }

    const auto codepoint = ((lead & Utf8Scalar::leading_masks[symbol_bytes - 1]) << (2 * Utf8Scalar::continuation_bits)) | ((middle & Utf8Scalar::continuation_mask) << Utf8Scalar::continuation_bits) | (last & Utf8Scalar::continuation_mask);
    if (codepoint >= first_box && codepoint <= last_box) {
      return Symbol{.kind = SymbolKind::box, .codepoint = codepoint};
    }

    if (codepoint >= first_block && codepoint <= last_block) {
      return Symbol{.kind = SymbolKind::block, .codepoint = codepoint};
    }

    if (codepoint >= first_braille && codepoint <= last_braille) {
      return Symbol{.kind = SymbolKind::braille, .codepoint = codepoint};
    }

    if (codepoint >= first_powerline && codepoint <= last_powerline) {
      return Symbol{.kind = SymbolKind::powerline, .codepoint = codepoint};
    }

    return {};
  }

}
