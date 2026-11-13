#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <algorithm>
#include <exception>
#include <iostream>



import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.machines.profile_store;

namespace {

using namespace telar::gui;
using namespace telar::gui::test;

void savedMachineSelection() {
  MachineProfiles profiles;
  profiles.add(MachineProfile::create(MachineId::fromRaw(1), {.label = "Saved", .destination = "user@host", .enabled = false}));
  require(MachineOpening::saved(profiles, "Saved", "host") == std::optional<std::string_view>{"user@host"}, "Disabled saved labels must resolve");
  require(!MachineOpening::saved(profiles, "host", "host"), "Hostname must select local without a saved local label");
  profiles.relabelLocal("Local");
  require(!MachineOpening::saved(profiles, "Local", "host"), "Explicit local label must select local");
  for (const auto *const label : {"host", "user@host", "missing"}) {
    bool refused = false;
    try {
      static_cast<void>(MachineOpening::saved(profiles, label, "host"));
    } catch (const MachineFailure &failure) {
      refused = failure.code() == MachineError::unknown_machine;
    }

    require(refused, "Saved selection accepts labels, with the explicit local label replacing the hostname");
  }
}

void admittedMachineSelection() {
  Machines machines;
  static_cast<void>(machines.add({.label = "Local", .destination = {}}, Machines::local_slot));
  const auto earlier = machines.add({.label = "destination", .destination = "first", .enabled = false});
  const auto later = machines.add({.label = "Saved", .destination = "destination"});
  require(MachineOpening::admitted(machines, "destination") == earlier, "A label/destination ambiguity must retain slot order");
  require(MachineOpening::admitted(machines, "Saved") == later, "An admitted saved label must be reusable");
  require(!MachineOpening::admitted(machines, "Local"), "A remote destination cannot select local by its label");
  machines.remove(earlier);
  require(MachineOpening::admitted(machines, "destination") == later, "Retired matches must not shadow another machine");
}

}

int main() {
  try {
    savedMachineSelection();
    admittedMachineSelection();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
