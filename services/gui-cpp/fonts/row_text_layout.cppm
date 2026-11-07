module;
#include <cstdlib>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <exception>
#include <cstdio>
#include <variant>

#include <concepts>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <utility>
#include <array>
#include <bit>
#include <stdexcept>
#include <string_view>
#include <algorithm>
#include <ghostty/vt/unicode.h>

#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <chrono>
#include <cmath>
#include <limits>
#include <type_traits>

export module telar.gui.fonts.row_text_layout;

export import telar.gui.fonts.face;
export import telar.gui.text.bounded_editor;


export import telar.gui.fonts.font_requests;


export import telar.gui.terminal.font_grid;


export import telar.gui.core.metrics;


export import telar.gui.core.json_writer;
export import telar.gui.terminal.copy_mode;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: fonts/font_runs.cppm
export {
namespace telar::gui::fonts {

template <typename Fonts>
concept CascadingFontProvider = FontProvider<Fonts> && requires(Fonts &fonts, std::string_view text, FontRole role) {
  { fonts.source(text, role) } -> std::same_as<std::optional<FontRole>>;
};

struct FontSpan {
  std::string_view text;
  std::optional<FontRole> role = std::nullopt;
  std::uint32_t columns = 0;
};

template <CascadingFontProvider Fonts>
class FontRuns {
public:
  inline FontRuns(Fonts &fonts, std::string_view text, FontRole preferred) noexcept
      : fonts_(fonts),
        text_(text),
        cursor_(text),
        preferred_(preferred) {}

  [[nodiscard]] inline std::optional<FontSpan> next() {
    const auto start = cursor_.position();
    const auto cluster = cursor_.next();
    if (!cluster) {
      return std::nullopt;
    }

    auto role = fonts_.source(*cluster, preferred_);
    const auto resolved = role.value_or(FontRole::primary);
    std::uint32_t columns = cursor_.columns();
    if (resolved == preferred_) {
      while (cursor_.position() < text_.size()) {
        auto candidate = cursor_;
        const auto following = candidate.next();
        if (!following) {
          break;
        }

        const auto following_role = fonts_.source(*following, preferred_);
        if (following_role.value_or(FontRole::primary) != resolved) {
          break;
        }

        if (!following_role) {
          role.reset();
        }

        cursor_ = candidate;
        columns += cursor_.columns();
      }
    }

    return FontSpan{.text = text_.substr(start, cursor_.position() - start), .role = role, .columns = columns};
  }

private:
  Fonts &fonts_;
  std::string_view text_;
  GraphemeCursor cursor_;
  FontRole preferred_;
};

}
}

// Interface: fonts/text_layout.cppm
export {
namespace telar::gui::fonts {

struct TextSpan {
  std::size_t first = 0;
  std::size_t count = 0;
  FontRole role = FontRole::regular;
  std::int32_t offset = 0;
  std::uint32_t columns = 0;
};

struct TextRequest {
  std::uint16_t pixel_height = 0;
  FontRole preferred = FontRole::regular;
};

template <Allocator Memory>
class TextLayout {
public:
  inline explicit TextLayout(Memory &memory)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}) {}

  [[nodiscard]] inline std::span<const ShapedGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] inline std::span<const TextSpan> spans() const noexcept {
    return single_span_ ? std::span{&*single_span_, std::size_t{1}} : std::span<const TextSpan>{spans_};
  }

  [[nodiscard]] inline std::int32_t advance() const noexcept {
    return advance_;
  }

  template <CascadingFontProvider Fonts>
  inline void shape(Fonts &fonts, std::string_view text, TextRequest request) {
    clear();
    append(fonts, text, request);
  }

  template <CascadingFontProvider Fonts>
  inline void shapeCaption(Fonts &fonts, std::string_view text, TextRequest request) {
    clear();
    CaptionRuns runs{text};
    while (const auto run = runs.next()) {
      const auto before = advance_;
      append(fonts, *run, request);
      if (advance_ <= before) {
        break;
      }
    }
  }

  template <CascadingFontProvider Fonts>
  [[nodiscard]] inline static std::int32_t measure(Fonts &fonts, std::string_view text, TextRequest request) {
    std::int32_t advance = 0;
    visit(fonts, text, request, [&](FontSpan span) {
      const auto run = fonts.face(span.role.value_or(FontRole::primary)).shape(span.text, request.pixel_height);
      advance = addAdvance(advance, spanAdvance(fonts, span, request, run));
    });

    return advance;
  }

