#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "ui/app/application_controller.hpp"
#include <QString>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <array>
#include <bit>
#include <cerrno>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <fcntl.h>
#include <limits.h>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <tuple>
#include <utility>
#include <variant>

import telar.gui.config.plugin_effects;
import telar.gui.input.copy_pointer;
import telar.gui.presentation.notification_center;

namespace telar::gui::qt {

  void ApplicationController::initializePlugins() {
    connect(&plugins_, &PluginRunner::finished, this, [this](const PluginEffects& effects) {
      try {
        error_.clear();
        applyPluginEffects(effects);
        refresh();
      } catch (const std::exception& error) {
        fail(error);
      }
    });
    connect(&plugins_, &PluginRunner::failed, this, &ApplicationController::reportFailure);
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
