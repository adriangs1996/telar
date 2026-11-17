module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.form_field_geometry;

import std;
import telar.tbc;

import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;

import telar.base.text;

// Interface: presentation/path_picker_footer.cppm
export {
  namespace telar::gui {

    template <typename Measure>
    concept TextColumnMeasure = requires(Measure& measure, std::string_view text) {
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

      // The footer places only its own literal hints; the status is measured, not kept.
      // Generic over the caller's measure, so it stays here.
      template <TextColumnMeasure MeasureColumns>
      [[nodiscard]] TBC_GENERIC static tbc::view<PathPickerFooter, tbc::lt::static_storage> measure(CellRectangle row, std::string_view status, bool mac_style, MeasureColumns measure_columns) {
        PathPickerFooter result;
        const auto& labels = mac_style ? mac_hints : pc_hints;
        std::uint32_t used = measure_columns(status) + status_gap;

        for (const auto& label : labels) {
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
}

// Interface: presentation/path_picker_placement.cppm
export {
  namespace telar::gui {

    struct PathPickerPlacement {
      static constexpr std::uint16_t maximum_rows = 10;
      static constexpr std::uint16_t maximum_width = 72;
      static constexpr std::uint16_t chrome_rows = 4;
      static constexpr std::uint16_t cursor_inset = 2;
      static constexpr std::uint16_t fallback_vertical_divisor = 3;

      CellRectangle area;
      bool flipped = false;

      [[nodiscard]] static PathPickerPlacement forPage(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t count) noexcept;
      [[nodiscard]] static PathPickerPlacement place(CellRectangle host, std::optional<CellPosition> cursor, std::uint16_t requested_width, std::uint16_t requested_height) noexcept;
    };

  }
}

// Interface: presentation/path_picker_geometry.cppm
export {
  namespace telar::gui {

    struct PathPickerFieldColumns {
      std::uint16_t root = 0;
      std::uint16_t count = 0;
    };

    struct PathPickerRowPlacement {
      CellRectangle bounds;
      std::size_t index = 0;
    };

    struct PathPickerGeometry {
      CellRectangle root_label;
      CellRectangle query;
      CellRectangle count_label;
      CellRectangle footer;
      CellRectangle empty;
      std::array<PathPickerRowPlacement, PathPickerPlacement::maximum_rows> rows{};
      std::size_t row_count = 0;

      [[nodiscard]] static PathPickerGeometry measure(PathPickerPlacement placement, std::size_t total, std::size_t selection, PathPickerFieldColumns columns) noexcept;
    };

  }
}
