#pragma once

#include "core/color.hpp"
#include "core/memory.hpp"
#include "fonts/ligature_role.hpp"
#include "glyphs/symbol.hpp"
#include "screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <algorithm>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>

namespace telar::gui {

template <typename Coverage>
concept LigatureRoles = requires(const Coverage &coverage, std::string_view text) {
  { coverage.role(text) } -> std::same_as<fonts::LigatureRole>;
};

struct TextRun {
  std::size_t count = 1;
  bool together = false;
};

template <Allocator Memory>
class TextRuns {
public:
  static constexpr std::size_t maximum_cells = 128;
  static constexpr std::size_t maximum_bytes = maximum_cells * CellValue::text_capacity;
  static constexpr std::size_t maximum_glyphs = 2 * maximum_cells;

  explicit TextRuns(Memory &memory)
      : columns_(AllocatorRef<Column, Memory>{memory}) {}

  void reserve(std::size_t columns) {
    columns_.reserve(columns);
  }

  void clear() noexcept {
    columns_.clear();
    inputs_ = 0;
  }

  template <LigatureRoles Coverage>
  void append(const Coverage &coverage, const CellValue &cell, bool alone) {
    const auto role = alone || !shapeable(cell) ? fonts::LigatureRole::none : coverage.role(cell.utf8());
    const auto joins = role != fonts::LigatureRole::none && !columns_.empty() && columns_.back().role != fonts::LigatureRole::none && inkStyle(previous_.style) == inkStyle(cell.style) && !typographic(previous_, cell);
    columns_.push_back({.role = role, .joins = joins});
    previous_ = cell;
    inputs_ += static_cast<std::size_t>(role == fonts::LigatureRole::input);
  }

  void close(std::uint16_t reach) noexcept {
    if (inputs_ == 0) {
      return;
    }

    const auto limit = reach == 0 || reach > maximum_cells ? maximum_cells : reach;
    auto since = far;
    for (auto &column : columns_) {
      if (!column.joins) {
        since = far;
      }

      since = distanceFromInput(column.role, since);
      column.since = since;
    }

    auto until = far;
    for (auto iterator = columns_.rbegin(); iterator != columns_.rend(); ++iterator) {
      auto &column = *iterator;
      until = distanceFromInput(column.role, until);
      column.kept = column.role != fonts::LigatureRole::none && std::min(column.since, until) < limit;
      if (!column.joins) {
        until = far;
      }
    }
  }

  [[nodiscard]] TextRun at(std::size_t start) const noexcept {
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

private:
  static constexpr auto far = std::numeric_limits<std::uint16_t>::max();

  struct Column {
    fonts::LigatureRole role = fonts::LigatureRole::none;
    bool joins = false;
    bool kept = false;
    std::uint16_t since = far;
  };

  [[nodiscard]] static std::uint16_t distanceFromInput(fonts::LigatureRole role, std::uint16_t distance) noexcept {
    if (role == fonts::LigatureRole::input) {
      return 0;
    }

    return distance == far ? far : static_cast<std::uint16_t>(distance + 1);
  }

  [[nodiscard]] static bool shapeable(const CellValue &cell) noexcept {
    return cell.width == CellWidth::single && !hasAttribute(cell.style, CellAttribute::invisible) && (cell.length == 1 || !glyphs::Symbol::parse(cell.utf8()));
  }

  [[nodiscard]] static CellStyle inkStyle(CellStyle style) noexcept {
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

  [[nodiscard]] static bool typographic(const CellValue &previous, const CellValue &next) noexcept {
    if (previous.length != 1 || next.length != 1) {
      return false;
    }

    return (previous.text[0] == 'f' && (next.text[0] == 'i' || next.text[0] == 'l')) || (previous.text[0] == 's' && next.text[0] == 't');
  }

  Vector<Column, Memory> columns_;
  CellValue previous_;
  std::size_t inputs_ = 0;
};

}