private:
  inline void clear() {
    glyphs_.clear();
    spans_.clear();
    single_span_.reset();
    advance_ = 0;
  }

  template <CascadingFontProvider Fonts>
  inline void append(Fonts &fonts, std::string_view text, TextRequest request) {
    visit(fonts, text, request, [&](FontSpan span) {
      const auto role = span.role.value_or(FontRole::primary);
      const auto run = fonts.face(role).shape(span.text, request.pixel_height);
      const auto start = glyphs_.size();
      appendSpan({.first = start, .count = run.size(), .role = role, .offset = advance_, .columns = span.columns});
      glyphs_.resize(start + run.size());
      for (std::size_t index = 0; index < run.size(); ++index) {
        glyphs_[start + index] = run.glyph(index);
      }

      advance_ = addAdvance(advance_, spanAdvance(fonts, span, request, run));
    });
  }

  inline void appendSpan(TextSpan span) {
    if (spans_.empty() && !single_span_) {
      single_span_ = span;
      return;
    }

    if (single_span_) {
      spans_.push_back(*single_span_);
      single_span_.reset();
    }

    spans_.push_back(span);
  }

  template <CascadingFontProvider Fonts, typename Visitor>
  inline static void visit(Fonts &fonts, std::string_view text, TextRequest request, Visitor visitor) {
    if (request.pixel_height == 0) {
      throw std::invalid_argument{"InvalidTextPixelHeight"};
    }

    if (text.empty()) {
      return;
    }

    if (!fittedFont(request.preferred) && FontCoverage::covers(fonts.face(request.preferred), text)) {
      visitor(FontSpan{.text = text, .role = request.preferred});
      return;
    }

    FontRuns runs{fonts, text, request.preferred};
    while (const auto span = runs.next()) {
      visitor(*span);
    }
  }

  template <CascadingFontProvider Fonts>
  inline static std::int32_t spanAdvance(Fonts &fonts, FontSpan span, TextRequest request, ShapedRunView run) {
    if (!span.role || !fittedFont(*span.role)) {
      return run.advance();
    }

    const auto width = static_cast<std::int64_t>(fonts.face(FontRole::primary).metrics(request.pixel_height).maximum_advance) * span.columns;

    return addAdvance(0, width);
  }

  inline static std::int32_t addAdvance(std::int32_t previous, std::int64_t next) {
    const auto total = previous + next;
    if (total < 0 || total > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"TextAdvanceOutOfRange"};
    }

    return static_cast<std::int32_t>(total);
  }

  Vector<ShapedGlyph, Memory> glyphs_;
  Vector<TextSpan, Memory> spans_;
  std::optional<TextSpan> single_span_;
  std::int32_t advance_ = 0;
};

}
}

