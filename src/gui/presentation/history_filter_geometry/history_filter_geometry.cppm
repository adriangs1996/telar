export module telar.gui.presentation.history_filter_geometry;

import std;
import telar.tbc;

export import telar.gui.core.metrics;
export import telar.gui.core.json_writer;
export import telar.gui.text.json_unsigned_integer;

export import telar.gui.history.browser;

export import telar.gui.machines.picker;
import telar.gui.core.primitives;
import telar.wire.vocabulary;

// Interface: presentation/bar_metrics.cppm
export {
  namespace telar::gui {

    struct BarMetrics {
      static constexpr std::size_t value_capacity = 16;
      static constexpr std::uint8_t cpu_warning = MetricLevels::cpu_warning;
      static constexpr std::uint8_t cpu_danger = MetricLevels::cpu_danger;
      static constexpr std::uint8_t memory_warning = MetricLevels::memory_warning;
      static constexpr std::uint8_t memory_danger = MetricLevels::memory_danger;
      static constexpr std::uint8_t battery_warning = MetricLevels::battery_warning;
      static constexpr std::uint8_t battery_danger = MetricLevels::battery_danger;
      static constexpr std::uint16_t tenths_per_unit = 10;
      using Value = BoundedText<value_capacity>;

      [[nodiscard]] static bool available(BarMetric metric, const SystemMetrics& sample) noexcept;
      [[nodiscard]] static std::string_view glyph(BarMetric metric) noexcept;
      [[nodiscard]] static Value value(BarMetric metric, const SystemMetrics& sample);
      [[nodiscard]] static std::uint8_t percent(BarMetric metric, const SystemMetrics& sample) noexcept;
      [[nodiscard]] static MetricSeverity severity(BarMetric metric, const SystemMetrics& sample, int margin = 0) noexcept;
      [[nodiscard]] static PaletteRole ink(MetricSeverity severity) noexcept;
      [[nodiscard]] static PaletteRole ink(BarMetric metric, const SystemMetrics& sample) noexcept;
    };

  }
}

// Interface: presentation/history_actions.cppm
export {
  namespace telar::gui {

    enum class HistoryKeyStyle : std::uint8_t {
      mac,
      pc,
    };

    enum class HistoryCardAction : std::uint8_t {
      copy,
      erase,
      visit,
    };

    enum class HistoryInspectionAction : std::uint8_t {
      submit,
      alternate,
      copy,
      erase,
      visit,
    };

    inline constexpr std::size_t history_inspection_action_count = 5;

    struct HistoryActionLabel {
      std::string_view key;
      std::string_view word;
      HistoryCardAction action;
    };

    struct HistoryActions {
      static constexpr std::size_t count = 3;

      [[nodiscard]] static constexpr std::array<HistoryActionLabel, count> labels(HistoryKeyStyle style) noexcept {
        if (style == HistoryKeyStyle::mac) {
          return {
              HistoryActionLabel{.key = "⌘C", .word = "copy", .action = HistoryCardAction::copy},
              HistoryActionLabel{.key = "⌘⌫", .word = "delete", .action = HistoryCardAction::erase},
              HistoryActionLabel{.key = "⌥↩", .word = "go to pane", .action = HistoryCardAction::visit},
          };
        }

        return {
            HistoryActionLabel{.key = "Ctrl+C", .word = "copy", .action = HistoryCardAction::copy},
            HistoryActionLabel{.key = "Ctrl+D", .word = "delete", .action = HistoryCardAction::erase},
            HistoryActionLabel{.key = "Alt+Enter", .word = "go to pane", .action = HistoryCardAction::visit},
        };
      }

      [[nodiscard]] static constexpr std::string_view inspectionKey(HistoryKeyStyle style) noexcept {
        return style == HistoryKeyStyle::mac ? "⌃O" : "Ctrl+O";
      }
    };

  }
}

// Interface: presentation/history_empty.cppm
export {
  namespace telar::gui {

    struct HistoryEmptyOptions {
      HistoryPhase phase = HistoryPhase::idle;
      HistoryScope scope = HistoryScope::global;
      HistoryAuthorFilter author = HistoryAuthorFilter::human;
      std::string_view workspace;
      std::uint32_t page_offset = 0;
      bool has_page = false;
      bool has_query = false;
      bool failed_only = false;
    };

    struct HistoryEmpty {
      static constexpr std::size_t title_capacity = 96;

      enum class Action : std::uint8_t {
        none,
        import,
        everywhere,
      };

      BoundedText<title_capacity> title;
      tbc::view<std::string_view, tbc::lt::static_storage> subtitle;
      Action action = Action::none;
      bool emphasized = false;

      [[nodiscard]] static tbc::view<HistoryEmpty, tbc::lt::static_storage> derive(const HistoryEmptyOptions& options);
    };

  }
}

