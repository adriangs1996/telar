#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_roster.hpp"
#include "dialogs.hpp"
#include "machines_coordinator.hpp"
#include "platform/environment.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
#include "ui/app/overlays/notifications/notifications_controller.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/machines/runtime_connection.hpp"
#include "ui/foundation/machines/window_identity.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/process/launch_arguments.hpp"
#include "window_display.hpp"
#include <QByteArray>
#include <QByteArrayView>
#include <QDir>
#include <QString>
#include <QStringList>
#include <QtCore/qobject.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string_view>

import telar.config.client;
import telar.gui.application;

namespace telar::gui::qt {

  namespace {

    application::machines::MachineFields profileFields(const application::machines::MachineProfile& profile) {
      return {.id = profile.identity(), .label = profile.label(), .destination = profile.destination(), .color = profile.color(), .enabled = profile.enabled(), .program = profile.program()};
    }

    std::string_view bytes(QByteArrayView text) {
      return {text.data(), static_cast<std::size_t>(text.size())};
    }

  }

  MachineRoster::MachineRoster(Store& store, MachinesCoordinator& machines, MachineProfilesSource& profiles, WindowDisplay& display, Dialogs& dialogs, NotificationsController& notifications, QByteArray hostname, QObject* parent)
      : QObject(parent),
        store_(store),
        machines_(machines),
        profiles_(profiles),
        display_(display),
        dialogs_(dialogs),
        notifications_(notifications),
        hostname_(std::move(hostname)) {
    observeProfiles();
  }

  void MachineRoster::observeProfiles() {
    retry_.setSingleShot(true);
    constexpr int profile_retry_ms = 1000;

    retry_.setInterval(profile_retry_ms);
    connect(&profiles_, &MachineProfilesSource::changed, this, &MachineRoster::applyProfiles);
    connect(&retry_, &QTimer::timeout, this, &MachineRoster::applyProfiles);
    connect(&profiles_, &MachineProfilesSource::failed, this, [this] {
      const auto detail = profiles_.error().toUtf8();
      const auto* const title = profiles_.editError() ? "Machine not saved" : "machines.json not applied";

      notifications_.publish({.level = NotificationLevel::failure, .title = title, .message = bytes(detail), .link = {}});
      if (remote_launch_) {
        applyProfiles();
      }
    });
  }

  void MachineRoster::openProfiles(const QString& path) {
    if (!machines_.clientAt(application::machines::Machines::local_slot).identity_lease) {
      throw std::logic_error{"Open the local machine before loading profiles"};
    }

    const platform::ProcessEnvironment environment;

    try {
      const auto runtime = application::machines::MachineRuntimeLocation::resolve(environment, system::currentUserId());

      control_endpoint_ = toQString(runtime.endpoint());
      prepare_directory_ = runtime.managedDirectory().has_value();
    } catch (const application::machines::MachineFailure&) {
      control_endpoint_.clear();
      prepare_directory_ = false;
    }

    profiles_.open(path, QString::fromUtf8(hostname_));
  }

  void MachineRoster::applyProfiles() {
    if (!profiles_.loaded() && (!remote_launch_ || profiles_.error().isEmpty())) {
      return;
    }

    try {
      if (profiles_.loaded()) {
        reconcileMachines();
      }

      try {
        openRequestedMachine();
      } catch (const application::machines::MachineFailure& failure) {
        remote_launch_.reset();
        emit launchFailed(QString::fromUtf8(failure.what()));
      }

      retry_.stop();
      machines_.publishList();
    } catch (const std::exception& error) {
      notifications_.publish({.level = NotificationLevel::failure, .title = "machines.json not applied", .message = error.what(), .link = {}});
      retry_.start();
    }
  }