// Interface: fonts/cell_text_layout.cppm
export {
namespace telar::gui::fonts {

template <Allocator Memory, std::size_t MaximumBytes>
class CellTextLayout {
public:
  static constexpr std::size_t maximum_text_bytes = MaximumBytes;
  static constexpr std::size_t glyphs_per_byte = 4;
  static constexpr std::size_t maximum_glyphs = maximum_text_bytes * glyphs_per_byte;

  inline explicit CellTextLayout(Memory &memory)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        clusters_(AllocatorRef<Cluster, Memory>{memory}) {}

  template <CascadingFontProvider Fonts>
  inline void shape(Fonts &fonts, std::string_view text, const FontGrid &grid) {
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

  [[nodiscard]] inline std::span<const ShapedGlyph> glyphs(std::uint32_t available_columns) const noexcept {
    std::size_t count = 0;
    for (const auto &cluster : clusters_) {
      if (cluster.columns > available_columns) {
        break;
      }

      count = cluster.glyph_end;
    }

    return std::span{glyphs_}.first(count);
  }

  [[nodiscard]] inline std::uint32_t columns() const noexcept {
    return columns_;
  }

  [[nodiscard]] inline std::span<const TextSpan> spans(std::uint32_t available_columns) const noexcept {
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
}

// Interface: fonts/glyph_transform.cppm
export {
namespace telar::gui::fonts {

struct GlyphTransform {
  float x = 0;
  float y = 0;
  float scale = 1;

  [[nodiscard]] inline static GlyphTransform fit(Rect ink, Rect cell) noexcept {
    if (!std::isfinite(ink.width) || ink.width <= 0 || ink.height <= 0) {
      return {};
    }

    const auto scale = std::min({1.0F, cell.width / ink.width, cell.height / ink.height});
    const auto top = ink.y * scale;
    const auto bottom = top + (ink.height * scale);

    float vertical_shift = 0;
    if (top < cell.y) {
      vertical_shift = cell.y - top;
    } else if (bottom > cell.bottom()) {
      vertical_shift = cell.bottom() - bottom;
    }

    return {
        .x = cell.x + ((cell.width - (ink.width * scale)) / 2) - (ink.x * scale),
        .y = vertical_shift,
        .scale = scale,
    };
  }

  [[nodiscard]] inline Rect map(Rect ink) const noexcept {
    return {.x = (ink.x * scale) + x, .y = (ink.y * scale) + y, .width = ink.width * scale, .height = ink.height * scale};
  }
};

}
}

// Interface: fonts/ink_bounds.cppm
export {
namespace telar::gui::fonts {

struct InkBounds {
  float left = std::numeric_limits<float>::infinity();
  float top = std::numeric_limits<float>::infinity();
  float right = -std::numeric_limits<float>::infinity();
  float bottom = -std::numeric_limits<float>::infinity();

  inline void include(Rect area) noexcept {
    left = std::min(left, area.x);
    top = std::min(top, area.y);
    right = std::max(right, area.right());
    bottom = std::max(bottom, area.bottom());
  }

  [[nodiscard]] inline Rect rect() const noexcept {
    return right > left && bottom > top ? Rect{.x = left, .y = top, .width = right - left, .height = bottom - top} : Rect{};
  }
};

}
}

// Interface: fonts/icon_layout.cppm
export {
namespace telar::gui::fonts {

struct IconGlyph {
  std::uint32_t index = 0;
  FontRole face = FontRole::regular;
  Rect ink;
};

struct IconRequest {
  std::uint16_t pixel_height = 0;
  FontRole preferred = FontRole::regular;
};

template <Allocator Memory>
class IconLayout {
public:
  static constexpr std::size_t maximum_text_bytes = 256;
  static constexpr std::size_t maximum_glyphs = 256;
  static constexpr float size_ratio = 0.85F;
  static constexpr std::uint16_t oversample = 2;
  static constexpr std::uint16_t maximum_pixel_height = 4096;

  inline explicit IconLayout(Memory &memory)
      : glyphs_(AllocatorRef<IconGlyph, Memory>{memory}) {}

  [[nodiscard]] inline std::span<const IconGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] inline Rect ink() const noexcept {
    InkBounds bounds;
    for (const auto &glyph : glyphs_) {
      bounds.include(glyph.ink);
    }

    return bounds.rect();
  }

  template <CascadingFontProvider Fonts>
  inline void shape(Fonts &fonts, std::string_view text, IconRequest request) {
    if (text.size() > maximum_text_bytes || request.pixel_height == 0 || request.pixel_height > maximum_pixel_height) {
      throw std::invalid_argument{"InvalidIconLayoutRequest"};
    }

    glyphs_.clear();
    FontRuns runs{fonts, text, request.preferred};
    float advance = 0;
    while (const auto span = runs.next()) {
      if (!span->role) {
        throw std::runtime_error{"IconFontUnavailable"};
      }

      advance += appendRun(fonts, span->text, {.role = *span->role, .request = request, .columns = span->columns, .advance = advance});
    }
  }

private:
  struct Run {
    FontRole role = FontRole::regular;
    IconRequest request;
    std::uint32_t columns = 0;
    float advance = 0;
  };

  template <CascadingFontProvider Fonts>
  inline float appendRun(Fonts &fonts, std::string_view text, Run run) {
    auto &face = fonts.face(run.role);
    const auto shaped = face.shape(text, run.request.pixel_height);
    const auto start = glyphs_.size();
    std::int64_t pen = 0;
    for (std::size_t index = 0; index < shaped.size(); ++index) {
      const auto glyph = shaped.glyph(index);
      const auto bitmap = face.rasterize({.index = glyph.index, .pixel_height = run.request.pixel_height, .style = {}});
      if (bitmap.width != 0 && bitmap.height != 0) {
        if (glyphs_.size() == maximum_glyphs) {
          throw std::length_error{"IconGlyphLimitExceeded"};
        }

        const auto x = FontMetrics::roundFixed(pen + glyph.x_offset) + bitmap.left;
        const auto y = -FontMetrics::roundFixed(glyph.y_offset) - bitmap.top;
        glyphs_.push_back({.index = glyph.index, .face = run.role, .ink = {.x = static_cast<float>(x), .y = static_cast<float>(y), .width = static_cast<float>(bitmap.width), .height = static_cast<float>(bitmap.height)}});
      }

      pen += glyph.x_advance;
    }

    auto appended = std::span{glyphs_}.subspan(start);
    if (fittedFont(run.role)) {
      const auto metrics = fonts.face(FontRole::primary).metrics(run.request.pixel_height);
      const Rect cell{.y = -static_cast<float>(metrics.ascender), .width = static_cast<float>(metrics.maximum_advance) * static_cast<float>(run.columns), .height = static_cast<float>(metrics.line_height)};
      fitFallback(appended, cell, run.advance);

      return cell.width;
    }

    for (auto &glyph : appended) {
      glyph.ink.x += run.advance;
    }

    return static_cast<float>(FontMetrics::roundFixed(pen));
  }

  inline static void fitFallback(std::span<IconGlyph> glyphs, Rect cell, float advance) {
    InkBounds bounds;
    for (const auto &glyph : glyphs) {
      bounds.include(glyph.ink);
    }

    const auto ink = bounds.rect();
    if (ink.empty()) {
      return;
    }

    const auto transform = GlyphTransform::fit(ink, cell);
    for (auto &glyph : glyphs) {
      glyph.ink = {.x = advance + (glyph.ink.x * transform.scale) + transform.x, .y = (glyph.ink.y * transform.scale) + transform.y, .width = glyph.ink.width * transform.scale, .height = glyph.ink.height * transform.scale};
    }
  }

  Vector<IconGlyph, Memory> glyphs_;
};

}
}

// Interface: fonts/icon_placement.cppm
export {
namespace telar::gui::fonts {

struct IconPlacement {
  Point origin;
  Point ink_origin;
  float scale = 0;

  [[nodiscard]] inline static IconPlacement resolve(Rect ink, Rect bounds, float requested_side) {
    if (!std::isfinite(requested_side) || !std::isfinite(bounds.x) || !std::isfinite(bounds.y) || !std::isfinite(bounds.width) || !std::isfinite(bounds.height)) {
      throw std::invalid_argument{"InvalidIconBounds"};
    }

    const auto side = std::min({requested_side, bounds.width, bounds.height});
    if (ink.empty() || side <= 0) {
      return {};
    }

    const auto left = bounds.x + ((bounds.width - side) / 2);
    const auto top = bounds.y + ((bounds.height - side) / 2);
    const auto scale = std::min(side / ink.width, side / ink.height);

    return {.origin = {.x = left + ((side - (ink.width * scale)) / 2), .y = top + ((side - (ink.height * scale)) / 2)}, .ink_origin = {.x = ink.x, .y = ink.y}, .scale = scale};
  }

  [[nodiscard]] inline Rect map(Rect glyph) const noexcept {
    return {.x = origin.x + ((glyph.x - ink_origin.x) * scale), .y = origin.y + ((glyph.y - ink_origin.y) * scale), .width = glyph.width * scale, .height = glyph.height * scale};
  }
};

}
}

// Interface: fonts/row_text_layout.cppm
export {
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
  inline explicit RowTextLayout(Memory &memory)
      : runs_(memory),
        cell_(memory),
        glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        cells_(AllocatorRef<CellTextRange, Memory>{memory}) {}

  inline void resetFont() noexcept {
    ascii_ = {};
    cached_face_ = nullptr;
  }

  [[nodiscard]] inline std::span<const ShapedGlyph> glyphs() const noexcept {
    return glyphs_;
  }

  [[nodiscard]] inline std::span<const TextSpan> spans() const noexcept {
    return spans_;
  }

  [[nodiscard]] inline CellTextRange cell(std::size_t column) const noexcept {
    return cells_[column];
  }

  template <CascadingFontProvider Fonts>
  inline void shape(Fonts &fonts, std::span<const CellValue> cells, RowTextRequest request) {
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
  [[nodiscard]] inline static std::int32_t cellOffset(std::size_t column, RowTextRequest request) {
    const auto offset = static_cast<std::uint64_t>(column) * request.cell_width;
    if (offset > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"CellTextOffsetOutOfRange"};
    }

    return static_cast<std::int32_t>(offset);
  }

  inline void appendPrimary(std::span<const ShapedGlyph> glyphs, std::size_t column, RowTextRequest request) {
    const auto first = glyphs_.size();
    glyphs_.insert(glyphs_.end(), glyphs.begin(), glyphs.end());
    cells_[column] = {.first_span = spans_.size(), .span_count = 1};
    spans_.push_back({.first = first, .count = glyphs.size(), .role = FontRole::primary, .offset = cellOffset(column, request), .columns = 1});
  }

  inline bool appendTogether(Face &face, std::span<const CellValue> cells, std::size_t column, RowTextRequest request) {
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
  inline void appendAlone(Fonts &fonts, const CellValue &cell, std::size_t column, RowTextRequest request) {
    if (cell.width == CellWidth::continuation || hasAttribute(cell.style, CellAttribute::invisible) || glyphs::Symbol::parse(cell.utf8()) || cell.utf8().starts_with(placeholder_prefix)) {
      return;
    }

    const auto text = cell.utf8();
    auto &face = fonts.face(FontRole::primary);
    if (text.size() == 1 && static_cast<unsigned char>(text.front()) < ascii_.size()) {
      auto &cached = ascii_[static_cast<unsigned char>(text.front())];
      if (cached) {
        appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
        return;
      }

      if (FontCoverage::covers(face, text)) {
        const auto shaped = face.shape(text, request.pixel_height);
        if (shaped.size() == 1) {
          cached = shaped.glyph(0);
          appendPrimary(std::span{&*cached, std::size_t{1}}, column, request);
          return;
        }
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
}
