#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "core/terminal_size.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
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
import telar.gui.machines.picker;
import telar.gui.palette.navigation_label;
import telar.gui.presentation.suggestion_geometry;
import telar.config.client;

namespace telar::gui::qt {

  bool ApplicationController::executeMachineAction(window_actions::Action action) {
    switch (action) {
    case window_actions::Action::machine_picker:
      dialogs_.showPalette(PaletteMode::machines);
      break;
    case window_actions::Action::next_machine:
      machines_.move(1);
      break;
    case window_actions::Action::previous_machine:
      machines_.move(-1);
      break;
    case window_actions::Action::add_machine:
      dialogs_.showMachinePrompt();
      break;
    default:
      return false;
    }

    return true;
  }

  void ApplicationController::editMachineResult(const QVariantMap& choice, window_actions::MachineEditAction action) {
    const auto target = palette_.chosenMachine(choice);
    if (!target || !target->machine || !store_.machines().contains(*target->machine) || target->machine->slot == Machines::local_slot) {
      return;
    }

    const auto token = *target->machine;

    applyInteraction([&] {
      if (action == window_actions::MachineEditAction::rename) {
        dialogs_.showMachinePrompt(token);
      } else {
        const auto label = store_.machines().row(token.slot).label.view();

        static_cast<void>(machine_profiles_.edit({.kind = MachineEditKind::remove, .label = label, .value = {}}));
      }
    });
  }

}
