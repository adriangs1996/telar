#pragma once

#include "action_descriptions.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/client_definitions.hpp"
#include "telar_lua/value.hpp"
#include "telar_plugins/identity.hpp"
#include <array>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

class ActionDescriptionReader {
public:
  static ExtendedActionDescription read(const runtime::lua::Value &value, const runtime::config::ClientDefinitions &definitions) {
    const auto kind = value.field("kind");
    const auto name = kind.string();
    if (name == "notification") {
      return notification(value);
    }

    if (name == "plugin") {
      return PluginActionDescription{.plugin = runtime::plugins::stableId(value.field("plugin").string()), .action = runtime::plugins::stableId(value.field("action").string())};
    }

    const bool panel = name == "open-panel";
    const auto selected = value.field(panel ? "panel" : "pick");
    const auto index = definitions.index(panel ? "panels" : "picks", selected.string());
    if (!index) {
      selected.fail("names an unknown client definition");
    }

    return DefinitionActionDescription{.kind = panel ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = *index};
  }

  static NotificationActionDescription notification(const runtime::lua::Value &value) {
    NotificationActionDescription result;
    result.title.assign(runtime::utf8Prefix(value.field("title").string(), max_notification_title_bytes));
    const auto body = value.field("body");
    if (body.present()) {
      result.message.assign(runtime::utf8Prefix(body.string(), max_notification_message_bytes));
    }

    const auto level = value.field("level");
    if (level.present()) {
      constexpr std::array names{"info", "success", "warning", "failure"};
      for (std::size_t index = 0; index < names.size(); ++index) {
        if (level.string() == names[index]) {
          result.level = static_cast<NotificationLevel>(index);
        }
      }
    }

    result.duration_ms = static_cast<std::uint32_t>(value.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms));
    constexpr std::array targets{"pane_id", "tab_id", "workspace_id"};
    for (std::size_t index = 0; index < targets.size(); ++index) {
      const auto target = value.field(targets[index]);
      if (target.present()) {
        result.target = {.kind = static_cast<NotificationTarget::Kind>(index + 1), .id = static_cast<std::uint64_t>(target.integer())};
      }
    }

    return result;
  }
};

}
