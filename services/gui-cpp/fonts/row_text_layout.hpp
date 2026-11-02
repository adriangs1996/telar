#pragma once

#include "core/color.hpp"
#include "core/memory.hpp"
#include "core/placeholder_prefix.hpp"
#include "face.hpp"
#include "font_coverage.hpp"
#include "font_role.hpp"
#include "shaped_run_view.hpp"
#include "terminal/glyphs/symbol.hpp"
#include "terminal/screen.hpp"
#include "terminal/selection.hpp"
#include "terminal/text_runs.hpp"
#include "text_layout.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::fonts {

struct RowTextRequest {
  std::uint16_t pixel_height = 1;
  std::uint16_t cell_width = 1;
  std::optional<std::size_t> cursor = std::nullopt;
  CellSelection selection{};
  std::size_t first_cell = 0;
};

struct CellTextRange {
  std::size_t first_span = 0;
  std::size_t span_count = 0;
};

template <Allocator Memory>
class RowTextLayout {
public:
  explicit RowTextLayout(Memory &memory)
      : runs_(memory),
        cell_(memory),
        glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        cells_(AllocatorRef<CellTextRange, Memory>{memory}) {}

  void resetFont() noexcept {
    ascii_ = {};
    cached_face_ = nullptr;
  }

  [[nodiscard]] std::span<const ShapedGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] std::span<const TextSpan> spans() const noexcept {
    return spans_;
  }

  [[nodiscard]] CellTextRange cell(std::size_t column) const noexcept {
    return cells_[column];
  }

  template <CascadingFontProvider Fonts>
  void shape(Fonts &fonts, std::span<const CellValue> cells, RowTextRequest request) {
    if (request.pixel_height == 0 || request.cell_width == 0 || cells.size() > std::numeric_limits<std::uint16_t>::max()) {
      throw std::invalid_argument{"InvalidRowTextRequest"};
    }

    glyphs_.clear();
    spans_.clear();
    cells_.assign(cells.size(), {});
    runs_.reserve(cells.size());
    runs_.clear();
    auto &primary = fonts.face(FontRole::primary);
    if (cached_face_ != &primary || cached_height_ != request.pixel_height) {
      ascii_ = {};
      cached_face_ = &primary;
      cached_height_ = request.pixel_height;
    }
    const auto &coverage = primary.ligatures();
    for (std::size_t column = 0; column < cells.size(); ++column) {
      auto projected = cells[column];
      if (request.selection.contains(request.first_cell + column)) {
        projected.style.flags ^= static_cast<std::uint16_t>(CellAttribute::inverse);
      }

      runs_.append(coverage, projected, request.cursor == column);
    }

    runs_.close(coverage.reach());
    for (std::size_t column = 0; column < cells.size();) {
      const auto run = runs_.at(column);
      const auto source = cells.subspan(column, run.count);
      if (!run.together || !appendTogether(primary, source, column, request)) {
        for (std::size_t offset = 0; offset < run.count; ++offset) {
          appendAlone(fonts, source[offset], column + offset, request);
        }
      }

      column += run.count;
    }
  }

private:
  [[nodiscard]] static std::int32_t cellOffset(std::size_t column, RowTextRequest request) {
    const auto offset = static_cast<std::uint64_t>(column) * request.cell_width;
    if (offset > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"CellTextOffsetOutOfRange"};
    }

    return static_cast<std::int32_t>(offset);
  }

  void appendPrimary(std::span<const ShapedGlyph> glyphs, std::size_t column, RowTextRequest request) {
    const auto first = glyphs_.size();
    glyphs_.insert(glyphs_.end(), glyphs.begin(), glyphs.end());
    cells_[column] = {.first_span = spans_.size(), .span_count = 1};
    spans_.push_back({.first = first, .count = glyphs.size(), .role = FontRole::primary, .offset = cellOffset(column, request), .columns = 1});
  }

  bool appendTogether(Face &face, std::span<const CellValue> cells, std::size_t column, RowTextRequest request) {
    std::array<char, TextRuns<Memory>::maximum_bytes> bytes{};
    std::array<std::uint32_t, TextRuns<Memory>::maximum_cells> ends{};
    std::size_t length = 0;
    for (std::size_t index = 0; index < cells.size(); ++index) {
      const auto text = cells[index].utf8();
      std::ranges::copy(text, bytes.begin() + static_cast<std::ptrdiff_t>(length));
      length += text.size();
      ends[index] = static_cast<std::uint32_t>(length);
    }

    const auto run = face.shape({bytes.data(), length}, request.pixel_height);
    if (run.size() == 0 || run.size() > TextRuns<Memory>::maximum_glyphs || run.rightToLeft()) {
      return false;
    }

    std::array<ShapedGlyph, TextRuns<Memory>::maximum_glyphs> saved{};
    for (std::size_t index = 0; index < run.size(); ++index) {
      saved[index] = run.glyph(index);
      if (index != 0 && saved[index].cluster < saved[index - 1].cluster) {
        return false;
      }
    }

    std::size_t first = 0;
    for (std::size_t index = 0; index < cells.size(); ++index) {
      auto end = first;
      while (end < run.size() && saved[end].cluster < ends[index]) {
        ++end;
      }

      const auto share = std::span{saved}.subspan(first, end - first);
      appendPrimary(share, column + index, request);

      first = end;
    }

    return true;
  }

  template <CascadingFontProvider Fonts>
  void appendAlone(Fonts &fonts, const CellValue &cell, std::size_t column, RowTextRequest request) {
    if (cell.width == CellWidth::continuation || hasAttribute(cell.style, CellAttribute::invisible) || glyphs::Symbol::parse(cell.utf8()) || cell.utf8().starts_with(placeholder_prefix)) {
      return;
    }

    const auto text = cell.utf8();
    auto &face = fonts.face(FontRole::primary);
    if (text.size() == 1 && static_cast<unsigned char>(text.front()) < ascii_.size() && FontCoverage::covers(face, text)) {
      auto &cached = ascii_[static_cast<unsigned char>(text.front())];
      if (cached) {
        appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
        return;
      }

      const auto shaped = face.shape(text, request.pixel_height);
      if (shaped.size() == 1) {
        cached = shaped.glyph(0);
        appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
        return;
      }
    }

    cell_.shape(fonts, text, {.pixel_height = request.pixel_height, .preferred = FontRole::primary});
    const auto first_glyph = glyphs_.size();
    glyphs_.insert(glyphs_.end(), cell_.glyphs().begin(), cell_.glyphs().end());
    cells_[column] = {.first_span = spans_.size(), .span_count = cell_.spans().size()};
    for (auto span : cell_.spans()) {
      span.first += first_glyph;
      const auto offset = static_cast<std::int64_t>(span.offset) + cellOffset(column, request);
      if (offset > std::numeric_limits<std::int32_t>::max()) {
        throw std::length_error{"CellTextOffsetOutOfRange"};
      }

      span.offset = static_cast<std::int32_t>(offset);
      spans_.push_back(span);
    }
  }

  TextRuns<Memory> runs_;
  TextLayout<Memory> cell_;
  Vector<ShapedGlyph, Memory> glyphs_;
  Vector<TextSpan, Memory> spans_;
  Vector<CellTextRange, Memory> cells_;
  std::array<std::optional<ShapedGlyph>, LigatureCoverage::ascii_count> ascii_{};
  const Face *cached_face_ = nullptr;
  std::uint16_t cached_height_ = 0;
};

}
