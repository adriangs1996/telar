#pragma once

#include "config/command_tab_reference.hpp"
#include "input/action.hpp"
#include <bit>
#include <cstdint>
#include <optional>
#include <utility>

namespace telar::gui {

[[nodiscard]] inline BindingAction commandTabAction(runtime::config::CommandTabReference reference, std::uint64_t generation) noexcept {
  return {.kind = BindingActionKind::command_tab, .parameter = std::bit_cast<std::int32_t>(reference.epoch), .reference = reference.id, .generation = generation};
}

[[nodiscard]] inline std::optional<runtime::config::CommandTabReference> commandTabReference(BindingAction action) noexcept {
  if (action.kind != BindingActionKind::command_tab || !std::in_range<std::uint16_t>(action.reference)) {
    return std::nullopt;
  }

  return runtime::config::CommandTabReference{.epoch = std::bit_cast<std::uint32_t>(action.parameter), .id = static_cast<std::uint16_t>(action.reference)};
}

}
