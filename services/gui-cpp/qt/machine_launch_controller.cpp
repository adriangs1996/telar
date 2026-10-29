#include "application.hpp"
#include "launch_arguments.hpp"
#include "machine_client.hpp"
#include "machines/field_rules.hpp"
#include "machines/machines.hpp"
#include "machines/machine_row.hpp"
#include "machines/opening.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QtCore/qcontainerfwd.h>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui::qt {

void Application::configureRemoteLaunch(const QString &destination, const QStringList &arguments) {
  if (clientAt(Machines::local_slot).identity_lease) {
    throw std::logic_error{"Configure the initial machine before opening the local connection"};
  }

  const auto encoded = destination.toUtf8();
  MachineFieldRules::profileDestination({encoded.constData(), static_cast<std::size_t>(encoded.size())});
  if (!arguments.isEmpty()) {
    const LaunchArguments prepared{arguments};
    BodySchema<Launch>::validate({.cwd = "/", .arguments = prepared.argv()});
  }

  remote_launch_ = RemoteLaunch{.destination = destination, .arguments = arguments};
}

void Application::openRequestedMachine() {
  if (!remote_launch_) {
    return;
  }

  const auto request = *remote_launch_;
  const auto destination = request.destination.toUtf8();
  const std::string_view name{destination.constData(), static_cast<std::size_t>(destination.size())};
  const auto slot = MachineOpening::admitted(machines_, name).value_or(Machines::local_slot);
  const auto opened = slot == Machines::local_slot ? machines_.add({.label = name, .destination = name}) : slot;
  if (!machines_.row(opened).pinned) {
    machines_.pin(opened);
  }

  if (!clients_[opened] || clientAt(opened).phase == MachinePhase::stopped) {
    admitMachine(opened);
  }

  auto &client = clientAt(opened);
  if (!request.arguments.isEmpty()) {
    const LaunchArguments prepared{request.arguments};
    client.session.setLaunchArguments(prepared.argv());
    client.named_launch = true;
  }

  selectMachine(machines_.token(opened));
  remote_launch_.reset();
}

}
