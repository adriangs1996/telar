#include "application.hpp"
#include "login_shell.hpp"
#include "machine_client.hpp"
#include "machine_profiles_source.hpp"
#include "machines/failure.hpp"
#include "machines/machine_row.hpp"
#include "machines/machines.hpp"
#include "machines/profile.hpp"
#include "machines/profiles.hpp"
#include "machines/runtime_location.hpp"
#include "platform/environment.hpp"
#include "platform/peer_identity.hpp"
#include "projection.hpp"
#include "remote_bridge.hpp"
#include "runtime_connection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "window_identity.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QString>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <exception>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {

namespace {

MachineFields profileFields(const MachineProfile &profile) {
  return {.id = profile.identity(), .label = profile.label(), .destination = profile.destination(), .color = profile.color(), .enabled = profile.enabled(), .program = profile.program()};
}

std::string_view bytes(QByteArrayView text) {
  return {text.data(), static_cast<std::size_t>(text.size())};
}

}

void Application::initializeMachineProfiles() {
  connect(this, &Application::machinesChanged, this, &Application::refreshMachinePicker);
  connect(this, &Application::windowGeometryChanged, this, &Application::machinePromptChanged);
  connect(this, &Application::configurationChanged, this, &Application::machinePromptChanged);

  machine_retry_.setSingleShot(true);
  machine_retry_.setInterval(RuntimeConnection::reconnect_delay_ms);
  connect(&machine_profiles_, &MachineProfilesSource::changed, this, &Application::applyMachineProfiles);
  connect(&machine_retry_, &QTimer::timeout, this, &Application::applyMachineProfiles);
  connect(&machine_profiles_, &MachineProfilesSource::failed, this, [this] {
    const auto detail = machine_profiles_.error().toUtf8();
    const auto *const title = machine_profiles_.editError() ? "Machine not saved" : "machines.json not applied";
    publishNotification({.level = NotificationLevel::failure, .title = title, .message = bytes(detail), .link = {}});
  });
}

void Application::openMachines(const QString &path) {
  if (!clientAt(Machines::local_slot).identity_lease) {
    throw std::logic_error{"Open the local machine before loading profiles"};
  }

  const platform::ProcessEnvironment environment;
  try {
    const auto runtime = MachineRuntimeLocation::resolve(environment, platform::currentUserId());
    machine_control_endpoint_ = toQString(runtime.endpoint());
    prepare_machine_directory_ = runtime.managedDirectory().has_value();
  } catch (const MachineFailure &) {
    machine_control_endpoint_.clear();
    prepare_machine_directory_ = false;
  }

  machine_profiles_.open(path, QString::fromUtf8(hostname_));
}

void Application::applyMachineProfiles() {
  if (!machine_profiles_.loaded()) {
    return;
  }

  try {
    reconcileMachines();
    machine_retry_.stop();
    emit machinesChanged();
  } catch (const std::exception &error) {
    publishNotification({.level = NotificationLevel::failure, .title = "machines.json not applied", .message = error.what(), .link = {}});
    machine_retry_.start();
  }
}

void Application::reconcileMachines() {
  const auto &profiles = machine_profiles_.profiles();
  const auto hostname = bytes(hostname_);
  const auto local_label = profiles.localLabel().value_or(hostname);
  if (machines_.row(Machines::local_slot).label.view() != local_label) {
    machines_.update(Machines::local_slot, {.label = local_label, .destination = {}});
  }

  for (std::size_t index = 1; index < Machines::capacity; ++index) {
    const auto slot = static_cast<Machines::Slot>(index);
    const auto &row = machines_.row(slot);
    const auto profile_exists = std::ranges::any_of(profiles.rows(), [&row](const MachineProfile &profile) {
      return profile.identity() == row.id;
    });
    if (row.used && row.id.value() != 0 && !profile_exists) {
      retireMachine(slot, MachineRetirement::removed);
      clients_[slot].reset();
      machines_.setLive(slot, false);
      machines_.remove(slot);
    }
  }

  for (const auto &profile : profiles.rows()) {
    reconcileMachine(profile);
  }
}

void Application::reconcileMachine(const MachineProfile &profile) {
  auto fields = profileFields(profile);
  auto slot = machines_.find(profile.identity());
  if (!slot) {
    const auto temporary = machines_.findDestination(profile.destination());
    if (temporary && *temporary != Machines::local_slot && machines_.row(*temporary).id.value() == 0) {
      slot = temporary;
    }
  }

  if (!slot) {
    const auto added = machines_.add(fields);
    if (fields.enabled) {
      admitMachine(added);
    }

    return;
  }

  if (profile.enabled()) {
    machines_.unpin(*slot);
  }

  const auto &previous = machines_.row(*slot);
  fields.enabled = profile.enabled() || previous.pinned;
  const auto was_enabled = previous.enabled;
  const auto moved = previous.destination.view() != fields.destination || previous.program.view() != fields.program.value_or("");
  machines_.update(*slot, fields);
  if (!fields.enabled) {
    if (was_enabled) {
      retireMachine(*slot, MachineRetirement::disabled);
    }

    return;
  }

  const auto &client = clients_[*slot];
  const auto admitted = client && (*client)->key.machine == machines_.token(*slot) && (*client)->admitted_program.view() == fields.program.value_or("");
  if (!was_enabled || moved || !admitted) {
    admitMachine(*slot);
  }
}

void Application::admitMachine(Machines::Slot slot) {
  auto &client = createClient(slot);
  const auto &row = machines_.row(slot);
  client.identity = WindowIdentity::remote(clientAt(Machines::local_slot).identity, row.destination.view());
  client.session.setRestoreLayout(restore_layout_);
  synchronizeWorkbenchGeometry();
  client.connection.openRemote({.destination = toQString(row.destination.view()), .program = toQString(row.program.view()), .local_endpoint = machine_control_endpoint_, .prepare_directory = prepare_machine_directory_});
  summarizeMachine(client);
}

void Application::retireMachine(Machines::Slot slot, MachineRetirement reason) {
  if (slot == machines_.active()) {
    const auto label = toQString(machines_.row(slot).label.view());
    selectMachine(machines_.token(Machines::local_slot));
    const auto state = reason == MachineRetirement::disabled ? QStringLiteral("disabled") : QStringLiteral("removed");
    const auto local = toQString(machines_.row(Machines::local_slot).label.view());
    const auto detail = (label + QStringLiteral(" was ") + state + QStringLiteral("; the window shows ") + local).toUtf8();
    publishNotification({.title = "Machine left the window", .message = bytes(detail), .link = {}});
  }

  if (const auto &client = clients_[slot]) {
    (*client)->connection.close();
    (*client)->session.disconnected();
    static_cast<void>((*client)->session.settlePresentation());
    (*client)->phase = MachinePhase::stopped;
    (*client)->needs_setup = false;
    summarizeMachine(**client);
  }
}

void Application::discoveredMachine(MachineClient &client, const RemoteDiscovery &discovery) {
  const auto path = discovery.shell();
  const std::array arguments{path, std::string_view{"-l"}, std::string_view{"-i"}};
  client.session.setLaunch({.cwd = discovery.home(), .arguments = std::span{arguments}.first(login_shell::script(path) != nullptr ? arguments.size() : 1)});
}

}
