#pragma once

#include "components/source.hpp"
#include "machine_client_key.hpp"
#include <QPointF>
#include <QString>
#include <QVariantList>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

struct ComponentSlotState {
  using Clock = std::chrono::steady_clock;
  QVariantList nodes;
  QString error;
  Clock::time_point next;
  Clock::time_point clock_next = Clock::time_point::max();
  std::uint64_t revision = 0;
  std::uint64_t identity = 0;
};

struct ComponentSurfaceState {
  static constexpr std::size_t bar_slots = components::Definitions::positions;
  std::array<ComponentSlotState, bar_slots> bars;
  ComponentSlotState panel;
  std::optional<std::size_t> open_panel = std::nullopt;
  QString last_render;
  std::uint64_t generation = 0;
  std::uint64_t panel_identity = 0;
  QPointF panel_anchor{-1, -1};
};

struct ComponentCommandOwner {
  std::size_t index = 0;
  bool panel = false;
  std::uint64_t generation = 0;
  std::uint64_t panel_identity = 0;
  MachineClientKey source;
  std::uint64_t runtime = 0;
};

}
