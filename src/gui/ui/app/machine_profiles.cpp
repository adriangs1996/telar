#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "platform/environment.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/remote_bridge.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/machines/window_identity.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/machine_prompt/machine_profiles_source.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QString>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/un.h>
#include <system_error>
#include <vector>

#include "platform/environment.hpp"

import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.machines.profile_store;
import telar.gui.platform.peer_identity;

namespace telar::gui::qt {

  namespace {

    MachineFields profileFields(const MachineProfile& profile) {
      return {.id = profile.identity(), .label = profile.label(), .destination = profile.destination(), .color = profile.color(), .enabled = profile.enabled(), .program = profile.program()};
    }

    std::string_view bytes(QByteArrayView text) {
      return {text.data(), static_cast<std::size_t>(text.size())};
    }

  }

  void ApplicationController::initializeMachineProfiles() {
    connect(this, &ApplicationController::machinesChanged, &palette_, &PaletteController::refreshMachines);

    machine_retry_.setSingleShot(true);
    constexpr int profile_retry_ms = 1000;

    machine_retry_.setInterval(profile_retry_ms);
    connect(&machine_profiles_, &MachineProfilesSource::changed, this, &ApplicationController::applyMachineProfiles);
    connect(&machine_retry_, &QTimer::timeout, this, &ApplicationController::applyMachineProfiles);
    connect(&machine_profiles_, &MachineProfilesSource::failed, this, [this] {
      const auto detail = machine_profiles_.error().toUtf8();
      const auto* const title = machine_profiles_.editError() ? "Machine not saved" : "machines.json not applied";

      notifications_.publish({.level = NotificationLevel::failure, .title = title, .message = bytes(detail), .link = {}});
      if (remote_launch_) {
        applyMachineProfiles();
      }
    });
  }

  void ApplicationController::openMachines(const QString& path) {
    if (!clientAt(Machines::local_slot).identity_lease) {
      throw std::logic_error{"Open the local machine before loading profiles"};
    }

    const platform::ProcessEnvironment environment;

    try {
      const auto runtime = MachineRuntimeLocation::resolve(environment, platform::currentUserId());

      machine_control_endpoint_ = toQString(runtime.endpoint());
      prepare_machine_directory_ = runtime.managedDirectory().has_value();
    } catch (const MachineFailure&) {
      machine_control_endpoint_.clear();
      prepare_machine_directory_ = false;
    }

    machine_profiles_.open(path, QString::fromUtf8(hostname_));
  }

  void ApplicationController::applyMachineProfiles() {
    if (!machine_profiles_.loaded() && (!remote_launch_ || machine_profiles_.error().isEmpty())) {
      return;
    }

    try {
      if (machine_profiles_.loaded()) {
        reconcileMachines();
      }

      try {
        openRequestedMachine();
      } catch (const MachineFailure& failure) {
        remote_launch_.reset();
        emit machineLaunchFailed(QString::fromUtf8(failure.what()));
      }

      machine_retry_.stop();
      emit machinesChanged();
    } catch (const std::exception& error) {
      notifications_.publish({.level = NotificationLevel::failure, .title = "machines.json not applied", .message = error.what(), .link = {}});
      machine_retry_.start();
    }
  }

  void ApplicationController::reconcileMachines() {
    // A copy: reconciling mutates the application that owns the profiles, which are few and bounded.
    const auto profiles = machine_profiles_.profiles();
    const auto hostname = bytes(hostname_);
    const auto local_label = profiles.localLabel().value_or(hostname);
    if (store_.machines().row(Machines::local_slot).label.view() != local_label) {
      store_.machines().update(Machines::local_slot, {.label = local_label, .destination = {}});
    }

    for (std::size_t index = 1; index < Machines::capacity; ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      const auto& row = store_.machines().row(slot);
      const auto profile_exists = std::ranges::any_of(profiles.rows(), [&row](const MachineProfile& profile) {
        return profile.identity() == row.id;
      });
      if (row.used && row.id.value() != 0 && !profile_exists) {
        retireMachine(slot, MachineRetirement::removed);
        store_.clients()[slot].reset();
        store_.machines().setLive(slot, false);
        store_.machines().remove(slot);
      }
    }

    for (const auto& profile : profiles.rows()) {
      reconcileMachine(profile);
    }
  }

  void ApplicationController::reconcileMachine(const MachineProfile& profile) {
    auto fields = profileFields(profile);
    auto slot = store_.machines().find(profile.identity());
    if (!slot) {
      const auto temporary = store_.machines().findDestination(profile.destination());
      if (temporary && *temporary != Machines::local_slot && store_.machines().row(*temporary).id.value() == 0) {
        slot = temporary;
      }
    }

    if (!slot) {
      const auto added = store_.machines().add(fields);

      if (fields.enabled) {
        admitMachine(added);
      }

      return;
    }

    if (profile.enabled()) {
      store_.machines().unpin(*slot);
    }

    const auto& previous = store_.machines().row(*slot);

    fields.enabled = profile.enabled() || previous.pinned;
    const auto was_enabled = previous.enabled;
    const auto moved = previous.destination.view() != fields.destination || previous.program.view() != fields.program.value_or("");

    store_.machines().update(*slot, fields);
    if (!fields.enabled) {
      if (was_enabled) {
        retireMachine(*slot, MachineRetirement::disabled);
      }

      return;
    }

    const auto& client = store_.clients()[*slot];
    const auto admitted = client && (*client)->key.machine == store_.machines().token(*slot) && (*client)->admitted_program.view() == fields.program.value_or("");
    if (!was_enabled || moved || !admitted) {
      admitMachine(*slot);
    }
  }

  void ApplicationController::admitMachine(Machines::Slot slot) {
    {
      auto& created = createClient(slot);

      created.identity = WindowIdentity::remote(clientAt(Machines::local_slot).identity, store_.machines().row(slot).destination.view());
      created.session.setRestoreLayout(restore_layout_);
    }

    synchronizeWorkbenchGeometry();
    auto& client = clientAt(slot);
    const auto& row = store_.machines().row(slot);

    client.connection.openRemote({.destination = toQString(row.destination.view()), .program = toQString(row.program.view()), .local_endpoint = machine_control_endpoint_, .prepare_directory = prepare_machine_directory_});
    summarizeMachine(client.key);
  }

  void ApplicationController::retireMachine(Machines::Slot slot, MachineRetirement reason) {
    if (slot == store_.machines().active()) {
      const auto label = toQString(store_.machines().row(slot).label.view());

      selectMachine(store_.machines().token(Machines::local_slot));
      const auto state = reason == MachineRetirement::disabled ? QStringLiteral("disabled") : QStringLiteral("removed");
      const auto local = toQString(store_.machines().row(Machines::local_slot).label.view());
      const auto detail = (label + QStringLiteral(" was ") + state + QStringLiteral("; the window shows ") + local).toUtf8();

      notifications_.publish({.title = "Machine left the window", .message = bytes(detail), .link = {}});
    }

    if (const auto& client = store_.clients()[slot]) {
      (*client)->connection.close();
      (*client)->session.disconnected();
      static_cast<void>((*client)->session.settlePresentation());
      (*client)->phase = MachinePhase::stopped;
      (*client)->needs_setup = false;
      summarizeMachine((*client)->key);
    }
  }

}
