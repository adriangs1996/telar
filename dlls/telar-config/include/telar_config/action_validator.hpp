#pragma once

#include "telar_base/text/utf8.hpp"
#include "telar_config/client_definitions.hpp"
#include "telar_config/command_tab_registry.hpp"
#include "telar_config/limit_notices.hpp"
#include "telar_config/value_constraints.hpp"

namespace telar::runtime::config {

template <CommandTabStore Commands>
class BasicActionValidator {
public:
  explicit BasicActionValidator(const ClientDefinitions &definitions, LimitNotices &limits, Commands &commands)
      : definitions_(definitions),
        limits_(limits),
        commands_(commands) {}

  bool validate(const lua::Value &action, bool expression = false) const {
    if (action.is(LUA_TFUNCTION)) {
      return true;
    }
    if (expression) {
      action.fail("requires a function for an expression binding");
    }
    if (action.is(LUA_TSTRING)) {
      builtin(action);
      return true;
    }

    const auto kind_value = action.field("kind");
    const auto kind = kind_value.string();
    if (kind == "scroll-pane") {
      direction(action, {"up", "down"});
    } else if (kind == "split-pane") {
      direction(action, {"horizontal", "vertical"});
    } else if (kind == "focus-pane" || kind == "navigate-pane" || kind == "resize-pane") {
      direction(action, {"left", "right", "up", "down"});
    } else if (kind == "resize-sidebar") {
      direction(action, {"left", "right"});
    } else if (kind == "move-tab") {
      direction(action, {"previous", "next"});
    } else if (kind == "select-tab" || kind == "select-workspace") {
      action.onlyFields({"kind", "index"});
      requiredInteger(action.field("index"), 1, 256);
    } else if (kind == "select-tab-offset") {
      action.onlyFields({"kind", "offset"});
      requiredInteger(action.field("offset"), INT8_MIN, INT8_MAX);
    } else if (kind == "command-tab") {
      return commandTab(action);
    } else if (kind == "notification") {
      notification(action);
    } else if (kind == "open-panel") {
      reference(action, "panel", "panels");
    } else if (kind == "pick") {
      reference(action, "pick", "picks");
    } else if (kind == "plugin") {
      action.onlyFields({"kind", "plugin", "action"});
      action.field("plugin").string();
      action.field("action").string();
    } else {
      builtin(kind_value);
      action.onlyFields({"kind"});
    }
    return true;
  }

  bool component(const lua::Value &action) const {
    if (action.is(LUA_TFUNCTION)) {
      action.fail("cannot be a callback in a static component");
    }
    return validate(action);
  }

private:
  static void builtin(const lua::Value &value) {
    constexpr std::string_view names[]{"next-machine", "previous-machine", "machine-picker", "add-machine", "scroll-pane-up", "scroll-pane-down", "split-horizontal", "split-vertical", "focus-left", "focus-right", "focus-up", "focus-down", "navigate-left", "navigate-right", "navigate-up", "navigate-down", "resize-left", "resize-right", "resize-up", "resize-down", "toggle-pane-fullscreen", "toggle-sidebar", "resize-sidebar-left", "resize-sidebar-right", "toggle-workspace-list", "leave-worktree", "forget-gone-worktrees", "new-workspace", "rename-workspace", "close-pane", "new-tab", "next-tab", "previous-tab", "rename-tab", "close-tab", "move-tab-previous", "move-tab-next", "detach", "copy-mode", "goto-picker", "history-palette", "path-picker", "suggest-command", "close-panel", "refresh-panel"};
    const auto name = value.string();
    if (std::ranges::find(names, name) != std::end(names)) {
      return;
    }
    for (const std::string_view prefix : {"select-tab-", "select-workspace-"}) {
      if (name.starts_with(prefix)) {
        const auto number = name.substr(prefix.size());
        if (validIndex(number)) {
          return;
        }
      }
    }
    value.fail("names an unknown action");
  }

  static bool validIndex(std::string_view number) noexcept {
    if (number.empty() || number.front() == '_' || number.back() == '_') {
      return false;
    }

    unsigned index = 0;
    for (const auto byte : number) {
      if (byte == '_') {
        continue;
      }
      if (byte < '0' || byte > '9') {
        return false;
      }
      index = index * 10 + static_cast<unsigned>(byte - '0');
      if (index > UINT8_MAX) {
        return false;
      }
    }
    return index != 0;
  }

