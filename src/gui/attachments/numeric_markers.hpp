#pragma once

#include "attachments/marker_screen.hpp"
#include "terminal/cell_position.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::gui {

struct NumericAttachmentMarker {
  std::uint16_t number = 0;
  CellPosition start;
  CellPosition end;
};

class NumericAttachmentMarkers {
public:
  explicit NumericAttachmentMarkers(AttachmentMarkerScreen screen) noexcept
      : screen_(screen) {}

  [[nodiscard]] std::optional<NumericAttachmentMarker> next() noexcept {
    while (position_.y < screen_.rows && static_cast<std::uint32_t>(position_.x) + head.size() <= screen_.columns) {
      const auto point = position_;
      if (static_cast<std::uint32_t>(position_.x) + head.size() < screen_.columns) {
        ++position_.x;
      } else {
        position_.x = 0;
        ++position_.y;
      }

      if (const auto marker = parse(screen_, point)) {
        return marker;
      }
    }

    return std::nullopt;
  }

  [[nodiscard]] static std::optional<NumericAttachmentMarker> parse(AttachmentMarkerScreen screen, CellPosition point) noexcept {
    if (!screen.matches(point, head)) {
      return std::nullopt;
    }

    const CellPosition after_head{.x = static_cast<std::uint16_t>(point.x + head.size()), .y = point.y};
    if (screen.matches(after_head, separator)) {
      return tail(screen, point, {.x = static_cast<std::uint16_t>(after_head.x + separator.size()), .y = point.y});
    }

    if (point.y + 1 >= screen.rows || !blankTail(screen, after_head)) {
      return std::nullopt;
    }

    const auto first = firstInk(screen, point.y + 1);
    if (!first || !screen.matches(*first, "#")) {
      return std::nullopt;
    }

    return tail(screen, point, {.x = static_cast<std::uint16_t>(first->x + 1), .y = first->y});
  }

  [[nodiscard]] static std::optional<NumericAttachmentMarker> closest(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
    NumericAttachmentMarkers scan{screen};
    std::optional<NumericAttachmentMarker> best;
    auto best_distance = std::numeric_limits<std::uint32_t>::max();
    while (const auto candidate = scan.next()) {
      if (candidate->number != number) {
        continue;
      }

      const auto row_distance = candidate->end.y > screen.cursor.y ? candidate->end.y - screen.cursor.y : screen.cursor.y - candidate->end.y;
      const auto column_distance = candidate->end.x > screen.cursor.x ? candidate->end.x - screen.cursor.x : screen.cursor.x - candidate->end.x;
      const auto distance = (row_distance * (static_cast<std::uint32_t>(screen.columns) + 1)) + static_cast<std::uint32_t>(column_distance);
      if (distance < best_distance) {
        best = candidate;
        best_distance = distance;
      }
    }

    return best;
  }

  [[nodiscard]] static bool present(AttachmentMarkerScreen screen, std::uint16_t number) noexcept {
    NumericAttachmentMarkers scan{screen};
    while (const auto marker = scan.next()) {
      if (marker->number == number) {
        return true;
      }
    }

    return false;
  }

  [[nodiscard]] static std::optional<std::uint16_t> steps(AttachmentMarkerScreen screen, std::uint16_t row, std::uint16_t first, std::uint16_t last) noexcept {
    if (first > last || last > screen.columns || row >= screen.rows) {
      return std::nullopt;
    }

    std::uint16_t count = 0;
    auto column = first;
    while (column < last) {
      const auto marker = parse(screen, {.x = column, .y = row});
      if (marker && marker->start.y == marker->end.y && marker->end.x <= last) {
        ++count;
        column = marker->end.x;
      } else {
        const auto *const value = screen.cell({.x = column, .y = row});
        count = static_cast<std::uint16_t>(count + (value != nullptr && value->width != CellWidth::continuation ? 1 : 0));
        ++column;
      }
    }

    return count;
  }

private:
  static constexpr std::string_view head = "[Image";
  static constexpr std::string_view separator = " #";
  static constexpr std::uint16_t decimal_base = 10;

  [[nodiscard]] static std::optional<NumericAttachmentMarker> tail(AttachmentMarkerScreen screen, CellPosition start, CellPosition point) noexcept {
    std::uint16_t number = 0;
    for (auto column = point.x; column < screen.columns; ++column) {
      const auto *const cell = screen.cell({.x = column, .y = point.y});
      if (cell == nullptr || cell->width == CellWidth::continuation || cell->length != 1) {
        return std::nullopt;
      }

      const auto byte = cell->text[0];
      if (byte == ']') {
        return column != point.x && number != 0 ? std::optional{NumericAttachmentMarker{.number = number, .start = start, .end = {.x = static_cast<std::uint16_t>(column + 1), .y = point.y}}} : std::nullopt;
      }

      if (byte < '0' || byte > '9' || number > (std::numeric_limits<std::uint16_t>::max() - (byte - '0')) / decimal_base) {
        return std::nullopt;
      }

      number = static_cast<std::uint16_t>((number * decimal_base) + byte - '0');
    }

    return std::nullopt;
  }

  [[nodiscard]] static bool blankTail(AttachmentMarkerScreen screen, CellPosition point) noexcept {
    for (auto column = point.x; column < screen.columns; ++column) {
      const auto *const cell = screen.cell({.x = column, .y = point.y});
      if (cell == nullptr || !AttachmentMarkerScreen::blank(*cell)) {
        return false;
      }
    }

    return true;
  }

  [[nodiscard]] static std::optional<CellPosition> firstInk(AttachmentMarkerScreen screen, std::uint32_t row) noexcept {
    for (std::uint16_t column = 0; column < screen.columns; ++column) {
      const auto *const cell = screen.cell({.x = column, .y = row});
      if (cell != nullptr && !AttachmentMarkerScreen::blank(*cell)) {
        return CellPosition{.x = column, .y = row};
      }
    }

    return std::nullopt;
  }

  AttachmentMarkerScreen screen_;
  CellPosition position_;
};

}