// Interface: presentation/history_empty_geometry.cppm
export {
  namespace telar::gui {

    struct HistoryEmptyMeasurements {
      float title = 0;
      float subtitle = 0;
      float import = 0;
      HistoryEmpty::Action action = HistoryEmpty::Action::none;
    };

    struct HistoryEmptyGeometry {
      static constexpr float title_gap = 6;
      static constexpr float action_gap = 14;
      static constexpr float action_height = 28;
      static constexpr float side_inset = 16;
      static constexpr float import_inset = 10;
      static constexpr float import_radius = 4;
      static constexpr float search_width = 180;

      Rect title;
      Rect subtitle;
      Rect action;

      [[nodiscard]] static HistoryEmptyGeometry derive(Rect area, ChromeMetrics chrome, HistoryEmptyMeasurements measured) noexcept;

    private:
      [[nodiscard]] static Rect centered(Rect area, float advance) noexcept;
    };

  }
}

// Interface: presentation/history_filter_chip_geometry.cppm
export {
  namespace telar::gui {

    struct HistoryFilterChipMeasurements {
      float label = 0;
      float value = 0;
      bool has_value = false;
    };

    struct HistoryFilterChipGeometry {
      static constexpr float horizontal_padding = 10;
      static constexpr float value_gap = 6;
      static constexpr float corner_radius = 4;
      static constexpr float ring_width = 1;
      static constexpr float danger_ring_alpha = 0.8F;

      Rect bounds;
      Rect label;
      Rect value;

      [[nodiscard]] static float width(ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept;
      [[nodiscard]] static HistoryFilterChipGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept;
    };

  }
}

// Interface: presentation/history_filter_labels.cppm
export {
  namespace telar::gui {

    struct HistoryFilterLabels {
      struct Choice {
        std::string_view value;
        std::string_view text;
      };

      static constexpr std::array scopes{
          Choice{.value = "global", .text = "All"},
          Choice{.value = "workspace", .text = "Workspace"},
          Choice{.value = "cwd", .text = "Directory"},
          Choice{.value = "pane", .text = "Pane"},
      };
      static constexpr std::array authors{
          Choice{.value = "human", .text = "You"},
          Choice{.value = "agent", .text = "Agents"},
          Choice{.value = "all", .text = "Both"},
      };
      static constexpr std::size_t key_count = 3;
      static constexpr std::string_view failed = "Failed";

      [[nodiscard]] static constexpr std::array<std::string_view, key_count> keys(HistoryKeyStyle style) noexcept {
        return style == HistoryKeyStyle::mac ? std::array<std::string_view, key_count>{"⇥", "⇧⇥", "!"} : std::array<std::string_view, key_count>{"Tab", "Shift+Tab", "!"};
      }
    };

  }
}

// Interface: presentation/history_filter_geometry.cppm
export {
  namespace telar::gui {

    struct HistoryFilterMeasurements {
      std::array<HistoryFilterChipMeasurements, HistoryFilterLabels::scopes.size()> scopes{};
      std::array<HistoryFilterChipMeasurements, HistoryFilterLabels::authors.size()> authors{};
      std::array<float, HistoryFilterLabels::key_count> keys{};
      float failed = 0;
    };

    struct HistoryFilterGeometry {
      static constexpr float horizontal_inset = 16;
      static constexpr float maximum_chip_height = 28;
      static constexpr float vertical_inset = 12;
      static constexpr float group_padding = 4;
      static constexpr float chip_inset = 2;
      static constexpr float group_gap = 8;
      static constexpr float group_radius = 6;
      static constexpr float key_gap = 8;
      static constexpr float separator_height = 1;

      std::array<HistoryFilterChipGeometry, HistoryFilterLabels::scopes.size()> scopes{};
      std::array<HistoryFilterChipGeometry, HistoryFilterLabels::authors.size()> authors{};
      std::array<Rect, HistoryFilterLabels::key_count> keys{};
      HistoryFilterChipGeometry failed;
      Rect scope_group;
      Rect author_group;
      Rect separator;
      bool visible = false;
      bool show_keys = false;
      bool show_right = false;

      [[nodiscard]] static HistoryFilterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFilterMeasurements& measured) noexcept;

    private:
      template <std::size_t Count>
      static float placeGroup(std::array<HistoryFilterChipGeometry, Count>& destination, Rect group, ChromeMetrics chrome, const std::array<HistoryFilterChipMeasurements, Count>& measured) noexcept;
    };

  }
}

// Interface: presentation/machine_facts.cppm
export {
  namespace telar::gui {

    struct MachineFacts {
      static constexpr float machine_gap = 12;
      static constexpr float part_gap = 5;
      static constexpr std::size_t cpu_capacity = 8;
      using CpuText = BoundedText<cpu_capacity>;

      struct Widths {
        float glyph = 0;
        float label = 0;
        float cpu = 0;
      };

      struct Geometry {
        Rect bounds;
        Rect glyph;
        Rect label;
        Rect cpu;
      };

      [[nodiscard]] static std::string_view glyph(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static PaletteRole glyphInk(MachinePhase phase, bool attention) noexcept;
      [[nodiscard]] static std::string_view phaseName(MachinePhase phase) noexcept;
      [[nodiscard]] static CpuText cpu(MachinePhase phase, std::optional<std::uint8_t> percent);
      [[nodiscard]] static float width(const ChromeMetrics& chrome, Widths parts) noexcept;
      [[nodiscard]] static Geometry geometry(Rect area, const ChromeMetrics& chrome, Widths parts) noexcept;
    };

  }
}
