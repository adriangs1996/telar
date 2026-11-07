module;
#include <exception>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <limits>
#include <string>
#include <variant>
#include <vector>
#include <bit>
#include <utility>
#include <cstdlib>
#include <mutex>
#include <new>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>

#include <algorithm>
#include <cmath>
#include <chrono>

#include <span>

export module telar.gui.presentation.history_filter_geometry;

export import telar.gui.core.metrics;
export import telar.gui.text.json_unsigned_integer;


export import telar.gui.history.browser;


export import telar.gui.machines.picker;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;
import telar.gui.core.primitives;

// Interface: presentation/bar_metrics.cppm
export {
namespace telar::gui {

enum class BarMetric : std::uint8_t {
  cpu,
  memory,
  battery,
};

struct BarMetrics {
  static constexpr std::size_t value_capacity = 16;
  static constexpr std::uint8_t cpu_warning = 90;
  static constexpr std::uint8_t cpu_danger = 98;
  static constexpr std::uint8_t battery_warning = 20;
  static constexpr std::uint8_t battery_danger = 10;
  static constexpr std::uint16_t tenths_per_unit = 10;
  using Value = BoundedText<value_capacity>;

  [[nodiscard]] inline static bool available(BarMetric metric, const SystemMetrics &sample) noexcept {
    return sample.revision != 0 && (metric != BarMetric::battery || sample.has_battery);
  }

  [[nodiscard]] inline static std::string_view glyph(BarMetric metric) noexcept {
    switch (metric) {
    case BarMetric::cpu:
      return "\uf4bc";
    case BarMetric::memory:
      return "\uefc5";
    case BarMetric::battery:
      return {};
    }

    return {};
  }

  [[nodiscard]] inline static Value value(BarMetric metric, const SystemMetrics &sample) {
    Value result;
    if (!available(metric, sample)) {
      return result;
    }

    switch (metric) {
    case BarMetric::cpu:
      result.appendDecimal(sample.cpu_percent);
      result.append("%");
      break;
    case BarMetric::memory:
      result.appendDecimal(static_cast<unsigned>(sample.memory_used_decigib / tenths_per_unit));
      result.append(".");
      result.appendDecimal(static_cast<unsigned>(sample.memory_used_decigib % tenths_per_unit));
      result.append(" GB");
      break;
    case BarMetric::battery:
      result.appendDecimal(sample.battery_percent);
      result.append("%");
      break;
    }

    return result;
  }

  [[nodiscard]] inline static PaletteRole ink(BarMetric metric, const SystemMetrics &sample) noexcept {
    if (!available(metric, sample)) {
      return PaletteRole::text;
    }

    switch (metric) {
    case BarMetric::cpu:
      if (sample.cpu_percent >= cpu_danger) {
        return PaletteRole::red;
      }

      return sample.cpu_percent >= cpu_warning ? PaletteRole::yellow : PaletteRole::text;
    case BarMetric::battery:
      if (sample.battery_percent <= battery_danger) {
        return PaletteRole::red;
      }

      return sample.battery_percent <= battery_warning ? PaletteRole::yellow : PaletteRole::text;
    case BarMetric::memory:
      return PaletteRole::text;
    }

    return PaletteRole::text;
  }
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
  std::string_view subtitle;
  Action action = Action::none;
  bool emphasized = false;

  [[nodiscard]] inline static HistoryEmpty derive(const HistoryEmptyOptions &options) {
    HistoryEmpty result;
    if (options.phase == HistoryPhase::loading && !options.has_page) {
      result.title.append("Searching your command history…");

      return result;
    }

    if (options.phase == HistoryPhase::failed) {
      result.title.append("Could not load the command history");

      return result;
    }

    result.emphasized = true;
    const auto nothing_recorded = !options.has_query && options.scope == HistoryScope::global && options.author == HistoryAuthorFilter::all && !options.failed_only && options.page_offset == 0;
    if (nothing_recorded) {
      result.title.append("No commands yet");
      result.subtitle = "Commands you run in telar appear here as you work. Bring your shell history:";
      result.action = Action::import;

      return result;
    }

    result.subtitle = "Widen the search or check the filters.";
    result.action = options.scope == HistoryScope::global ? Action::none : Action::everywhere;
    switch (options.scope) {
    case HistoryScope::global:
      result.title.append("No matching commands");
      break;
    case HistoryScope::workspace: {
      constexpr std::string_view prefix = "No matches in workspace ";
      if (options.workspace.size() <= title_capacity - prefix.size()) {
        result.title.append(prefix);
        result.title.append(options.workspace);
      } else {
        result.title.append("No matches in this workspace");
      }

      break;
    }
    case HistoryScope::cwd:
      result.title.append("No matches in this directory");

      break;
    case HistoryScope::pane:
      result.title.append("No matches in this pane");

      break;
    }

    return result;
  }
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

  [[nodiscard]] inline static HistoryEmptyGeometry derive(Rect area, ChromeMetrics chrome, HistoryEmptyMeasurements measured) noexcept {
    if (area.empty()) {
      return {};
    }

    const auto title_height = ChromeMetrics::lineHeight(chrome.body);
    const auto small_height = ChromeMetrics::lineHeight(chrome.small);
    const auto stack = title_height + chrome.px(title_gap) + small_height + chrome.px(action_gap) + chrome.px(action_height);
    const auto top = area.y + std::max(0.0F, (area.height - stack) / 2);
    const Rect inner{.x = area.x + chrome.px(side_inset), .y = top, .width = std::max(0.0F, area.width - chrome.px(side_inset * 2)), .height = title_height};
    const auto action_width = std::min(inner.width, measured.action == HistoryEmpty::Action::import ? measured.import + chrome.px(import_inset * 2) : chrome.px(search_width));
    const Rect subtitle{.x = inner.x, .y = inner.y + title_height + chrome.px(title_gap), .width = inner.width, .height = small_height};

    return {.title = centered(inner, measured.title), .subtitle = centered(subtitle, measured.subtitle), .action = {.x = inner.x + std::max(0.0F, (inner.width - action_width) / 2), .y = subtitle.y + small_height + chrome.px(action_gap), .width = action_width, .height = chrome.px(action_height)}};
  }

private:
  [[nodiscard]] inline static Rect centered(Rect area, float advance) noexcept {
    const auto width = std::min(area.width, advance);

    return {.x = area.x + std::max(0.0F, (area.width - width) / 2), .y = area.y, .width = width, .height = area.height};
  }
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

  [[nodiscard]] inline static float width(ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    auto result = measured.label + chrome.px(horizontal_padding * 2);
    if (measured.has_value) {
      result += measured.value + chrome.px(value_gap);
    }

    return result;
  }

  [[nodiscard]] inline static HistoryFilterChipGeometry derive(Rect bounds, ChromeMetrics chrome, HistoryFilterChipMeasurements measured) noexcept {
    HistoryFilterChipGeometry result;
    result.bounds = bounds;
    result.label = {.x = bounds.x + chrome.px(horizontal_padding), .y = bounds.y, .width = std::max(0.0F, bounds.width - chrome.px(horizontal_padding * 2)), .height = bounds.height};
    const auto painted = result.label.empty() ? 0.0F : std::min(measured.label, result.label.width);
    const auto value_x = result.label.x + (painted + chrome.px(value_gap));
    result.value = {.x = value_x, .y = bounds.y, .width = std::max(0.0F, bounds.right() - chrome.px(horizontal_padding) - value_x), .height = bounds.height};

    return result;
  }
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

  [[nodiscard]] inline static HistoryFilterGeometry derive(Rect area, ChromeMetrics chrome, const HistoryFilterMeasurements &measured) noexcept {
    HistoryFilterGeometry result;
    if (area.empty()) {
      return result;
    }

    result.visible = true;
    result.separator = {.x = area.x, .y = area.bottom() - separator_height, .width = area.width, .height = separator_height};
    const auto height = std::min(chrome.px(maximum_chip_height), std::max(0.0F, area.height - chrome.px(vertical_inset)));
    const auto y = area.y + std::floor((area.height - height) / 2);
    auto scope_total = chrome.px(group_padding);
    auto author_total = chrome.px(group_padding);
    for (const auto &chip : measured.scopes) {
      scope_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }
    for (const auto &chip : measured.authors) {
      author_total += HistoryFilterChipGeometry::width(chrome, chip) + chrome.px(chip_inset);
    }

    const auto failed_width = HistoryFilterChipGeometry::width(chrome, {.label = measured.failed});
    const auto gap = chrome.px(group_gap);
    const auto key_spacing = chrome.px(key_gap);
    const auto scope_key_width = measured.keys[0] + key_spacing;
    const auto author_key_width = measured.keys[1] + key_spacing;
    const auto failed_key_width = measured.keys[2] + key_spacing;
    const auto available = area.width - chrome.px(horizontal_inset * 2);
    const auto with_keys = scope_total + scope_key_width + gap + author_total + author_key_width + gap + failed_width + failed_key_width;
    result.show_keys = with_keys <= available;
    result.show_right = result.show_keys || scope_total + gap + author_total + gap + failed_width <= available;

    const auto left = area.x + chrome.px(horizontal_inset);
    result.scope_group = {.x = left, .y = y, .width = scope_total, .height = height};
    const auto scope_end = placeGroup(result.scopes, result.scope_group, chrome, measured.scopes);
    if (result.show_keys) {
      result.keys[0] = {.x = scope_end + key_spacing, .y = y, .width = scope_key_width, .height = height};
    }
    if (!result.show_right) {
      return result;
    }

    auto right = area.right() - chrome.px(horizontal_inset);
    if (result.show_keys) {
      right -= failed_key_width;
      result.keys[2] = {.x = right + key_spacing, .y = y, .width = failed_key_width, .height = height};
    }
    right -= failed_width;
    result.failed = HistoryFilterChipGeometry::derive({.x = right, .y = y, .width = failed_width, .height = height}, chrome, {.label = measured.failed});
    right -= gap;
    if (result.show_keys) {
      right -= author_key_width;
      result.keys[1] = {.x = right + key_spacing, .y = y, .width = author_key_width, .height = height};
    }
    right -= author_total;
    result.author_group = {.x = right, .y = y, .width = author_total, .height = height};
    placeGroup(result.authors, result.author_group, chrome, measured.authors);

    return result;
  }

private:
  template <std::size_t Count>
  inline static float placeGroup(std::array<HistoryFilterChipGeometry, Count> &destination, Rect group, ChromeMetrics chrome, const std::array<HistoryFilterChipMeasurements, Count> &measured) noexcept {
    auto x = group.x + chrome.px(chip_inset);
    for (std::size_t index = 0; index < Count; ++index) {
      const auto width = HistoryFilterChipGeometry::width(chrome, measured[index]);
      destination[index] = HistoryFilterChipGeometry::derive({.x = x, .y = group.y + chrome.px(chip_inset), .width = width, .height = std::max(0.0F, group.height - chrome.px(chip_inset * 2))}, chrome, measured[index]);
      x += width + chrome.px(chip_inset);
    }

    return x + chrome.px(chip_inset);
  }
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

  [[nodiscard]] inline static std::string_view glyph(MachinePhase phase, bool attention) noexcept {
    if (attention || phase == MachinePhase::connected) {
      return "●";
    }

    switch (phase) {
    case MachinePhase::connecting:
      return "◌";
    case MachinePhase::lost:
    case MachinePhase::failed:
      return "✕";
    case MachinePhase::stopped:
      return "○";
    case MachinePhase::connected:
      break;
    }

    return {};
  }

  [[nodiscard]] inline static PaletteRole glyphInk(MachinePhase phase, bool attention) noexcept {
    if (attention) {
      return PaletteRole::yellow;
    }

    switch (phase) {
    case MachinePhase::connected:
      return PaletteRole::green;
    case MachinePhase::connecting:
      return PaletteRole::overlay1;
    case MachinePhase::lost:
      return PaletteRole::peach;
    case MachinePhase::failed:
      return PaletteRole::red;
    case MachinePhase::stopped:
      return PaletteRole::overlay0;
    }

    return PaletteRole::text;
  }

  [[nodiscard]] inline static std::string_view phaseName(MachinePhase phase) noexcept {
    switch (phase) {
    case MachinePhase::connected:
      return "connected";
    case MachinePhase::connecting:
      return "connecting";
    case MachinePhase::lost:
      return "lost";
    case MachinePhase::failed:
      return "failed";
    case MachinePhase::stopped:
      return "stopped";
    }

    return {};
  }

  [[nodiscard]] inline static CpuText cpu(MachinePhase phase, std::optional<std::uint8_t> percent) {
    CpuText value;
    if (phase == MachinePhase::connected && percent) {
      value.appendDecimal(*percent);
      value.append("%");
    }

    return value;
  }

  [[nodiscard]] inline static float width(const ChromeMetrics &chrome, Widths parts) noexcept {
    return parts.glyph + chrome.px(part_gap) + parts.label + (parts.cpu > 0 ? chrome.px(part_gap) + parts.cpu : 0);
  }

  [[nodiscard]] inline static Geometry geometry(Rect area, const ChromeMetrics &chrome, Widths parts) noexcept {
    Geometry result;
    result.bounds = {.x = area.x, .y = area.y, .width = width(chrome, parts), .height = area.height};
    result.glyph = {.x = area.x, .y = area.y, .width = parts.glyph, .height = area.height};
    result.label = {.x = result.glyph.right() + chrome.px(part_gap), .y = area.y, .width = parts.label, .height = area.height};
    if (parts.cpu > 0) {
      result.cpu = {.x = result.label.right() + chrome.px(part_gap), .y = area.y, .width = parts.cpu, .height = area.height};
    }

    return result;
  }
};

}
}
