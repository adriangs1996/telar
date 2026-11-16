#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/terminal_size.hpp"
#include "machine_profiles_source.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QLatin1StringView>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

import telar.gui.machines.profile_store;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.palette.navigation_label;
import telar.gui.platform.runtime_endpoint;
import telar.gui.presentation.suggestion_geometry;
import telar.config.client;
import telar.gui.text.json_unsigned_integer;

namespace telar::gui::qt {

  bool ApplicationController::executeMachineAction(Action action) {
    switch (action) {
    case Action::machine_picker:
      showPalette(PaletteMode::machines);
      break;
    case Action::next_machine:
      moveMachine(1);
      break;
    case Action::previous_machine:
      moveMachine(-1);
      break;
    case Action::add_machine:
      showMachinePrompt();
      break;
    default:
      return false;
    }

    return true;
  }

  void ApplicationController::showMachinePrompt(std::optional<MachineToken> renamed) {
    if (machine_prompt_.open(renamed)) {
      showDialog(Dialog::machine);
    }
  }

  void ApplicationController::moveMachine(int delta) {
    auto slot = static_cast<int>(store_.machines().active());

    for (std::size_t step = 0; step < Machines::capacity; ++step) {
      slot = (slot + delta + static_cast<int>(Machines::capacity)) % static_cast<int>(Machines::capacity);
      const auto candidate = static_cast<Machines::Slot>(slot);
      if (store_.machines().shown(candidate) && store_.machines().row(candidate).live && store_.clients()[candidate]) {
        selectMachine(store_.machines().token(candidate));

        return;
      }
    }
  }

  void ApplicationController::chooseMachine(MachinePickerTarget target, bool alternate) {
    const auto intent = MachinePicker::choose(store_.machines(), target.machine, alternate);
    if (intent == MachinePicker::Intent::add) {
      showMachinePrompt();

      return;
    }

    showDialog(Dialog::none);
    if (intent == MachinePicker::Intent::none || !target.machine) {
      return;
    }

    const auto token = *target.machine;

    if (intent == MachinePicker::Intent::setup) {
      setupMachine(token);
    } else if (intent == MachinePicker::Intent::enable || intent == MachinePicker::Intent::disable) {
      if (intent == MachinePicker::Intent::disable) {
        store_.machines().unpin(token.slot);
      }

      const auto label = store_.machines().row(token.slot).label.view();

      static_cast<void>(machine_profiles_.edit({.kind = intent == MachinePicker::Intent::enable ? MachineEditKind::enable : MachineEditKind::disable, .label = label, .value = {}}));
    } else if (store_.clients()[token.slot]) {
      auto& client = clientAt(token.slot);
      if (!client.connection.ready()) {
        client.phase = MachinePhase::connecting;
        client.needs_setup = false;
        client.connection.retryNow();
        summarizeMachine(client.key);
      }

      selectMachine(token);
    }
  }

  void ApplicationController::editMachineResult(const QVariantMap& choice, MachineEditAction action) {
    const auto target = palette_.chosenMachine(choice);
    if (!target || !target->machine || !store_.machines().contains(*target->machine) || target->machine->slot == Machines::local_slot) {
      return;
    }

    const auto token = *target->machine;

    applyInteraction([&] {
      if (action == MachineEditAction::rename) {
        showMachinePrompt(token);
      } else {
        const auto label = store_.machines().row(token.slot).label.view();

        static_cast<void>(machine_profiles_.edit({.kind = MachineEditKind::remove, .label = label, .value = {}}));
      }
    });
  }

  void ApplicationController::setupMachine(MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == Machines::local_slot) {
      return;
    }

    const auto& row = store_.machines().row(target.slot);
    const auto program = platform::runtime_endpoint::program();
    constexpr std::string_view title_prefix = "Set up ";
    BoundedText<title_prefix.size() + MachineLimits::label_bytes> title;

    title.append(title_prefix);
    title.append(row.label.view());
    const auto name = row.id.value() == 0 ? row.destination.view() : row.label.view();
    const std::array<std::string_view, 5> arguments{program, "machine", "setup", name, "--confirm"};
    runtime::config::CommandTabView command{.count = arguments.size(), .configured_label = title.view()};

    std::ranges::copy(arguments, command.arguments.begin());
    selectMachine(store_.machines().token(Machines::local_slot));
    static_cast<void>(session().createCommandTab(command));
  }

}