  void MachineRoster::reconcileMachines() {
    // A copy: reconciling mutates the application that owns the profiles, which are few and bounded.
    const auto profiles = profiles_.profiles();
    const auto hostname = bytes(hostname_);
    const auto local_label = profiles.localLabel().value_or(hostname);
    if (store_.machines().row(application::machines::Machines::local_slot).label.view() != local_label) {
      store_.machines().update(application::machines::Machines::local_slot, {.label = local_label, .destination = {}});
    }

    for (std::size_t index = 1; index < application::machines::Machines::capacity; ++index) {
      const auto slot = static_cast<application::machines::Machines::Slot>(index);
      const auto& row = store_.machines().row(slot);
      const auto profile_exists = std::ranges::any_of(profiles.rows(), [&row](const application::machines::MachineProfile& profile) {
        return profile.identity() == row.id;
      });
      if (row.used && row.id.value() != 0 && !profile_exists) {
        retire(slot, Retirement::removed);
        store_.clients()[slot].reset();
        store_.machines().setLive(slot, false);
        store_.machines().remove(slot);
      }
    }

    for (const auto& profile : profiles.rows()) {
      reconcileMachine(profile);
    }
  }

  void MachineRoster::reconcileMachine(const application::machines::MachineProfile& profile) {
    auto fields = profileFields(profile);
    auto slot = store_.machines().find(profile.identity());
    if (!slot) {
      const auto temporary = store_.machines().findDestination(profile.destination());
      if (temporary && *temporary != application::machines::Machines::local_slot && store_.machines().row(*temporary).id.value() == 0) {
        slot = temporary;
      }
    }

    if (!slot) {
      const auto added = store_.machines().add(fields);

      if (fields.enabled) {
        admit(added);
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
        retire(*slot, Retirement::disabled);
      }

      return;
    }

    const auto& client = store_.clients()[*slot];
    const auto admitted = client && (*client)->key.machine == store_.machines().token(*slot) && (*client)->admitted_program.view() == fields.program.value_or("");
    if (!was_enabled || moved || !admitted) {
      admit(*slot);
    }
  }

  void MachineRoster::admit(application::machines::Machines::Slot slot) {
    {
      auto& created = machines_.createClient(slot);

      created.identity = WindowIdentity::remote(machines_.clientAt(application::machines::Machines::local_slot).identity, store_.machines().row(slot).destination.view());
      created.session.setRestoreLayout(restore_layout_);
    }

    display_.layoutWorkbench();
    auto& client = machines_.clientAt(slot);
    const auto& row = store_.machines().row(slot);

    client.connection.openRemote({.destination = toQString(row.destination.view()), .program = toQString(row.program.view()), .local_endpoint = control_endpoint_, .prepare_directory = prepare_directory_});
    machines_.summarize(client.key);
  }

  void MachineRoster::retire(application::machines::Machines::Slot slot, Retirement reason) {
    if (slot == store_.machines().active()) {
      const auto label = toQString(store_.machines().row(slot).label.view());

      machines_.select(store_.machines().token(application::machines::Machines::local_slot));
      const auto state = reason == Retirement::disabled ? QStringLiteral("disabled") : QStringLiteral("removed");
      const auto local = toQString(store_.machines().row(application::machines::Machines::local_slot).label.view());
      const auto detail = (label + QStringLiteral(" was ") + state + QStringLiteral("; the window shows ") + local).toUtf8();

      notifications_.publish({.title = "Machine left the window", .message = bytes(detail), .link = {}});
    }

    if (const auto& client = store_.clients()[slot]) {
      (*client)->connection.close();
      (*client)->session.disconnected();
      static_cast<void>((*client)->session.settlePresentation());
      (*client)->phase = application::machines::MachinePhase::stopped;
      (*client)->needs_setup = false;
      machines_.summarize((*client)->key);
    }
  }

  void MachineRoster::choose(application::machines::MachinePickerTarget target, bool alternate) {
    const auto intent = application::machines::MachinePicker::choose(store_.machines(), target.machine, alternate);
    if (intent == application::machines::MachinePicker::Intent::add) {
      dialogs_.showMachinePrompt();

      return;
    }

    dialogs_.show(Store::Dialog::none);
    if (intent == application::machines::MachinePicker::Intent::none || !target.machine) {
      return;
    }

    const auto token = *target.machine;

    if (intent == application::machines::MachinePicker::Intent::setup) {
      setup(token);
    } else if (intent == application::machines::MachinePicker::Intent::enable || intent == application::machines::MachinePicker::Intent::disable) {
      if (intent == application::machines::MachinePicker::Intent::disable) {
        store_.machines().unpin(token.slot);
      }

      const auto label = store_.machines().row(token.slot).label.view();

      static_cast<void>(profiles_.edit({.kind = intent == application::machines::MachinePicker::Intent::enable ? application::machines::MachineEditKind::enable : application::machines::MachineEditKind::disable, .label = label, .value = {}}));
    } else if (store_.clients()[token.slot]) {
      auto& client = machines_.clientAt(token.slot);
      if (!client.connection.ready()) {
        client.phase = application::machines::MachinePhase::connecting;
        client.needs_setup = false;
        client.connection.retryNow();
        machines_.summarize(client.key);
      }

      machines_.select(token);
    }
  }

