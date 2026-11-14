export module telar.gui.terminal.glyphs;

import std;

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

      [[nodiscard]] bool empty() const noexcept;
      void simplifyDoubles() noexcept;
    };

  }
}

// Interface: terminal/glyphs/box_stroke.cppm
export {
  namespace telar::gui::glyphs {

    struct BoxStroke {
      std::uint16_t units_per_em = 0;
      std::int16_t underline_thickness = 0;

      [[nodiscard]] float pixels(std::uint16_t pixel_height) const noexcept;
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

      [[nodiscard]] static std::optional<Symbol> parse(std::string_view text) noexcept;
    };

  }
}
