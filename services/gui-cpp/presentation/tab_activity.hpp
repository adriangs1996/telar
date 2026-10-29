#pragma once

#include "agent_order.hpp"
#include "agent_status.hpp"
#include "application/records.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "progress_geometry.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui {

struct TabActivity {
  static constexpr float dot_side = 6;
  static constexpr float spinner_side = 12;
  static constexpr float spinner_fraction = 0.3F;
  static constexpr unsigned spinner_steps = 8;
  static constexpr std::uint64_t spinner_interval_ns = 120'000'000;

  enum class Kind : std::uint8_t {
    none,
    dot,
    spinner,
    progress,
  };

  Kind kind = Kind::none;
  PaletteRole color = PaletteRole::teal;
  std::optional<PaletteRole> attention = std::nullopt;

  [[nodiscard]] float width() const noexcept {
    switch (kind) {
    case Kind::dot:
      return dot_side;
    case Kind::spinner:
      return spinner_side;
    case Kind::progress:
      return ProgressGeometry::compactWidth();
    default:
      return 0;
    }
  }

  template <Allocator Memory>
  [[nodiscard]] static TabActivity derive(const Tab<Memory> &tab, const Pane<Memory> *focused, std::span<const Agent<Memory>> agents, bool selected) noexcept {
    const Agent<Memory> *urgent = nullptr;
    for (const auto &agent : agents) {
      if (sameTab(agent.location, tab.location) && (urgent == nullptr || AgentOrder::priority(agent) < AgentOrder::priority(*urgent))) {
        urgent = &agent;
      }
    }

    TabActivity activity;
    if (urgent != nullptr && AgentOrder::attention(urgent->status) == AgentOrder::Attention::needs_input) {
      activity.attention = AgentStatusPresentation::color(urgent->status);
    }

    if (selected && tab.layout.nodes().size() == 1 && focused != nullptr && focused->progress_state != PaneProgressState::remove) {
      activity.kind = Kind::progress;
      if (focused->progress_state == PaneProgressState::error) {
        activity.color = PaletteRole::red;
      } else if (focused->progress_state == PaneProgressState::pause) {
        activity.color = PaletteRole::yellow;
      }

      return activity;
    }

    if (urgent == nullptr) {
      return activity;
    }

    switch (urgent->status) {
    case AgentStatus::working:
      activity.kind = Kind::spinner;
      break;
    case AgentStatus::blocked:
    case AgentStatus::failed:
    case AgentStatus::done:
      activity.kind = Kind::dot;
      activity.color = AgentStatusPresentation::color(urgent->status);
      break;
    default:
      break;
    }

    return activity;
  }
};

}
