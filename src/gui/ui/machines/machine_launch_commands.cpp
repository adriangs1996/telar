#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include "ui/foundation/process/launch_arguments.hpp"
#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QtCore/qcontainerfwd.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>

import telar.gui.machines.profile_store;
import telar.gui.machines.picker;

namespace telar::gui::qt {

  void ApplicationController::configureRemoteLaunch(const QString& destination, const QStringList& arguments) {
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

  void ApplicationController::openRequestedMachine() {
    if (!remote_launch_) {
      return;
    }

    const auto request = *remote_launch_;
    const auto destination = request.destination.toUtf8();
    const std::string_view name{destination.constData(), static_cast<std::size_t>(destination.size())};
    const auto slot = MachineOpening::admitted(store_.machines(), name).value_or(Machines::local_slot);
    const auto opened = slot == Machines::local_slot ? store_.machines().add({.label = name, .destination = name}) : slot;
    if (!store_.machines().row(opened).pinned) {
      store_.machines().pin(opened);
    }

    if (!store_.clients()[opened] || clientAt(opened).phase == MachinePhase::stopped) {
      admitMachine(opened);
    }

    auto& client = clientAt(opened);

    if (!request.arguments.isEmpty()) {
      const LaunchArguments prepared{request.arguments};

      client.session.setLaunchArguments(prepared.argv());
      client.named_launch = true;
    }

    selectMachine(store_.machines().token(opened));
    remote_launch_.reset();
  }

}
