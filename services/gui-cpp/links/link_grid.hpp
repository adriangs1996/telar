#pragma once

#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct LinkGrid {
  std::span<const CellValue> cells;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  Scroll scroll{};
  std::span<const Byte> row_flags;

  [[nodiscard]] std::optional<std::size_t> cellIndex(CellPosition point) const noexcept {
    if (columns == 0 || cells.size() != static_cast<std::size_t>(columns) * rows || point.x >= columns || point.y < scroll.offset || point.y - scroll.offset >= rows) {
      return {};
    }

    auto index = (static_cast<std::size_t>(point.y - scroll.offset) * columns) + point.x;
    if (padding(index)) {
      return {};
    }

    if (cells[index].width == CellWidth::continuation) {
      if (point.x == 0 || cells[index - 1].width != CellWidth::wide) {
        return {};
      }

      --index;
    }

    return index;
  }

  [[nodiscard]] std::optional<std::size_t> previous(std::size_t index) const noexcept {
    while (index != 0) {
      if (index % columns == 0 && !joins((index / columns) - 1)) {
        return {};
      }

      --index;
      if (!padding(index)) {
        return index;
      }
    }

    return {};
  }

  [[nodiscard]] std::optional<std::size_t> next(std::size_t index) const noexcept {
    while (index + 1 < cells.size()) {
      if ((index + 1) % columns == 0 && !joins(index / columns)) {
        return {};
      }

      ++index;
      if (!padding(index)) {
        return index;
      }
    }

    return {};
  }

  [[nodiscard]] CellPosition position(std::size_t index) const noexcept {
    return {.x = static_cast<std::uint16_t>(index % columns), .y = scroll.offset + static_cast<std::uint32_t>(index / columns)};
  }

  [[nodiscard]] CellPosition cellEnd(std::size_t index) const noexcept {
    auto result = position(index);
    result.x = static_cast<std::uint16_t>(std::min<unsigned>(columns, result.x + std::max(1U, static_cast<unsigned>(cells[index].width))));

    return result;
  }

  [[nodiscard]] bool complete(CellPosition first, CellPosition last) const noexcept {
    if (row_flags.empty()) {
      return true;
    }

    if (first.y == scroll.offset && first.x == 0 && flag(0, RowFlag::continuation)) {
      return false;
    }

    const auto last_row = row_flags.size() - 1;
    const auto last_column = columns - static_cast<unsigned>(flag(last_row, RowFlag::wide_padding));

    return last.y - scroll.offset != last_row || last.x != last_column || !flag(last_row, RowFlag::wrap);
  }

private:
  [[nodiscard]] bool flag(std::size_t row, RowFlag value) const noexcept {
    return row < row_flags.size() && (row_flags[row] & static_cast<Byte>(value)) != 0;
  }

  [[nodiscard]] bool padding(std::size_t index) const noexcept {
    return flag(index / columns, RowFlag::wide_padding) && index % columns == columns - 1;
  }

  [[nodiscard]] bool joins(std::size_t row) const noexcept {
    return row + 1 < row_flags.size() && flag(row, RowFlag::wrap) && flag(row + 1, RowFlag::continuation);
  }
};

}
