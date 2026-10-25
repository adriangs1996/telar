#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::runtime::config {

enum class ComponentKind : std::uint8_t {
  label,
  icon,
  mark,
  meter,
  sparkline,
  badge,
  clock,
  metric,
  machines,
  group,
  heading,
  text,
  meter_row,
  key_value,
  callout,
  actions,
  button,
  divider
};

struct ComponentShape {
  ComponentKind kind = ComponentKind::label;
  std::string_view text{};
  std::string_view detail{};
  std::string_view url{};
  const char *action_field = nullptr;
  std::size_t samples = 0;
  unsigned priority = 50;
  unsigned tone_bonus = 0;
};

}
