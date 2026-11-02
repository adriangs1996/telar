#pragma once

#include "cell_position.hpp"
#include "screen.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

using CopyPoint = CellPosition;

enum class CopyDirection : std::uint8_t {
  forward,
  backward,
};
enum class CopyGranularity : std::uint8_t {
  character,
  word,
  line,
};
enum class CopyWordClass : std::uint8_t {
  space,
  word,
  punctuation,
};

struct CopyGrid {
  std::span<const CellValue> cells;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  Scroll scroll;

  [[nodiscard]] std::uint32_t maximumOffset() const noexcept {
    return scroll.total_rows - std::min<std::uint32_t>(scroll.total_rows, rows);
  }

  [[nodiscard]] std::uint32_t lastRow() const noexcept {
    return scroll.total_rows == 0 ? 0 : scroll.total_rows - 1;
  }

  [[nodiscard]] const CellValue *cell(CopyPoint point) const noexcept {
    if (point.x >= columns || point.y < scroll.offset || point.y - scroll.offset >= rows) {
      return nullptr;
    }

    const auto index = (static_cast<std::size_t>(point.y - scroll.offset) * columns) + point.x;

    return index < cells.size() ? &cells[index] : nullptr;
  }

  [[nodiscard]] static bool whitespace(char byte) noexcept {
    return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\x0b' || byte == '\x0c';
  }

  [[nodiscard]] std::optional<CopyWordClass> wordClass(CopyPoint point) const noexcept {
    const auto *value = cell(point);
    if (value == nullptr) {
      return {};
    }

    const auto text = value->utf8();
    if (text.empty() || whitespace(text.front())) {
      return CopyWordClass::space;
    }

    const auto byte = text.front();
    const auto word = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_';

    return word ? CopyWordClass::word : CopyWordClass::punctuation;
  }

  [[nodiscard]] CopyPoint step(CopyPoint point, CopyDirection direction) const noexcept {
    if (direction == CopyDirection::forward) {
      if (static_cast<unsigned>(point.x) + 1 < columns) {
        ++point.x;
      } else if (point.y < lastRow()) {
        point.x = 0;
        ++point.y;
      }
    } else if (point.x != 0) {
      --point.x;
    } else if (point.y != 0) {
      point.x = columns == 0 ? 0 : columns - 1;
      --point.y;
    }

    return point;
  }

  [[nodiscard]] bool blankRow(std::uint32_t absolute_row) const noexcept {
    for (std::uint16_t column = 0; column < columns; ++column) {
      const auto *value = cell({.x = column, .y = absolute_row});
      if (value == nullptr) {
        return false;
      }

      const auto text = value->utf8();
      if (!text.empty() && !whitespace(text.front())) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] std::array<CopyPoint, 2> pointerSpan(CopyPoint point, CopyGranularity granularity) const noexcept {
    auto first = point;
    auto last = point;
    if (granularity == CopyGranularity::line) {
      first.x = 0;
      last.x = columns == 0 ? 0 : columns - 1;
    } else if (granularity == CopyGranularity::word) {
      const auto word = pointerWord(point);
      while (first.x != 0 && pointerWord({.x = static_cast<std::uint16_t>(first.x - 1), .y = point.y}) == word) {
        --first.x;
      }

      while (static_cast<unsigned>(last.x) + 1 < columns && pointerWord({.x = static_cast<std::uint16_t>(last.x + 1), .y = point.y}) == word) {
        ++last.x;
      }
    }

    const auto *first_cell = cell(first);
    const auto *last_cell = cell(last);
    if (first_cell != nullptr && first_cell->width == CellWidth::continuation && first.x != 0) {
      --first.x;
    }

    if (last_cell != nullptr && last_cell->width == CellWidth::wide && static_cast<unsigned>(last.x) + 1 < columns) {
      ++last.x;
    }

    return {first, last};
  }

private:
  [[nodiscard]] bool pointerWord(CopyPoint point) const noexcept {
    const auto *value = cell(point);
    if (value == nullptr) {
      return false;
    }

    const auto text = value->utf8();

    return value->width == CellWidth::continuation || (!text.empty() && text.front() != ' ');
  }
};

template <Allocator Memory>
CopyGrid copyGrid(const Screen<Memory> &screen) noexcept {
  return {screen.cells(), screen.columns(), screen.rows(), screen.scroll()};
}

}
