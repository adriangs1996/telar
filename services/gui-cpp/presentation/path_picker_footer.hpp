#pragma once

#include "core/cell_rectangle.hpp"
#include "text/cell_text_measure.hpp"
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui {

template <typename Measure>
concept TextColumnMeasure = requires(Measure &measure, std::string_view text) {
  { measure(text) } -> std::unsigned_integral;
};

struct PathPickerHint {
  std::string_view key;
  std::string_view word;
};

struct PathPickerHintPlacement {
  PathPickerHint label;
  CellRectangle key;
  CellRectangle word;
};

struct PathPickerFooter {
  static constexpr std::size_t maximum_hints = 5;
  static constexpr std::uint16_t status_gap = 3;
  static constexpr std::uint16_t key_gap = 1;
  static constexpr std::uint16_t word_gap = 2;
  static constexpr std::array<PathPickerHint, maximum_hints> mac_hints{{{.key = "↵", .word = "insert"}, {.key = "⇥", .word = "open"}, {.key = "⇧⇥", .word = "parent"}, {.key = "⌥↵", .word = "absolute"}, {.key = "esc", .word = "close"}}};
  static constexpr std::array<PathPickerHint, maximum_hints> pc_hints{{{.key = "enter", .word = "insert"}, {.key = "tab", .word = "open"}, {.key = "shift+tab", .word = "parent"}, {.key = "alt+enter", .word = "absolute"}, {.key = "esc", .word = "close"}}};

  std::array<PathPickerHintPlacement, maximum_hints> hints{};
  std::size_t count = 0;

  template <TextColumnMeasure MeasureColumns>
  [[nodiscard]] static PathPickerFooter measure(CellRectangle row, std::string_view status, bool mac_style, MeasureColumns measure_columns) {
    PathPickerFooter result;
    const auto &labels = mac_style ? mac_hints : pc_hints;
    std::uint32_t used = measure_columns(status) + status_gap;
    for (const auto &label : labels) {
      const auto key = cellTextColumns(label.key);
      const auto word = measure_columns(label.word);
      const auto key_room = key + key_gap;
      if (used + key_room + word > row.width) {
        break;
      }

      result.hints[result.count++] = {
          .label = label,
          .key = {.x = static_cast<std::uint16_t>(row.x + used), .y = row.y, .width = static_cast<std::uint16_t>(key), .height = row.height},
          .word = {.x = static_cast<std::uint16_t>(row.x + used + key_room), .y = row.y, .width = static_cast<std::uint16_t>(word), .height = row.height},
      };
      used += key_room + word + word_gap;
    }

    return result;
  }
};

}
