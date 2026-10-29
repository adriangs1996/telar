#pragma once

#include "command_tab_action.hpp"
#include "config/action_validator.hpp"
#include "config/command_tab_registry.hpp"
#include "config/command_tab_view.hpp"
#include "config/limit_notices.hpp"
#include "input/action.hpp"
#include "lua/value.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <lauxlib.h>
#include <limits>
#include <lua.h>
#include <string_view>

namespace telar::gui {

class BindingActionReader {
public:
  explicit BindingActionReader(lua_State &state, const runtime::config::RetainedActionValidator &validator, runtime::config::RetainedCommandTabRegistry &commands, std::uint64_t generation)
      : state_(state),
        validator_(validator),
        commands_(commands),
        generation_(generation) {}

  [[nodiscard]] std::optional<BindingAction> read(const runtime::lua::Value &value, bool expression = false) const {
    if (!validator_.validate(value, expression)) {
      return {};
    }

    if (value.is(LUA_TFUNCTION)) {
      return referenced(value, expression ? BindingActionKind::expression : BindingActionKind::callback);
    }

    if (value.is(LUA_TSTRING)) {
      return builtin(value);
    }

    const auto kind = value.field("kind");
    const auto name = kind.string();
    if (const auto action = builtinBindingAction(name)) {
      return action;
    }

    if (name == "select-tab" || name == "select-workspace") {
      return BindingAction{.kind = name == "select-tab" ? BindingActionKind::select_tab : BindingActionKind::select_workspace, .parameter = static_cast<std::int32_t>(value.field("index").integer() - 1)};
    }

    if (name == "select-tab-offset") {
      return BindingAction{.kind = BindingActionKind::select_tab_offset, .parameter = static_cast<std::int32_t>(value.field("offset").integer())};
    }

    if (name == "command-tab") {
      return command(value);
    }

    if (name == "notification" || name == "open-panel" || name == "pick" || name == "plugin") {
      return referenced(value, BindingActionKind::extended);
    }

    return directional(value, name);
  }

private:
  [[nodiscard]] BindingAction command(const runtime::lua::Value &value) const {
    const auto command = value.field("command");
    const auto count = command.listLength();
    std::array<std::string_view, runtime::config::CommandTabView::maximum_arguments> arguments{};
    if (count == 0 || count > arguments.size()) {
      command.fail("has an invalid number of command arguments");
    }

    for (std::size_t index = 0; index < count; ++index) {
      arguments[index] = command.element(static_cast<lua_Integer>(index) + 1).string();
    }

    const auto label = value.field("label");
    runtime::config::LimitNotices limits;
    const auto reference = commands_.keepReference(std::span{arguments}.first(count), label.is(LUA_TSTRING) ? label.string() : std::string_view{}, limits);
    if (!reference) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return commandTabAction(*reference, generation_);
  }

  static BindingAction builtin(const runtime::lua::Value &value) {
    if (const auto action = builtinBindingAction(value.string())) {
      return *action;
    }

    value.fail("names an unknown binding action");
  }

  static BindingAction directional(const runtime::lua::Value &value, std::string_view name) {
    constexpr auto stems = std::to_array<std::pair<std::string_view, std::string_view>>({
        {"scroll-pane", "scroll-pane-"},
        {"split-pane", "split-"},
        {"focus-pane", "focus-"},
        {"navigate-pane", "navigate-"},
        {"resize-pane", "resize-"},
        {"resize-sidebar", "resize-sidebar-"},
        {"move-tab", "move-tab-"},
    });
    const auto *const found = std::ranges::find(stems, name, &decltype(stems)::value_type::first);
    if (found == stems.end()) {
      value.fail("names an unknown binding action");
    }

    const auto direction = value.field("direction");
    const auto suffix = direction.string();
    constexpr std::size_t name_capacity = 64;
    std::array<char, name_capacity> combined{};
    if (found->second.size() + suffix.size() > combined.size()) {
      direction.fail("names an invalid direction");
    }

    const auto copied = std::ranges::copy(found->second, combined.begin());
    std::ranges::copy(suffix, copied.out);
    const auto action = builtinBindingAction({combined.data(), found->second.size() + suffix.size()});
    if (!action) {
      direction.fail("names an invalid direction");
    }

    return *action;
  }

  [[nodiscard]] BindingAction referenced(const runtime::lua::Value &value, BindingActionKind kind) const {
    value.pushCopy();

    return {.kind = kind, .reference = luaL_ref(&state_, LUA_REGISTRYINDEX), .generation = generation_};
  }

  lua_State &state_;
  const runtime::config::RetainedActionValidator &validator_;
  runtime::config::RetainedCommandTabRegistry &commands_;
  std::uint64_t generation_;
};

}
