#pragma once

#include "application/dependencies.hpp"
#include "application/session.hpp"
#include "application_effects.hpp"
#include "machine_client_key.hpp"
#include "machines/limits.hpp"
#include "machines/machine_row.hpp"
#include "platform/awake_clock.hpp"
#include "platform/window_lease.hpp"
#include "runtime_connection.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <cstdint>
#include <optional>

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
