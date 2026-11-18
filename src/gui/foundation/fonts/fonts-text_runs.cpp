module telar.gui.foundation.fonts;

import std;

import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;

namespace telar::gui::inline foundation::inline fonts {

  template <Allocator Memory>
  TextRuns<Memory>::TextRuns(Memory& memory)
      : columns_(memory) {}

  template <Allocator Memory>
  void TextRuns<Memory>::reserve(std::size_t columns) {
    columns_.reserve(columns);
  }

  template <Allocator Memory>
  void TextRuns<Memory>::clear() noexcept {
    columns_.clear();
    inputs_ = 0;
  }

  template <Allocator Memory>
  void TextRuns<Memory>::close(std::uint16_t reach) noexcept {
    if (inputs_ == 0) {
      return;
    }

    const auto limit = reach == 0 || reach > maximum_cells ? maximum_cells : reach;
    auto since = far;

    for (auto& column : columns_.viewMut()) {
      if (!column.joins) {
        since = far;
      }

      since = distanceFromInput(column.role, since);
      column.since = since;
    }

    auto until = far;

    for (auto index = columns_.size(); index-- != 0;) {
      auto& column = columns_.atMut(index);

      until = distanceFromInput(column.role, until);
      column.kept = column.role != fonts::LigatureRole::none && std::min(column.since, until) < limit;
      if (!column.joins) {
        until = far;
      }
    }
  }

  template <Allocator Memory>
  TextRun TextRuns<Memory>::at(std::size_t start) const noexcept {
    if (!columns_[start].kept) {
      return {};
    }

    auto end = start + 1;

    while (end < columns_.size() && columns_[end].kept && columns_[end].joins) {
      ++end;
    }

    const auto count = end - start;

    return {.count = count, .together = count > 1 && count <= maximum_cells};
  }

  template <Allocator Memory>
  std::uint16_t TextRuns<Memory>::distanceFromInput(fonts::LigatureRole role, std::uint16_t distance) noexcept {
    if (role == fonts::LigatureRole::input) {
      return 0;
    }

    return distance == far ? far : static_cast<std::uint16_t>(distance + 1);
  }

  template <Allocator Memory>
  bool TextRuns<Memory>::shapeable(const CellValue& cell) noexcept {
    return cell.width == CellWidth::single && !hasAttribute(cell.style, CellAttribute::invisible) && (cell.length == 1 || !glyphs::Symbol::parse(cell.utf8()));
  }

  template <Allocator Memory>
  CellStyle TextRuns<Memory>::inkStyle(CellStyle style) noexcept {
    if (hasAttribute(style, CellAttribute::inverse)) {
      style.foreground = {};
    } else {
      style.background = {};
    }

    constexpr unsigned underline_shift = 8;
    constexpr unsigned underline_width = 7;
    constexpr auto decorations = (underline_width << underline_shift) | static_cast<unsigned>(CellAttribute::overline) | static_cast<unsigned>(CellAttribute::strikethrough);

    style.underline_color = {};
    style.flags &= static_cast<std::uint16_t>(~decorations);

    return style;
  }

  template <Allocator Memory>
  bool TextRuns<Memory>::typographic(const CellValue& previous, const CellValue& next) noexcept {
    if (previous.length != 1 || next.length != 1) {
      return false;
    }

    return (previous.text[0] == 'f' && (next.text[0] == 'i' || next.text[0] == 'l')) || (previous.text[0] == 's' && next.text[0] == 't');
  }

  template class TextRuns<Memory>;
  template class TextRuns<ConcurrentMemory>;

}
