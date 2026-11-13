#pragma once

#include "core/memory.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui {

struct AttachmentMarkerScreen {
  std::span<const CellValue> cells;
  std::uint16_t columns = 0;
  std::uint16_t rows = 0;
  Cursor cursor;

  template <Allocator Memory>
  [[nodiscard]] static AttachmentMarkerScreen from(const Screen<Memory> &screen) noexcept {
    return {.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .cursor = screen.cursor()};
  }

  [[nodiscard]] const CellValue *cell(CellPosition point) const noexcept {
    if (point.x >= columns || point.y >= rows) {
      return nullptr;
    }

    const auto index = (static_cast<std::size_t>(point.y) * columns) + point.x;

    return index < cells.size() ? &cells[index] : nullptr;
  }

  [[nodiscard]] bool matches(CellPosition point, std::string_view literal) const noexcept {
    if (point.y >= rows || point.x > columns || literal.size() > columns - point.x) {
      return false;
    }

    for (std::size_t offset = 0; offset < literal.size(); ++offset) {
      const auto *const value = cell({.x = static_cast<std::uint16_t>(point.x + offset), .y = point.y});
      if (value == nullptr || value->width == CellWidth::continuation || value->length != 1 || value->text[0] != static_cast<std::uint8_t>(literal[offset])) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] static bool blank(const CellValue &cell) noexcept {
    return cell.width == CellWidth::continuation || cell.utf8() == " ";
  }

  [[nodiscard]] bool isolatedInverse(CellPosition point) const noexcept {
    const auto *const value = cell(point);
    if (value == nullptr || !inverse(*value)) {
      return false;
    }

    const auto *const left = point.x != 0 ? cell({.x = static_cast<std::uint16_t>(point.x - 1), .y = point.y}) : nullptr;
    const auto *const right = cell({.x = static_cast<std::uint16_t>(point.x + 1), .y = point.y});

    return (left == nullptr || !inverse(*left)) && (right == nullptr || !inverse(*right));
  }

  [[nodiscard]] std::optional<CellPosition> editorCursor() const noexcept {
    if (cursor.visible) {
      return CellPosition{.x = cursor.x, .y = cursor.y};
    }

    for (std::uint32_t row = 0; row < rows; ++row) {
      for (std::uint16_t column = 0; column < columns; ++column) {
        const CellPosition point{.x = column, .y = row};
        if (isolatedInverse(point)) {
          return point;
        }
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] bool promptContinues() const noexcept {
    const auto point = editorCursor();

    return point && point->x != 0 && matches({.x = static_cast<std::uint16_t>(point->x - 1), .y = point->y}, "\\");
  }

private:
  [[nodiscard]] static bool inverse(const CellValue &cell) noexcept {
    return (cell.style.flags & static_cast<std::uint16_t>(CellAttribute::inverse)) != 0;
  }
};

}
