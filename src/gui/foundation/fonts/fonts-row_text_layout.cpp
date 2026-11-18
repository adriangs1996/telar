module telar.gui.foundation.fonts;

import std;

import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.base.ds;

namespace telar::gui::inline foundation::inline fonts {

  template <Allocator Memory>
  TextLayout<Memory>::TextLayout(Memory& memory)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}) {}

  template <Allocator Memory>
  std::span<const ShapedGlyph> TextLayout<Memory>::glyphs() const noexcept {
    return glyphs_;
  }

  template <Allocator Memory>
  std::span<const TextSpan> TextLayout<Memory>::spans() const noexcept {
    return single_span_ ? std::span{&*single_span_, std::size_t{1}} : std::span<const TextSpan>{spans_};
  }

  template <Allocator Memory>
  std::int32_t TextLayout<Memory>::advance() const noexcept {
    return advance_;
  }

  template <Allocator Memory>
  void TextLayout<Memory>::clear() {
    glyphs_.clear();
    spans_.clear();
    single_span_.reset();
    advance_ = 0;
  }

  template <Allocator Memory>
  void TextLayout<Memory>::appendSpan(TextSpan span) {
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

  template <Allocator Memory>
  std::int32_t TextLayout<Memory>::addAdvance(std::int32_t previous, std::int64_t next) {
    const auto total = previous + next;
    if (total < 0 || total > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"TextAdvanceOutOfRange"};
    }

    return static_cast<std::int32_t>(total);
  }

  GlyphTransform GlyphTransform::fit(Rect ink, Rect cell) noexcept {
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

  Rect GlyphTransform::map(Rect ink) const noexcept {
    return {.x = (ink.x * scale) + x, .y = (ink.y * scale) + y, .width = ink.width * scale, .height = ink.height * scale};
  }

  void InkBounds::include(Rect area) noexcept {
    left = std::min(left, area.x);
    top = std::min(top, area.y);
    right = std::max(right, area.right());
    bottom = std::max(bottom, area.bottom());
  }

  Rect InkBounds::rect() const noexcept {
    return right > left && bottom > top ? Rect{.x = left, .y = top, .width = right - left, .height = bottom - top} : Rect{};
  }

  template <Allocator Memory>
  IconLayout<Memory>::IconLayout(Memory& memory)
      : glyphs_(AllocatorRef<IconGlyph, Memory>{memory}) {}

  template <Allocator Memory>
  std::span<const IconGlyph> IconLayout<Memory>::glyphs() const noexcept {
    return glyphs_;
  }

  template <Allocator Memory>
  Rect IconLayout<Memory>::ink() const noexcept {
    InkBounds bounds;

    for (const auto& glyph : glyphs_) {
      bounds.include(glyph.ink);
    }

    return bounds.rect();
  }

  template <Allocator Memory>
  void IconLayout<Memory>::fitFallback(std::span<IconGlyph> glyphs, Rect cell, float advance) {
    InkBounds bounds;

    for (const auto& glyph : glyphs) {
      bounds.include(glyph.ink);
    }

    const auto ink = bounds.rect();
    if (ink.empty()) {
      return;
    }

    const auto transform = GlyphTransform::fit(ink, cell);

    for (auto& glyph : glyphs) {
      glyph.ink = {.x = advance + (glyph.ink.x * transform.scale) + transform.x, .y = (glyph.ink.y * transform.scale) + transform.y, .width = glyph.ink.width * transform.scale, .height = glyph.ink.height * transform.scale};
    }
  }

  IconPlacement IconPlacement::resolve(Rect ink, Rect bounds, float requested_side) {
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

  Rect IconPlacement::map(Rect glyph) const noexcept {
    return {.x = origin.x + ((glyph.x - ink_origin.x) * scale), .y = origin.y + ((glyph.y - ink_origin.y) * scale), .width = glyph.width * scale, .height = glyph.height * scale};
  }

  template <Allocator Memory>
  RowTextLayout<Memory>::RowTextLayout(Memory& memory)
      : runs_(memory),
        cell_(memory),
        glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        cells_(AllocatorRef<CellTextRange, Memory>{memory}) {}

  template <Allocator Memory>
  void RowTextLayout<Memory>::resetFont() noexcept {
    ascii_ = {};
    clusters_ = {};
    cached_face_ = nullptr;
  }

  template <Allocator Memory>
  std::span<const ShapedGlyph> RowTextLayout<Memory>::glyphs() const noexcept {
    return glyphs_;
  }

  template <Allocator Memory>
  std::span<const TextSpan> RowTextLayout<Memory>::spans() const noexcept {
    return spans_;
  }

  template <Allocator Memory>
  CellTextRange RowTextLayout<Memory>::cell(std::size_t column) const noexcept {
    return cells_[column];
  }

  template <Allocator Memory>
  std::int32_t RowTextLayout<Memory>::cellOffset(std::size_t column, RowTextRequest request) {
    const auto offset = static_cast<std::uint64_t>(column) * request.cell_width;
    if (offset > std::numeric_limits<std::int32_t>::max()) {
      throw std::length_error{"CellTextOffsetOutOfRange"};
    }

    return static_cast<std::int32_t>(offset);
  }

  template <Allocator Memory>
  void RowTextLayout<Memory>::appendPrimary(std::span<const ShapedGlyph> glyphs, std::size_t column, RowTextRequest request) {
    const auto first = glyphs_.size();

    glyphs_.insert(glyphs_.end(), glyphs.begin(), glyphs.end());
    cells_[column] = {.first_span = spans_.size(), .span_count = 1};
    spans_.push_back({.first = first, .count = glyphs.size(), .role = FontRole::primary, .offset = cellOffset(column, request), .columns = 1});
  }

  template <Allocator Memory>
  bool RowTextLayout<Memory>::appendTogether(Face& face, std::span<const CellValue> cells, std::size_t column, RowTextRequest request) {
    ds::Array<char, TextRuns<Memory>::maximum_bytes> bytes{};
    ds::Array<std::uint32_t, TextRuns<Memory>::maximum_cells> ends{};
    std::size_t length = 0;

    for (std::size_t index = 0; index < cells.size(); ++index) {
      const auto text = cells[index].utf8();

      std::ranges::copy(text, bytes.viewMut().begin() + static_cast<std::ptrdiff_t>(length));
      length += text.size();
      ends.atMut(index) = static_cast<std::uint32_t>(length);
    }

    const auto run = face.shape({bytes.data(), length}, request.pixel_height);
    if (run.size() == 0 || run.size() > TextRuns<Memory>::maximum_glyphs || run.rightToLeft()) {
      return false;
    }

    ds::Array<ShapedGlyph, TextRuns<Memory>::maximum_glyphs> saved{};

    for (std::size_t index = 0; index < run.size(); ++index) {
      saved.atMut(index) = run.glyph(index);
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

  template <Allocator Memory>
  std::uint64_t RowTextLayout<Memory>::clusterKey(std::string_view text) noexcept {
    if (text.size() < 2 || text.size() > 4) {
      return 0;
    }

    std::uint64_t key = static_cast<std::uint64_t>(text.size()) << cluster_length_shift;

    for (std::size_t index = 0; index < text.size(); ++index) {
      key |= static_cast<std::uint64_t>(static_cast<unsigned char>(text[index])) << (std::size_t{std::numeric_limits<unsigned char>::digits} * index);
    }

    return key;
  }

  template <Allocator Memory>
  std::size_t RowTextLayout<Memory>::clusterSlot(std::uint64_t key) noexcept {
    return static_cast<std::size_t>((key * golden_ratio_multiplier) >> (std::numeric_limits<std::uint64_t>::digits - cluster_bits));
  }

  template <Allocator Memory>
  void RowTextLayout<Memory>::appendCluster(ShapedGlyph glyph, std::size_t column, RowTextRequest request) {
    cells_[column] = {.first_span = spans_.size(), .span_count = 1};
    spans_.push_back({.first = glyphs_.size(), .count = 1, .role = FontRole::primary, .offset = cellOffset(column, request), .columns = 0});
    glyphs_.push_back(glyph);
  }

  template <Allocator Memory>
  CellTextLayout<Memory>::CellTextLayout(Memory& memory, std::size_t maximum_text_bytes)
      : glyphs_(AllocatorRef<ShapedGlyph, Memory>{memory}),
        spans_(AllocatorRef<TextSpan, Memory>{memory}),
        clusters_(AllocatorRef<Cluster, Memory>{memory}),
        maximum_text_bytes_(maximum_text_bytes) {}

  template <Allocator Memory>
  void CellTextLayout<Memory>::begin(std::string_view text, const FontGrid& grid) {
    if (text.size() > maximum_text_bytes_ || grid.width == 0 || grid.height == 0 || grid.pixel_height == 0) {
      throw std::invalid_argument{"InvalidCellTextRequest"};
    }

    glyphs_.clear();
    spans_.clear();
    clusters_.clear();
    columns_ = 0;
  }

  template <Allocator Memory>
  void CellTextLayout<Memory>::append(const ShapedRunView& shaped, FontRole role, const FontGrid& grid, std::uint32_t columns) {
    if (shaped.size() > (maximum_text_bytes_ * glyphs_per_byte) - glyphs_.size()) {
      throw std::length_error{"CellTextGlyphLimitExceeded"};
    }

    for (std::size_t index = 0; index < shaped.size(); ++index) {
      glyphs_.push_back(shaped.glyph(index));
    }

    spans_.push_back({.first = glyphs_.size() - shaped.size(), .count = shaped.size(), .role = role, .offset = static_cast<std::int32_t>(columns_ * grid.width), .columns = columns});
    columns_ += columns;
    clusters_.push_back({.columns = columns_, .glyph_end = glyphs_.size(), .span_end = spans_.size()});
  }

  template <Allocator Memory>
  std::span<const ShapedGlyph> CellTextLayout<Memory>::glyphs(std::uint32_t available_columns) const noexcept {
    std::size_t count = 0;

    for (const auto& cluster : clusters_) {
      if (cluster.columns > available_columns) {
        break;
      }

      count = cluster.glyph_end;
    }

    return std::span{glyphs_}.first(count);
  }

  template <Allocator Memory>
  std::uint32_t CellTextLayout<Memory>::columns() const noexcept {
    return columns_;
  }

  template <Allocator Memory>
  std::span<const TextSpan> CellTextLayout<Memory>::spans(std::uint32_t available_columns) const noexcept {
    std::size_t count = 0;

    for (const auto& cluster : clusters_) {
      if (cluster.columns > available_columns) {
        break;
      }

      count = cluster.span_end;
    }

    return std::span{spans_}.first(count);
  }

  template class TextLayout<Memory>;
  template class CellTextLayout<Memory>;
  template class CellTextLayout<ConcurrentMemory>;
  template class TextLayout<ConcurrentMemory>;
  template class IconLayout<Memory>;
  template class IconLayout<ConcurrentMemory>;
  template class RowTextLayout<Memory>;
  template class RowTextLayout<ConcurrentMemory>;

}