  static void requiredInteger(const lua::Value &value, lua_Integer minimum, lua_Integer maximum) {
    const auto integer = value.integer();
    if (integer < minimum || integer > maximum) {
      value.fail("is outside its bounds");
    }
  }

  static void direction(const lua::Value &action, std::initializer_list<std::string_view> choices) {
    action.onlyFields({"kind", "direction"});
    const auto direction = action.field("direction");
    direction.string();
    optionalChoice(direction, choices);
  }

  void reference(const lua::Value &action, const char *field, const char *section) const {
    action.onlyFields({"kind", field});
    const auto value = action.field(field);
    if (!definitions_.contains(section, value.string())) {
      value.fail("names an unknown client definition");
    }
  }

  bool commandTab(const lua::Value &action) const {
    action.onlyFields({"kind", "command", "label"});
    const auto command = action.field("command");
    const auto count = command.listLength();
    constexpr std::size_t maximum_arguments = 32;
    constexpr std::size_t maximum_bytes = 4096;
    if (count == 0) {
      command.fail("requires a command");
    }
    if (count > maximum_arguments) {
      limits_.add({"command_tab.max_arguments", "arguments", maximum_arguments, count, {}});
      return false;
    }

    command.arraySize();
    std::array<std::string_view, maximum_arguments> arguments;
    std::size_t total_bytes = 0;
    for (std::size_t index = 0; index < count; ++index) {
      const auto argument = command.element(index + 1);
      arguments[index] = argument.string();
      if (arguments[index].empty()) {
        argument.fail("must be nonempty");
      }
      total_bytes += arguments[index].size();
    }
    const auto label = action.field("label");
    if (label.is(LUA_TSTRING) && label.string().size() > 32) {
      label.fail("exceeds the label limit");
    }

    std::size_t kept_bytes = 0;
    for (const auto argument : std::span{arguments}.first(count)) {
      if (argument.contains('\0')) {
        command.fail("contains NUL");
      }
      kept_bytes += argument.size();
      if (kept_bytes > maximum_bytes) {
        limits_.add({"command_tab.max_command_bytes", "argv bytes", maximum_bytes, total_bytes, {}});
        return false;
      }
    }
    return commands_.keep(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits_);
  }

  void notification(const lua::Value &action) const {
    action.onlyFields({"kind", "title", "body", "level", "duration_ms", "pane_id", "tab_id", "workspace_id"});
    optionalChoice(action.field("level"), {"info", "success", "warning", "failure"});
    NotificationBody body{.duration_ms = static_cast<std::uint32_t>(action.field("duration_ms").boundedInteger(default_notification_duration_ms, min_notification_duration_ms, max_notification_duration_ms))};
    const auto title = action.field("title");
    const auto message = action.field("body");
    body.title = fitted(title.string(), {"notifications.max_title_bytes", "bytes", max_notification_title_bytes, {}, {}});
    body.message = message.present() ? fitted(message.string(), {"notifications.max_message_bytes", "bytes", max_notification_message_bytes, {}, {}}) : std::string_view{};
    unsigned target_count = 0;
    for (const auto *name : {"pane_id", "tab_id", "workspace_id"}) {
      const auto target = action.field(name);
      if (target.present()) {
        requiredInteger(target, 1, INT64_MAX);
        ++target_count;
      }
    }
    if (target_count > 1) {
      action.fail("accepts only one notification target");
    }
    std::array<Byte, 1024> storage;
    Codec::encode(ShowNotification{.request_id = 1, .notification = body}, storage);
  }

  std::string_view fitted(std::string_view text, LimitReach limit) const {
    if (text.size() > limit.value) {
      limit.requested = text.size();
      limits_.add(limit);
    }
    return utf8Prefix(text, limit.value);
  }

  const ClientDefinitions &definitions_;
  LimitNotices &limits_;
  Commands &commands_;
};

using ActionValidator = BasicActionValidator<CommandTabRegistry>;
using RetainedActionValidator = BasicActionValidator<RetainedCommandTabRegistry>;

}
