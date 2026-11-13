#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <cstddef>
#include <limits>
#include <string_view>
#include <array>
#include <span>
#include <stdexcept>
#include <charconv>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <variant>
#include "../terminal/screen.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "../terminal/cell_position.hpp"
#include <bit>
#include <tuple>
#include <cmath>
#include "../input/wheel_accumulator.hpp"
#include "telar_base/memory/allocator.hpp"
#include <memory>
#include "application_effects.hpp"
#include "machine_client_key.hpp"
#include <climits>
#include "runtime_connection.hpp"

#pragma once

#include "application/dependencies.hpp"


import telar.gui.application.session;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.platform.profile_file;
import telar.gui.platform.notification_commands;

namespace telar::gui::qt {

using GuiSession = Session<ApplicationAllocator, RuntimeConnection, platform::AwakeClock, ApplicationEffects>;

struct MachineClient {
  MachineClientKey key;
  RuntimeConnection connection;
  GuiSession session;
  std::optional<platform::WindowLease> identity_lease;
  std::uint64_t identity = 0;
  std::uint64_t runtime_generation = 0;
  MachinePhase phase = MachinePhase::connecting;
  bool needs_setup = false;
  bool named_launch = false;
  runtime::FixedText<MachineLimits::program_bytes> admitted_program;

  explicit MachineClient(ApplicationAllocator &memory, Application &application, MachineClientKey admission)
      : key(admission),
        connection(memory),
        session(memory, connection, ApplicationEffects{.application = application, .source = admission}) {}
};

}
