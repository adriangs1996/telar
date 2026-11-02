#pragma once

#include "core/memory.hpp"
#include "face.hpp"
#include "font_role.hpp"
#include "font_runs.hpp"
#include "shaped_run_view.hpp"
#include "terminal/font_grid.hpp"
#include "text/grapheme_cursor.hpp"
#include "text_layout.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

template <Allocator Memory, std::size_t MaximumBytes>
class CellTextLayout {
public:
  static constexpr std::size_t maximum_text_bytes = MaximumBytes;
  static constexpr std::size_t glyphs_per_byte = 4;
  static constexpr std::size_t maximum_glyphs = maximum_text_bytes * glyphs_per_byte;

  explicit CellTextLayout(Memory &memory)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        clusters_(AllocatorRef<Cluster, Memory>{memory}) {}

  template <CascadingFontProvider Fonts>
  void shape(Fonts &fonts, std::string_view text, const FontGrid &grid) {
    if (text.size() > maximum_text_bytes || grid.width == 0 || grid.height == 0 || grid.pixel_height == 0) {
      throw std::invalid_argument{"InvalidCellTextRequest"};
    }

    glyphs_.clear();
    spans_.clear();
    clusters_.clear();
    columns_ = 0;
    GraphemeCursor cursor{text};
    while (const auto cluster_text = cursor.next()) {
      const auto role = fonts.source(*cluster_text, FontRole::primary).value_or(FontRole::primary);
      const auto shaped = fonts.face(role).shape(*cluster_text, grid.pixel_height);
      if (shaped.size() > maximum_glyphs - glyphs_.size()) {
        throw std::length_error{"CellTextGlyphLimitExceeded"};
      }

      for (std::size_t index = 0; index < shaped.size(); ++index) {
        glyphs_.push_back(shaped.glyph(index));
      }

      spans_.push_back({.first = glyphs_.size() - shaped.size(), .count = shaped.size(), .role = role, .offset = static_cast<std::int32_t>(columns_ * grid.width), .columns = cursor.columns()});
      columns_ += cursor.columns();
      clusters_.push_back({.columns = columns_, .glyph_end = glyphs_.size(), .span_end = spans_.size()});
    }
  }

  [[nodiscard]] std::span<const ShapedGlyph> glyphs(std::uint32_t available_columns) const noexcept {
    std::size_t count = 0;
    for (const auto &cluster : clusters_) {
      if (cluster.columns > available_columns) {
        break;
      }

      count = cluster.glyph_end;
    }

    return std::span{glyphs_}.first(count);
  }

  [[nodiscard]] std::uint32_t columns() const noexcept {
    return columns_;
  }

  [[nodiscard]] std::span<const TextSpan> spans(std::uint32_t available_columns) const noexcept {
    std::size_t count = 0;
    for (const auto &cluster : clusters_) {
      if (cluster.columns > available_columns) {
        break;
      }

      count = cluster.span_end;
    }

    return std::span{spans_}.first(count);
  }

private:
  struct Cluster {
    std::uint32_t columns = 0;
    std::size_t glyph_end = 0;
    std::size_t span_end = 0;
  };

  Vector<ShapedGlyph, Memory> glyphs_;
  Vector<TextSpan, Memory> spans_;
  Vector<Cluster, Memory> clusters_;
  std::uint32_t columns_ = 0;
};

}
