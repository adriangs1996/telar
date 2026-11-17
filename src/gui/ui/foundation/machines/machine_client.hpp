#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "core/wheel_accumulator.hpp"
#include "machine_effects.hpp"
#include "runtime_connection.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <charconv>
#include <chrono>
#include <climits>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>

#pragma once

import telar.gui.application;
import telar.gui.foundation.system;

namespace telar::gui::qt {

  using GuiSession = application::Session;

  struct MachineClient {
    application::machines::MachineClientKey key;
    RuntimeConnection connection;
    MachineEffects effects;
    GuiSession session;
    std::optional<system::WindowLease> identity_lease;
    std::uint64_t identity = 0;
    std::uint64_t runtime_generation = 0;
    application::machines::MachinePhase phase = application::machines::MachinePhase::connecting;
    bool needs_setup = false;
    bool named_launch = false;
    runtime::FixedText<application::machines::MachineLimits::program_bytes> admitted_program;

    explicit MachineClient(ApplicationAllocator& memory, const MachineEffects::Sinks& sinks, application::machines::MachineClientKey admission)
        : key(admission),
          connection(memory),
          effects(sinks, admission),
          session(memory, connection, effects) {}
  };

  // The client the key names, or null once its slot holds another client or none.
  [[nodiscard]] inline MachineClient* findMachineClient(const application::machines::Machines& machines, const MachineClients& clients, application::machines::MachineClientKey key) noexcept {
    if (!machines.contains(key.machine)) {
      return nullptr;
    }

    const auto& client = clients[key.machine.slot];

    return client && (*client)->key == key ? client->get() : nullptr;
  }

}
