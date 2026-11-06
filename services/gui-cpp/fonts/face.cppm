module;

#include <cstddef>
#include <cstdint>
#include <span>


#include <array>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <string_view>


#include "../platform/font.h"
#include <algorithm>
#include <cstring>


#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>

export module telar.gui.fonts.face;

export import telar.gui.terminal.font_grid;
export import :views;

// Interface: fonts/glyph_bitmap_view.cppm
export {
namespace telar::gui::fonts {

struct GlyphStyle {
  bool bold = false;
  bool italic = false;

  bool operator==(const GlyphStyle &) const = default;
};

struct GlyphRasterRequest {
  std::uint32_t index = 0;
  std::uint16_t pixel_height = 0;
  GlyphStyle style;
  std::uint8_t thicken_strength = 0;
};

struct GlyphBitmapView {
  std::span<const std::uint8_t> coverage;
  std::size_t stride = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::int32_t left = 0;
  std::int32_t top = 0;

  [[nodiscard]] inline std::span<const std::uint8_t> row(std::size_t index) const noexcept {
    return coverage.subspan(index * stride, width);
  }
};

}
}

// Interface: fonts/ligature_role.cppm
export {
namespace telar::gui::fonts {

enum class LigatureRole : std::uint8_t {
  none,
  context,
  input,
};

}
}

// Interface: fonts/ligature_coverage.cppm
export {
namespace telar::gui::fonts {

class LigatureCoverage {
public:
  static constexpr std::size_t ascii_count = 128;

  explicit LigatureCoverage(FT_Face face, hb_font_t *font);
  [[nodiscard]] LigatureRole role(std::string_view text) const noexcept;
  [[nodiscard]] bool joins() const noexcept;
  [[nodiscard]] std::uint16_t reach() const noexcept;

private:
  struct SetDeleter {
    void operator()(hb_set_t *set) const noexcept;
  };

  using OwnedSet = std::unique_ptr<hb_set_t, SetDeleter>;

  [[nodiscard]] static OwnedSet createSet();
  [[nodiscard]] static std::uint16_t maximumContext(FT_Face face);

  std::array<LigatureRole, ascii_count> ascii_{};
  OwnedSet input_;
  OwnedSet context_;
  std::uint16_t reach_ = 0;
};

}
}

// Interface: fonts/native_match.cppm
export {
extern "C" {
}

namespace telar::gui::fonts {

using FontMatch = telar_font_match;
using FontVariation = telar_font_variation;

[[nodiscard]] inline bool sameFontMatch(const FontMatch &left, const FontMatch &right) noexcept {
  return left.face_index == right.face_index && std::strncmp(std::span{left.path}.data(), std::span{right.path}.data(), sizeof(left.path)) == 0 && std::strncmp(std::span{left.postscript}.data(), std::span{right.postscript}.data(), sizeof(left.postscript)) == 0 && left.variation.count == right.variation.count && std::ranges::equal(left.variation.tags, right.variation.tags) && std::ranges::equal(left.variation.values, right.variation.values);
}

}
}

// Interface: fonts/face.cppm
export {
namespace telar::gui::fonts {

class Face {
public:
  static constexpr std::size_t maximum_sizes = 8;

  explicit Face(std::span<const std::uint8_t> bytes, const FontMatch &match = {});
  ~Face();
  Face(const Face &) = delete;
  Face &operator=(const Face &) = delete;
  Face(Face &&) = delete;
  Face &operator=(Face &&) = delete;

  [[nodiscard]] FontMetrics metrics(std::uint16_t pixel_height);
  [[nodiscard]] ShapedRunView shape(std::string_view text, std::uint16_t pixel_height);
  [[nodiscard]] GlyphBitmapView rasterize(GlyphRasterRequest request);
  [[nodiscard]] bool covers(char32_t scalar) const noexcept;
  [[nodiscard]] FontVariation variation() const;
  [[nodiscard]] std::string_view family() const noexcept;
  [[nodiscard]] std::string_view style() const noexcept;
  [[nodiscard]] bool fixedPitch() const noexcept;
  [[nodiscard]] bool monochrome() const noexcept;
  [[nodiscard]] const LigatureCoverage &ligatures();

private:
  struct LibraryDeleter {
    void operator()(FT_Library library) const noexcept;
  };

  struct FaceDeleter {
    void operator()(FT_Face face) const noexcept;
  };

  struct ShapingFontDeleter {
    void operator()(hb_font_t *font) const noexcept;
  };

  struct ShapingBufferDeleter {
    void operator()(hb_buffer_t *buffer) const noexcept;
  };

  struct SizeDeleter {
    void operator()(FT_Size size) const noexcept;
  };

  using OwnedSize = std::unique_ptr<std::remove_pointer_t<FT_Size>, SizeDeleter>;

  struct SizeEntry {
    std::uint16_t height = 0;
    OwnedSize handle;
  };

  void selectFace(std::span<const std::uint8_t> bytes, const FontMatch &match);
  void applyVariation(const FontVariation &variation);
  void initializeShaping();
  [[nodiscard]] OwnedSize createSize(std::uint16_t pixel_height);
  void selectSize(std::uint16_t pixel_height);

  std::unique_ptr<std::remove_pointer_t<FT_Library>, LibraryDeleter> library_;
  std::unique_ptr<std::remove_pointer_t<FT_Face>, FaceDeleter> face_;
  std::unique_ptr<hb_font_t, ShapingFontDeleter> shaping_font_;
  std::unique_ptr<hb_buffer_t, ShapingBufferDeleter> shaping_buffer_;
  std::optional<LigatureCoverage> ligatures_;
  std::array<SizeEntry, maximum_sizes> sizes_{};
  std::size_t next_size_slot_ = 0;
  std::uint16_t active_height_ = 0;
};

}
}
