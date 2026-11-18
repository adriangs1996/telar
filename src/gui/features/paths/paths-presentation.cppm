module;
#include "tbc/annotations.hpp"

// How a path is inserted at the shell and how the picker shows its matches, labels, hints and
// where it sits beside the cursor.
export module telar.gui.features.paths:presentation;

import std;
import telar.tbc;

import :page;
import telar.base.text;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.foundation.text;
import telar.base.ds;

// Interface: paths/insertion.cppm
export {
  namespace telar::gui::features::paths {

    class PathInsertion {
    public:
      static constexpr std::string_view paste_begin = BracketedPaste::begin;
      static constexpr std::string_view paste_end = BracketedPaste::end;
      static constexpr std::size_t paste_capacity = PathPickerLimits::quoted_bytes + BracketedPaste::framing_bytes;
      using Text = BoundedText<paste_capacity>;
      using Quoted = BoundedText<PathPickerLimits::quoted_bytes>;
      using AbsolutePath = BoundedText<PathPickerLimits::absolute_bytes>;

      struct Choice {
        std::size_t selection = 0;
        bool absolute = false;
        bool bracketed = false;
      };

      struct JoinParts {
        std::string_view root;
        std::string_view relative;
      };

      [[nodiscard]] static AbsolutePath join(JoinParts parts);

      // The relative path is a suffix of the path, region `a`.
      [[nodiscard]] static tbc::view<ds::Option<std::string_view>, tbc::lt::a> relativeTo(std::string_view anchor, tbc::view<std::string_view, tbc::lt::a> path) noexcept;

      [[nodiscard]] static ds::Option<Quoted> quote(std::string_view word);

      [[nodiscard]] static ds::Option<Text> prepare(const PathPickerPage& page, Choice choice);

      // A word the shell reads as written, with nothing to quote or expand.
      [[nodiscard]] static bool plain(std::string_view word) noexcept;
    };

  }
}

// Interface: paths/label.cppm
export {
  namespace telar::gui::features::paths {

    enum class PathLabelTone : std::uint8_t {
      directory,
      name,
      match,
      ellipsis,
    };

    struct PathLabelRun {
      std::string_view text;
      PathLabelTone tone = PathLabelTone::name;
    };

    class PathLabel {
    public:
      static constexpr std::size_t runs_per_match = 2;
      static constexpr std::size_t structural_runs = 6;
      static constexpr std::size_t maximum_runs = (runs_per_match * PathPickerLimits::query_bytes) + structural_runs;
      static constexpr std::string_view ellipsis = "…";
      static constexpr std::uint32_t ellipsis_columns = 1;

      // The runs view the laid out path, region `a`, until the next layout.
      void layout(tbc::view<std::string_view, tbc::lt::a> path, std::span<const std::uint16_t> positions, std::uint16_t width);

      [[nodiscard]] tbc::view<std::span<const PathLabelRun>, tbc::lt::a> runs() const noexcept;

    private:
      struct Span {
        std::string_view path;
        std::span<const std::uint16_t> positions;
        std::size_t start = 0;
        std::size_t end = 0;
        std::size_t name_start = 0;
      };

      [[nodiscard]] static std::size_t nameStart(std::string_view path) noexcept;

      [[nodiscard]] static std::size_t nextScalar(std::string_view text, std::size_t offset) noexcept;

      [[nodiscard]] static std::size_t fitting(std::string_view text, std::uint32_t width);

      [[nodiscard]] static PathLabelTone toneAt(const Span& span, std::size_t first, std::size_t last) noexcept;

      void appendSpan(tbc::view<Span, tbc::lt::a> span);

      void push(tbc::view<PathLabelRun, tbc::lt::a> run) noexcept;

      tbc::view<std::array<PathLabelRun, maximum_runs>, tbc::lt::a> runs_{};
      std::size_t count_ = 0;
    };

  }
}

// Interface: paths/labels.cppm
export {
  namespace telar::gui::features::paths {

    struct PathPickerLabels {
      static constexpr std::size_t count_bytes = 32;
      using Status = BoundedText<PathPickerLimits::error_bytes>;
      using Count = BoundedText<count_bytes>;

      [[nodiscard]] static std::string_view root(std::string_view path) noexcept;

      [[nodiscard]] static Count count(const PathPickerPage& page);

      [[nodiscard]] static Status status(const PathPickerPage& page);

      [[nodiscard]] static std::string_view empty(const PathPickerPage& page) noexcept;
    };

  }
}

// Interface: presentation/path_picker_footer.cppm
export {
  namespace telar::gui::features::paths {

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
  namespace telar::gui::features::paths {

    struct PathPickerPlacement {
      static constexpr std::uint16_t maximum_rows = 10;
      static constexpr std::uint16_t maximum_width = 72;
      static constexpr std::uint16_t chrome_rows = 4;
      static constexpr std::uint16_t cursor_inset = 2;
      static constexpr std::uint16_t fallback_vertical_divisor = 3;

      CellRectangle area;
      bool flipped = false;

      [[nodiscard]] static PathPickerPlacement forPage(CellRectangle host, ds::Option<CellPosition> cursor, std::uint16_t count) noexcept;
      [[nodiscard]] static PathPickerPlacement place(CellRectangle host, ds::Option<CellPosition> cursor, std::uint16_t requested_width, std::uint16_t requested_height) noexcept;
    };

  }
}

// Interface: presentation/path_picker_geometry.cppm
export {
  namespace telar::gui::features::paths {

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
