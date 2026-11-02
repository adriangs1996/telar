#pragma once

#include "config/component_shape.hpp"
#include "core/color_name.hpp"
#include "input/action.hpp"
#include "memory/fixed_text.hpp"
#include "presentation/bar_metrics.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>

namespace telar::gui::components {

using Kind = runtime::config::ComponentKind;

enum class Tone : std::uint8_t {
  neutral,
  muted,
  accent,
  success,
  warning,
  danger,
};

enum class Mark : std::uint8_t {
  claude,
  codex,
  pi,
  telar,
};

struct Style {
  std::optional<ColorName::Value> foreground = std::nullopt;
  std::optional<ColorName::Value> background = std::nullopt;
  bool bold = false;
  bool italic = false;
  bool faint = false;
  bool underline = false;
  bool strikethrough = false;
};

struct Range {
  std::uint16_t offset = 0;
  std::uint16_t length = 0;
};

struct Node {
  static constexpr std::uint8_t no_parent = std::numeric_limits<std::uint8_t>::max();
  static constexpr std::uint8_t no_action = no_parent;
  static constexpr std::size_t maximum_nodes = no_parent - 1;
  static constexpr std::size_t maximum_samples = 120;
  static constexpr std::size_t maximum_icon_bytes = 32;
  static constexpr std::uint8_t default_priority = 50;
  static constexpr std::uint8_t maximum_priority = 100;
  static constexpr std::uint16_t full_scale = 1000;
  static constexpr std::uint8_t warning_bonus = 20;
  static constexpr std::uint8_t danger_bonus = 40;

  Kind kind = Kind::label;
  std::uint8_t parent = no_parent;
  bool tooltip = false;
  Range text{};
  Range detail{};
  Range url{};
  Range samples{};
  std::optional<runtime::FixedText<maximum_icon_bytes>> icon = std::nullopt;
  std::optional<Mark> mark = std::nullopt;
  BarMetric metric = BarMetric::cpu;
  Tone tone = Tone::neutral;
  Style style{};
  std::uint16_t value = 0;
  std::optional<std::uint16_t> marker = std::nullopt;
  std::uint8_t priority = default_priority;
  bool primary = false;
  std::uint8_t action = no_action;

  [[nodiscard]] unsigned effectivePriority() const noexcept {
    unsigned bonus = 0;
    if (tone == Tone::warning) {
      bonus = warning_bonus;
    } else if (tone == Tone::danger) {
      bonus = danger_bonus;
    }

    return std::min<unsigned>(priority + bonus, std::numeric_limits<std::uint8_t>::max());
  }

  [[nodiscard]] bool container() const noexcept {
    return kind == Kind::group || kind == Kind::callout || kind == Kind::actions;
  }
};

struct Input {
  Node node{};
  std::string_view text;
  std::string_view detail;
  std::string_view url;
  std::span<const std::uint8_t> samples;
  std::optional<BindingAction> action = std::nullopt;
};

}
