#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/terminal_size.hpp"
#include "machine_client.hpp"
#include "machine_profiles_source.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/app/application.hpp"
#include "ui/app/projection.hpp"
#include "ui/app/runtime_connection.hpp"
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

  bool Application::executeMachineAction(Action action) {
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

  void Application::moveMachine(int delta) {
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

  void Application::refreshMachinePicker() {
    if (store_.dialog().kind == Dialog::palette && palette_query_.startsWith(QLatin1Char(':'))) {
      refreshPalette();
    }
  }

  bool Application::updateMachinePickerResults(std::string_view query) {
    const auto matches = MachinePicker::collect(store_.machines(), query);
    QVariantList rows;

    rows.reserve(static_cast<qsizetype>(matches.rows().size()) + 1);
    for (const auto& match : matches.rows()) {
      rows.append(machinePickerRecord({.machine = match.target}));
    }

    rows.append(machinePickerRecord({.machine = std::nullopt}));
    if (rows == palette_rows_) {
      return false;
    }

    for (std::size_t index = 0; index < matches.rows().size(); ++index) {
      palette_targets_[index] = MachinePickerTarget{.machine = matches.rows()[index].target};
      palette_kinds_[index] = PaletteRowKind::machine;
    }

    const auto last = matches.rows().size();

    palette_targets_[last] = MachinePickerTarget{.machine = std::nullopt};
    palette_kinds_[last] = PaletteRowKind::machine;
    palette_rows_ = std::move(rows);
    palette_selection_ = std::min(palette_selection_, static_cast<std::size_t>(palette_rows_.size() - 1));
    ++palette_revision_;

    return true;
  }

  QVariantMap Application::machinePickerRecord(MachinePickerTarget target) const {
    QVariantMap result{
        {QStringLiteral("kind"), static_cast<int>(PaletteRowKind::machine)},
        {QStringLiteral("detailBelow"), false},
        {QStringLiteral("shortcut"), false},
    };

    if (!target.machine) {
      result.insert(QStringLiteral("key"), QStringLiteral("machine:add"));
      result.insert(QStringLiteral("icon"), QStringLiteral("+"));
      result.insert(QStringLiteral("primary"), QStringLiteral("Add machine…"));
      result.insert(QStringLiteral("secondary"), QStringLiteral("a label and its SSH destination"));
      result.insert(QStringLiteral("hint"), QString{});

      return result;
    }

    const auto token = *target.machine;
    const auto& row = store_.machines().row(token.slot);
    QString state;

    if (!row.enabled) {
      state = QStringLiteral("disabled · enter enables");
    } else if (token.slot == store_.machines().active()) {
      state = QStringLiteral("shown");
    } else {
      switch (row.phase) {
      case MachinePhase::connected:
        state = row.cpu_percent ? QString::number(*row.cpu_percent) + QStringLiteral("% cpu") : QStringLiteral("connected");
        break;
      case MachinePhase::connecting:
        state = QStringLiteral("connecting");
        break;
      case MachinePhase::lost:
        state = QStringLiteral("unreachable · enter retries");
        break;
      case MachinePhase::failed:
        state = row.needs_setup ? QStringLiteral("no telar for this build · enter sets it up") : QStringLiteral("failed · enter retries");
        break;
      case MachinePhase::stopped:
        state = QStringLiteral("disabled");
        break;
      }
    }

    result.insert(QStringLiteral("key"), QStringLiteral("machine:") + QString::number(token.slot) + QLatin1Char(':') + QString::number(token.generation));
    result.insert(QStringLiteral("icon"), row.attention ? QStringLiteral("●") : QStringLiteral("○"));
    result.insert(QStringLiteral("primary"), toQString(row.label.view()));
    result.insert(QStringLiteral("secondary"), row.destination.view().empty() ? QStringLiteral("this machine") : toQString(row.destination.view()));
    result.insert(QStringLiteral("hint"), state);

    return result;
  }

  std::optional<MachinePickerTarget> Application::chosenMachine(const QVariantMap& choice) const {
    if (store_.dialog().kind != Dialog::palette || choice.value(QStringLiteral("revision")).toString() != QString::number(palette_revision_)) {
      return std::nullopt;
    }

    const auto key = choice.value(QStringLiteral("key")).toString();

    for (qsizetype index = 0; index < palette_rows_.size(); ++index) {
      if (palette_rows_[index].toMap().value(QStringLiteral("key")).toString() == key) {
        if (const auto* target = std::get_if<MachinePickerTarget>(&palette_targets_[static_cast<std::size_t>(index)])) {
          return *target;
        }
      }
    }

    return std::nullopt;
  }

  void Application::chooseMachine(MachinePickerTarget target, bool alternate) {
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

  void Application::editMachineResult(const QVariantMap& choice, MachineEditAction action) {
    const auto target = chosenMachine(choice);
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

  void Application::setupMachine(MachineToken target) {
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
