#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "foundation/core/wheel_accumulator.hpp"
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
import telar.base.ds;

namespace telar::gui::qt {

  using GuiSession = application::Session;

  struct MachineClient {
    application::machines::MachineClientKey key;
    // The connection allocates from the window's memory, and the effects reach the desktop it lends,
    // region `a`.
    tbc::view<RuntimeConnection, tbc::lt::a> connection;
    tbc::view<MachineEffects, tbc::lt::a> effects;
    // Talks through `connection` and reports to `effects`, its siblings, so the client stays put.
    tbc::view<GuiSession, tbc::lt::self> session;
    ds::Option<system::WindowLease> identity_lease;
    std::uint64_t identity = 0;
    std::uint64_t runtime_generation = 0;
    application::machines::MachinePhase phase = application::machines::MachinePhase::connecting;
    bool needs_setup = false;
    bool named_launch = false;
    runtime::FixedText<application::machines::MachineLimits::program_bytes> admitted_program;

    explicit MachineClient(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, tbc::holds<const MachineEffects::Sinks&, tbc::lt::a> sinks, application::machines::MachineClientKey admission)
        : key(admission),
          connection(memory),
          effects(sinks, admission),
          session(memory, connection, effects) {}

    // Whether the window shows this client's machine: its session draws and its effects reach the
    // desktop only then.
    void setPresented(bool presented) {
      session.setPresented(presented);
      effects.setPresented(presented);
    }

    MachineClient(const MachineClient&) = delete;
    MachineClient& operator=(const MachineClient&) = delete;
    MachineClient(MachineClient&&) = delete;
    MachineClient& operator=(MachineClient&&) = delete;
  };

  // The client the key names, or null once its slot holds another client or none.
  [[nodiscard]] inline tbc::view<const MachineClient*, tbc::lt::a> findMachineClient(const application::machines::Machines& machines, tbc::view<const MachineClients&, tbc::lt::a> clients, application::machines::MachineClientKey key) noexcept {
    if (!machines.contains(key.machine)) {
      return nullptr;
    }

    const auto& client = clients[key.machine.slot];

    return client && (*client)->key == key ? &client->get() : nullptr;
  }

  [[nodiscard]] inline tbc::view<MachineClient*, tbc::lt::a> findMachineClientMut(const application::machines::Machines& machines, tbc::view<MachineClients&, tbc::lt::a> clients, application::machines::MachineClientKey key) noexcept {
    if (!machines.contains(key.machine)) {
      return nullptr;
    }

    auto& client = clients.atMut(key.machine.slot);

    return client && (*client)->key == key ? &client.getMut().getMut() : nullptr;
  }

}
