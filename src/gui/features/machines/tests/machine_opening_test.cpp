#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstring>
#include <optional>
#include <string_view>

import telar.testing;
import telar.gui.features.machines;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  using namespace telar::gui::features::machines;

  void savedMachineSelection() {
    MachineProfiles profiles;

    profiles.add(MachineProfile::create(MachineId::fromRaw(1), {.label = "Saved", .destination = "user@host", .enabled = false}));
    check(MachineOpening::saved(profiles, "Saved", "host") == std::optional<std::string_view>{"user@host"}, "Disabled saved labels must resolve");
    check(!MachineOpening::saved(profiles, "host", "host"), "Hostname must select local without a saved local label");
    profiles.relabelLocal("Local");
    check(!MachineOpening::saved(profiles, "Local", "host"), "Explicit local label must select local");
    for (const auto* const label : {"host", "user@host", "missing"}) {
      bool refused = false;

      try {
        static_cast<void>(MachineOpening::saved(profiles, label, "host"));
      } catch (const MachineFailure& failure) {
        refused = failure.code() == MachineError::unknown_machine;
      }

      check(refused, "Saved selection accepts labels, with the explicit local label replacing the hostname");
    }
  }

  void admittedMachineSelection() {
    Machines machines;

    static_cast<void>(machines.add({.label = "Local", .destination = {}}, Machines::local_slot));
    const auto earlier = machines.add({.label = "destination", .destination = "first", .enabled = false});
    const auto later = machines.add({.label = "Saved", .destination = "destination"});

    check(MachineOpening::admitted(machines, "destination") == earlier, "A label/destination ambiguity must retain slot order");
    check(MachineOpening::admitted(machines, "Saved") == later, "An admitted saved label must be reusable");
    check(!MachineOpening::admitted(machines, "Local"), "A remote destination cannot select local by its label");
    machines.remove(earlier);
    check(MachineOpening::admitted(machines, "destination") == later, "Retired matches must not shadow another machine");
  }

  const telar::testing::Case case_saved_machine_selection{"machine_opening.saved_machine_selection", savedMachineSelection};
  const telar::testing::Case case_admitted_machine_selection{"machine_opening.admitted_machine_selection", admittedMachineSelection};

}
