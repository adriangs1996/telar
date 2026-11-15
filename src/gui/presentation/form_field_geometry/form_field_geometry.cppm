module;
#include "tbc/annotations.hpp"

export module telar.gui.presentation.form_field_geometry;

import std;
import telar.tbc;

import telar.gui.core.metrics;
import telar.gui.terminal.font_grid;
import telar.gui.text.bounded_editor;

import telar.gui.core.unicode_scalar;
import telar.base.diagnostics;
import telar.base.text;
import telar.gui.core.primitives;
import telar.gui.terminal.screen;

// Interface: presentation/form_field_geometry.cppm
export {
  namespace telar::gui {

    struct FormFieldGeometry {
      static constexpr float horizontal_padding = 12;
      static constexpr float vertical_padding = 8;
      static constexpr float caret_width = 1;
      static constexpr float underline_offset = 2;
      static constexpr float underline_height = 1;

      Rect content;
      float cell_width = 1;
      float line_height = 1;
      float insertion_width = 1;
      std::uint16_t columns = 0;

      [[nodiscard]] static FormFieldGeometry derive(Rect bounds, ChromeMetrics chrome, const FontGrid& grid) noexcept;
      [[nodiscard]] Rect caret(std::uint16_t column) const noexcept;
      [[nodiscard]] static FormFieldGeometry terminal(Rect bounds, const FontGrid& grid) noexcept;
      [[nodiscard]] Rect selection(EditorColumns selected) const noexcept;
      [[nodiscard]] Rect underline(std::uint32_t text_columns) const noexcept;
    };

  }
}

// Interface: presentation/history_match_highlight.cppm
export {
  namespace telar::gui {

    template <typename Sink>
    concept HistoryMatchSink = requires(Sink& sink, Rect bounds, std::string_view text) {
      { sink(bounds, text) } -> std::same_as<void>;
    };

    class HistoryMatchHighlight {
    public:
      explicit HistoryMatchHighlight(std::string_view query) noexcept;

      [[nodiscard]] std::size_t matched() const noexcept;

      // Generic over the caller's sink, so it stays here; it runs per history row painted.
      template <HistoryMatchSink Sink>
      TBC_GENERIC void paint(std::string_view text, Rect bounds, float cell_width, Sink& sink) {
        GraphemeCursor cursor{text};
        std::uint32_t column = 0;

        while (static_cast<float>(column) * cell_width < bounds.width && matched_ < query_.size()) {
          const auto cluster = cursor.nextReplacingInvalid();
          if (!cluster) {
            break;
          }

          const auto width = static_cast<float>(cursor.columns()) * cell_width;
          const auto x = static_cast<float>(column) * cell_width;
          if (x + width > bounds.width) {
            break;
          }

          if (cluster->size() <= query_.size() - matched_ && runtime::asciiEqualIgnoreCase(*cluster, query_.substr(matched_, cluster->size()))) {
            sink({.x = bounds.x + x, .y = bounds.y, .width = width, .height = bounds.height}, *cluster);
            matched_ += cluster->size();
          }

          column += cursor.columns();
        }
      }

    private:
      std::string_view query_;
      std::size_t matched_ = 0;
    };

  }
}

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

// Interface: presentation/suggestion_preview.cppm
export {
  namespace telar::gui {

    struct SuggestionPreviewLine {
      std::string_view text;
      Rect bounds;
      bool shortened = false;
    };

    class SuggestionPreview {
    public:
      static constexpr std::string_view shortened_message = "Preview shortened. Review the full command after pasting.";

      SuggestionPreview(std::string_view text, Rect bounds, const FontGrid& grid);

      [[nodiscard]] std::optional<SuggestionPreviewLine> next();

    private:
      [[nodiscard]] static std::uint16_t columns(Rect bounds, std::uint16_t width);

      Rect bounds_;
      float line_height_;
      float y_;
      WrappedLines lines_;
      bool finished_ = false;
    };

  }
}
