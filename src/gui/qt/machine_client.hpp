#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../application/dependencies.hpp"
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include "../input/wheel_accumulator.hpp"
#include "../terminal/cell_position.hpp"
#include "../terminal/screen.hpp"
#include "application_effects.hpp"
#include "machine_client_key.hpp"
#include "runtime_connection.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/graphics/limits.hpp"
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

#include "application/dependencies.hpp"

import telar.gui.application.session;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.platform.awake_clock;
import telar.gui.platform.window_lease;

namespace telar::gui::qt {

  using GuiSession = Session;

  struct MachineClient {
    MachineClientKey key;
    RuntimeConnection connection;
    ApplicationEffects effects;
    GuiSession session;
    std::optional<platform::WindowLease> identity_lease;
    std::uint64_t identity = 0;
    std::uint64_t runtime_generation = 0;
    MachinePhase phase = MachinePhase::connecting;
    bool needs_setup = false;
    bool named_launch = false;
    runtime::FixedText<MachineLimits::program_bytes> admitted_program;

    explicit MachineClient(ApplicationAllocator& memory, Application& application, MachineClientKey admission)
        : key(admission),
          connection(memory),
          effects(application, admission),
          session(memory, connection, effects) {}
  };

}
