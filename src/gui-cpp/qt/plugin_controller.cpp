#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include "../core/memory.hpp"
#include <array>
#include <span>
#include <stdexcept>
#include <tuple>
#include <variant>
#include <optional>
#include <utility>
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_base/memory/allocator.hpp"
#include <exception>
#include <charconv>
#include <limits.h>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <bit>
#include "machine_client.hpp"
#include "plugin_worker.hpp"
#include <string>
#include <QString>
#include <QtCore/qtmetamacros.h>



import telar.gui.application.workspace_replica;
import telar.gui.config.plugin_query;
import telar.gui.config.plugin_effects;
import telar.gui.input.copy_pointer;
import telar.gui.platform.profile_file;

namespace telar::gui::qt {

void Application::startPlugin(const PluginInvocation &invocation) {
  if (plugin_worker_.active() || plugin_owner_) {
    throw std::runtime_error{"PluginWorkerBusy"};
  }

  if (next_plugin_execution_ == 0) {
    throw std::runtime_error{"PluginExecutionIdExhausted"};
  }

  const auto &client = clientAt(machines_.active());
  const auto execution = next_plugin_execution_++;
  plugin_owner_ = PluginOwner{.source = client.key, .runtime_generation = client.runtime_generation, .execution = execution};
  try {
    plugin_worker_.start(invocation, execution, QString::fromStdString(platform::runtime_endpoint::program()));
  } catch (...) {
    plugin_owner_.reset();
    throw;
  }
}

void Application::pluginWorkerFinished(std::uint64_t execution, const PluginInvocation &invocation, const PluginWorkerResult &result) {
  if (!plugin_owner_ || plugin_owner_->execution != execution) {
    return;
  }

  const auto owner = *plugin_owner_;
  plugin_owner_.reset();
  const auto *client = findClient(owner.source);
  if (client == nullptr || client->key.machine.slot != machines_.active() || client->runtime_generation != owner.runtime_generation || !client->connection.ready() || configuration_source_.configurationGeneration() != invocation.configuration_generation) {
    return;
  }

  try {
    if (!result.error.isEmpty()) {
      throw std::runtime_error{result.error.toStdString()};
    }

    if (!result.effects) {
      throw std::runtime_error{"PluginWorkerFailed"};
    }

    configuration_source_.authorizePlugin(invocation, *result.effects);
    error_.clear();
    applyPluginEffects(*result.effects);

    refresh();
    emit stateChanged();
  } catch (const std::exception &error) {
    fail(error);
  }
}

void Application::applyPluginEffects(const PluginEffects &effects) {
  for (const auto &effect : effects.effects()) {
    if (const auto *action = std::get_if<BindingAction>(&effect)) {
      executeBinding(*action);
      if (action->kind == BindingActionKind::detach) {
        break;
      }
    } else {
      const auto &notification = std::get<NotificationActionDescription>(effect);
      publishNotification({.level = notification.level, .target = notification.target, .title = notification.title.view(), .message = notification.message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification.duration_ms) * NotificationInput::nanoseconds_per_millisecond});
    }
  }
}

}