  void MachineRoster::setup(application::machines::MachineToken target) {
    if (!store_.machines().contains(target) || target.slot == application::machines::Machines::local_slot) {
      return;
    }

    const auto& row = store_.machines().row(target.slot);
    const auto program = system::runtime_endpoint::program();
    constexpr std::string_view title_prefix = "Set up ";
    BoundedText<title_prefix.size() + application::machines::MachineLimits::label_bytes> title;

    title.append(title_prefix);
    title.append(row.label.view());
    const auto name = row.id.value() == 0 ? row.destination.view() : row.label.view();
    const std::array<std::string_view, 5> arguments{program, "machine", "setup", name, "--confirm"};
    runtime::config::CommandTabView command{.count = arguments.size(), .configured_label = title.view()};

    std::ranges::copy(arguments, command.arguments.begin());
    machines_.select(store_.machines().token(application::machines::Machines::local_slot));
    static_cast<void>(store_.session().createCommandTab(command));
  }

  void MachineRoster::configureRemoteLaunch(const QString& destination, const QStringList& arguments) {
    if (machines_.clientAt(application::machines::Machines::local_slot).identity_lease) {
      throw std::logic_error{"Configure the initial machine before opening the local connection"};
    }

    const auto encoded = destination.toUtf8();

    application::machines::MachineFieldRules::profileDestination({encoded.constData(), static_cast<std::size_t>(encoded.size())});
    if (!arguments.isEmpty()) {
      const LaunchArguments prepared{arguments};

      BodySchema<Launch>::validate({.cwd = "/", .arguments = prepared.argv()});
    }

    remote_launch_ = RemoteLaunch{.destination = destination, .arguments = arguments};
  }

  void MachineRoster::openRequestedMachine() {
    if (!remote_launch_) {
      return;
    }

    const auto request = *remote_launch_;
    const auto destination = request.destination.toUtf8();
    const std::string_view name{destination.constData(), static_cast<std::size_t>(destination.size())};
    const auto slot = application::machines::MachineOpening::admitted(store_.machines(), name).value_or(application::machines::Machines::local_slot);
    const auto opened = slot == application::machines::Machines::local_slot ? store_.machines().add({.label = name, .destination = name}) : slot;
    if (!store_.machines().row(opened).pinned) {
      store_.machines().pin(opened);
    }

    if (!store_.clients()[opened] || machines_.clientAt(opened).phase == application::machines::MachinePhase::stopped) {
      admit(opened);
    }

    auto& client = machines_.clientAt(opened);

    if (!request.arguments.isEmpty()) {
      const LaunchArguments prepared{request.arguments};

      client.session.setLaunchArguments(prepared.argv());
      client.named_launch = true;
    }

    machines_.select(store_.machines().token(opened));
    remote_launch_.reset();
  }

  void MachineRoster::configureLaunch(const QString& directory, const QStringList& arguments, bool restore) {
    const auto cwd = QDir{directory.isEmpty() ? QDir::currentPath() : directory}.absolutePath().toUtf8();
    const system::login_shell::Command shell;
    const LaunchArguments prepared{arguments};
    const auto command = arguments.isEmpty() ? shell.arguments() : prepared.argv();

    store_.session().setLaunch(Launch{.cwd = {cwd.constData(), static_cast<std::size_t>(cwd.size())}, .arguments = command});
    restore_layout_ = restore;
    store_.session().setRestoreLayout(restore);
  }

}
