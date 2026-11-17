#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include <cstdint>
#include <exception>
#include <variant>

import telar.gui.config.plugin_effects;
import telar.gui.presentation.notification_center;

namespace telar::gui::qt {

  void ApplicationController::initializePlugins() {
    connect(&plugins_, &PluginRunner::finished, this, [this](const PluginEffects& effects) {
      try {
        status_.clear();
        applyPluginEffects(effects);
        refresh();
      } catch (const std::exception& error) {
        status_.fail(error);
      }
    });
    connect(&plugins_, &PluginRunner::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::applyPluginEffects(const PluginEffects& effects) {
    for (const auto& effect : effects.effects()) {
      if (const auto* action = std::get_if<BindingAction>(&effect)) {
        executeBinding(*action);
        if (action->kind == BindingActionKind::detach) {
          break;
        }
      } else {
        const auto& notification = std::get<NotificationActionDescription>(effect);

        notifications_.publish({.level = notification.level, .target = notification.target, .title = notification.title.view(), .message = notification.message.view(), .link = {}, .duration_ns = static_cast<std::uint64_t>(notification.duration_ms) * NotificationInput::nanoseconds_per_millisecond});
      }
    }
  }

}
