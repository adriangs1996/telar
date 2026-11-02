#pragma once

#include "config/callback.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include <lua.h>
#include <optional>
#include <string_view>

namespace telar::gui::components {

struct Time {
  std::int64_t unix_seconds = 0;
  std::uint16_t year = 0;
  std::uint8_t month = 0;
  std::uint8_t day = 0;
  std::uint8_t hour = 0;
  std::uint8_t minute = 0;
  std::uint8_t second = 0;
  std::uint8_t weekday = 0;
};

struct Context {
  BindingContext client;
  Time time;
  std::optional<SystemMetrics> metrics = std::nullopt;
  std::optional<std::string_view> output = std::nullopt;
  std::string_view pane_title;
};

class Invocation {
public:
  explicit Invocation(int reference, const Context &context, const char *field = "render") noexcept
      : reference_(reference),
        context_(context),
        field_(field) {}

  static int invoke(lua_State *state) {
    const auto &invocation = *static_cast<const Invocation *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    lua_getfield(state, -1, invocation.field_);
    lua_remove(state, -2);
    invocation.pushContext(state);
    lua_call(state, 1, 1);

    return 1;
  }

private:
  static void integer(lua_State *state, const char *name, std::int64_t value) {
    lua_pushinteger(state, static_cast<lua_Integer>(value));
    lua_setfield(state, -2, name);
  }

  static void boolean(lua_State *state, const char *name, bool value) {
    lua_pushboolean(state, static_cast<int>(value));
    lua_setfield(state, -2, name);
  }

  static void text(lua_State *state, const char *name, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, name);
  }

  static int immutable(lua_State *state) {
    lua_pushliteral(state, "callback context is immutable");

    return lua_error(state);
  }

  static void freeze(lua_State *state) {
    lua_newtable(state);
    lua_newtable(state);
    lua_pushvalue(state, -3);
    lua_setfield(state, -2, "__index");
    lua_pushcfunction(state, &immutable);
    lua_setfield(state, -2, "__newindex");
    lua_pushboolean(state, 0);
    lua_setfield(state, -2, "__metatable");
    lua_setmetatable(state, -2);
    lua_remove(state, -2);
  }

  void pushContext(lua_State *state) const {
    lua_newtable(state);
    boolean(state, "sidebar_visible", context_.client.sidebar_visible);
    integer(state, "tab_count", context_.client.tab_count);
    integer(state, "active_tab_index", static_cast<std::int64_t>(context_.client.active_tab_index) + 1);
    integer(state, "pane_count", context_.client.pane_count);
    integer(state, "focused_pane_id", static_cast<std::int64_t>(context_.client.focused_pane_id));

    lua_newtable(state);
    integer(state, "unix_seconds", context_.time.unix_seconds);
    integer(state, "year", context_.time.year);
    integer(state, "month", context_.time.month);
    integer(state, "day", context_.time.day);
    integer(state, "hour", context_.time.hour);
    integer(state, "minute", context_.time.minute);
    integer(state, "second", context_.time.second);
    integer(state, "weekday", context_.time.weekday);
    freeze(state);
    lua_setfield(state, -2, "time");

    lua_newtable(state);
    boolean(state, "available", context_.metrics.has_value());
    if (context_.metrics) {
      integer(state, "cpu_percent", context_.metrics->cpu_percent);
      integer(state, "memory_used_decigib", context_.metrics->memory_used_decigib);
      if (context_.metrics->has_battery) {
        integer(state, "battery_percent", context_.metrics->battery_percent);
      }
    }

    freeze(state);
    lua_setfield(state, -2, "metrics");
    if (context_.output) {
      text(state, "output", *context_.output);
    }

    text(state, "pane_title", context_.pane_title);
    freeze(state);
  }

  int reference_;
  const Context &context_;
  const char *field_;
};

}
