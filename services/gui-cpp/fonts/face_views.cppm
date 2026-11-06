module;

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <hb.h>
#include <span>

export module telar.gui.fonts.face:views;

export import telar.gui.terminal.font_grid;

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
concept FontProvider = requires(Fonts &fonts, FontRole role) {
  { fonts.face(role) } -> std::same_as<Face &>;
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

  bool operator==(const ShapedGlyph &) const = default;
};

class ShapedRunView {
public:
  [[nodiscard]] inline std::size_t size() const noexcept {
    return glyphs_.size();
  }

  [[nodiscard]] inline bool rightToLeft() const noexcept {
    return right_to_left_;
  }

  [[nodiscard]] inline ShapedGlyph glyph(std::size_t index) const noexcept {
    const auto &info = glyphs_[index];
    const auto &position = positions_[index];

    return {.index = info.codepoint, .cluster = info.cluster, .x_advance = position.x_advance, .y_advance = position.y_advance, .x_offset = position.x_offset, .y_offset = position.y_offset};
  }

  [[nodiscard]] inline std::int32_t advance() const {
    std::int64_t advance = 0;
    for (const auto &position : positions_) {
      advance += position.x_advance;
    }

    return FontMetrics::roundFixed(advance);
  }

private:
  friend class Face;

  inline ShapedRunView(std::span<const hb_glyph_info_t> glyphs, std::span<const hb_glyph_position_t> positions, bool right_to_left) noexcept
      : glyphs_(glyphs),
        positions_(positions),
        right_to_left_(right_to_left) {}

  std::span<const hb_glyph_info_t> glyphs_;
  std::span<const hb_glyph_position_t> positions_;
  bool right_to_left_;
};

}
}
