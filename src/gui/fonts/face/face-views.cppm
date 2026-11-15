module;
#include <hb.h>

export module telar.gui.fonts.face:views;

import std;

// Interface: fonts/font_role.cppm
export {
  namespace telar::gui::fonts {

    class Face;

    enum class FontRole : std::uint8_t {
      regular,
      emphasized,
      primary,
      text,
      symbols,
      fallback_0,
      fallback_1,
      fallback_2,
      fallback_3,
      fallback_4,
      fallback_5,
      fallback_6,
      fallback_7,
    };

    inline constexpr std::size_t maximum_fallback_faces = 8;

    [[nodiscard]] constexpr FontRole fallbackRole(std::size_t index) noexcept {
      return static_cast<FontRole>(std::to_underlying(FontRole::fallback_0) + index);
    }

    [[nodiscard]] constexpr std::optional<std::size_t> fallbackIndex(FontRole role) noexcept {
      if (role < FontRole::fallback_0 || role > FontRole::fallback_7) {
        return std::nullopt;
      }

      return std::to_underlying(role) - std::to_underlying(FontRole::fallback_0);
    }

    template <typename Fonts>
    concept FontProvider = requires(Fonts& fonts, FontRole role) {
      { fonts.face(role) } -> std::same_as<Face&>;
    };

    [[nodiscard]] constexpr bool fittedFont(FontRole role) noexcept {
      return role == FontRole::text || role == FontRole::symbols || fallbackIndex(role).has_value();
    }

  }
}

// Interface: fonts/shaped_run_view.cppm
export {
  namespace telar::gui::fonts {

    struct ShapedGlyph {
      std::uint32_t index = 0;
      std::uint32_t cluster = 0;
      std::int32_t x_advance = 0;
      std::int32_t y_advance = 0;
      std::int32_t x_offset = 0;
      std::int32_t y_offset = 0;

      bool operator==(const ShapedGlyph&) const = default;
    };

    class ShapedRunView {
    public:
      [[nodiscard]] std::size_t size() const noexcept;
      [[nodiscard]] bool rightToLeft() const noexcept;
      [[nodiscard]] ShapedGlyph glyph(std::size_t index) const noexcept;
      [[nodiscard]] std::int32_t advance() const;

    private:
      friend class Face;

      ShapedRunView(std::span<const hb_glyph_info_t> glyphs, std::span<const hb_glyph_position_t> positions, bool right_to_left) noexcept;

      std::span<const hb_glyph_info_t> glyphs_;
      std::span<const hb_glyph_position_t> positions_;
      bool right_to_left_;
    };

  }
}
