#pragma once

#include "glyph_bitmap_view.hpp"
#include "ligature_coverage.hpp"
#include "native_match.hpp"
#include "shaped_run_view.hpp"
#include "terminal/font_grid.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include <optional>
#include <span>
#include <string_view>
#include <type_traits>

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
