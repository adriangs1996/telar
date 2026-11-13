export module telar.gui.terminal.glyphs;

import std;

import telar.gui.core.unicode_scalar;

// Interface: terminal/glyphs/box_edges.cppm
export {
  namespace telar::gui::glyphs {

    enum class BoxWeight : std::uint8_t {
      none,
      light,
      heavy,
      double_line,
    };

    struct BoxEdges {
      BoxWeight up = BoxWeight::none;
      BoxWeight right = BoxWeight::none;
      BoxWeight down = BoxWeight::none;
      BoxWeight left = BoxWeight::none;

      [[nodiscard]] inline bool empty() const noexcept {
        return up == BoxWeight::none && right == BoxWeight::none && down == BoxWeight::none && left == BoxWeight::none;
      }

      inline void simplifyDoubles() noexcept {
        for (auto* edge : {&up, &right, &down, &left}) {
          if (*edge == BoxWeight::double_line) {
            *edge = BoxWeight::light;
          }
        }
      }
    };

  }
}

// Interface: terminal/glyphs/box_stroke.cppm
export {
  namespace telar::gui::glyphs {

    struct BoxStroke {
      std::uint16_t units_per_em = 0;
      std::int16_t underline_thickness = 0;

      [[nodiscard]] inline float pixels(std::uint16_t pixel_height) const noexcept {
        constexpr float fallback_divisor = 16;
        const auto height = static_cast<float>(pixel_height);
        const auto thickness = units_per_em == 0 || underline_thickness <= 0 ? height / fallback_divisor : static_cast<float>(underline_thickness) * height / static_cast<float>(units_per_em);

        return std::max(1.0F, std::ceil(thickness));
      }
    };

  }
}

// Interface: terminal/glyphs/symbol.cppm
export {
  namespace telar::gui::glyphs {

    enum class SymbolKind : std::uint8_t {
      box,
      block,
      braille,
      powerline,
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
      static constexpr std::uint32_t first_powerline = 0xe0b0;
      static constexpr std::uint32_t last_powerline = 0xe0bf;

      SymbolKind kind = SymbolKind::box;
      std::uint32_t codepoint = 0;

      [[nodiscard]] inline static std::optional<Symbol> parse(std::string_view text) noexcept {
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
    };

  }
}
