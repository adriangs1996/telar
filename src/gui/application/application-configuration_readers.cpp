module telar.gui.application;

import std;

import telar.lua;
import telar.plugins;
import telar.config.client;
import telar.config.core;
import telar.gui.foundation.actions;
import telar.gui.config.plugin_query;

namespace telar::gui::application {

  ExtendedActionDescription ActionDescriptionReader::read(const runtime::lua::Value& value, const runtime::config::ClientDefinitions& definitions) {
    return std::visit(
        [](const auto& setting) {
          return description(setting);
        },
        runtime::config::ExtendedActionReader::read(value, definitions)
    );
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::NotificationActionSetting& setting) {
    NotificationActionDescription result;

    result.title.assign(setting.title);
    result.message.assign(setting.body);
    result.level = setting.level;
    result.duration_ms = setting.duration_ms;
    result.target = setting.target;

    return result;
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::PluginActionSetting& setting) {
    return PluginActionDescription{.plugin = runtime::plugins::stableId(setting.plugin), .action = runtime::plugins::stableId(setting.action)};
  }

  ExtendedActionDescription ActionDescriptionReader::description(const runtime::config::DefinitionActionSetting& setting) {
    return DefinitionActionDescription{.kind = setting.panel ? DefinitionActionDescription::Kind::panel : DefinitionActionDescription::Kind::pick, .index = setting.index};
  }

  BindingActionReader::BindingActionReader(lua_State& state, const runtime::config::RetainedActionValidator& validator, runtime::config::RetainedCommandTabRegistry& commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  std::optional<BindingAction> BindingActionReader::read(const runtime::lua::Value& value, bool expression) const {
    using Kind = runtime::config::ActionKind;

    const auto setting = validator_.read(value, expression);
    if (!setting) {
      return {};
    }

    switch (setting->kind) {
    case Kind::function:
      return referenced(value, expression ? BindingActionKind::expression : BindingActionKind::callback);
    case Kind::builtin:
      return builtin(value, setting->name);
    case Kind::select_tab:
    case Kind::select_workspace:
      return BindingAction{.kind = setting->kind == Kind::select_tab ? BindingActionKind::select_tab : BindingActionKind::select_workspace, .parameter = setting->number - 1};
    case Kind::select_tab_offset:
      return BindingAction{.kind = BindingActionKind::select_tab_offset, .parameter = setting->number};
    case Kind::command_tab:
      return command(setting->command);
    case Kind::notification:
    case Kind::panel:
    case Kind::pick:
    case Kind::plugin:
      return referenced(value, BindingActionKind::extended);
    }

    return {};
  }

  BindingAction BindingActionReader::command(const runtime::config::CommandTabView& command) const {
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(command.argv(), command.configured_label, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return commandTabAction(*reference, generation_);
  }

  BindingAction BindingActionReader::builtin(const runtime::lua::Value& value, std::string_view name) {
    if (const auto action = builtinBindingAction(name)) {
      return *action;
    }

    value.fail("names an unknown binding action");
  }

  BindingAction BindingActionReader::referenced(const runtime::lua::Value& value, BindingActionKind kind) const {
    value.pushCopy();

    return {.kind = kind, .reference = luaL_ref(&state_, LUA_REGISTRYINDEX), .generation = generation_};
  }

}
