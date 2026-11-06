#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <variant>
#include <utility>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <limits>
#include <span>
#include "telar_base/text/utf8.hpp"
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <string>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include "machine_client_key.hpp"
#include <QPointF>
#include <QString>
#include <QVariantList>

#pragma once


import telar.gui.components.configuration;

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
