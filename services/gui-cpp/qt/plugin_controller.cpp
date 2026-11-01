#include "application.hpp"
#include "application/notification_item.hpp"
#include "config/action_descriptions.hpp"
#include "config/plugin_effects.hpp"
#include "config/plugin_invocation.hpp"
#include "input/action.hpp"
#include "machine_client.hpp"
#include "plugin_worker.hpp"
#include "runtime_endpoint.hpp"
#include <QString>
#include <QtCore/qtmetamacros.h>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <variant>

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
    plugin_worker_.start(invocation, execution, QString::fromStdString(runtime_endpoint::program()));
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
