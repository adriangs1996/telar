#pragma once

#include "telar_config/callback_context.hpp"
#include <cstdint>
#include <lua.h>

namespace telar::runtime::config {

class CallbackInvocation {
public:
  explicit CallbackInvocation(int reference, BindingContext context)
      : reference_(reference),
        context_(context) {}

  static int invoke(lua_State *state) {
    const auto &invocation = *static_cast<CallbackInvocation *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.reference_);
    invocation.pushContext(state);
    lua_call(state, 1, 1);

    return 1;
  }

private:
  static void integer(lua_State *state, const char *name, std::uint64_t value) {
    lua_pushinteger(state, static_cast<lua_Integer>(value));
    lua_setfield(state, -2, name);
  }

  static int immutable(lua_State *state) {
    lua_pushliteral(state, "callback context is immutable");

    return lua_error(state);
  }

  void pushContext(lua_State *state) const {
    lua_newtable(state);
    lua_pushboolean(state, static_cast<int>(context_.sidebar_visible));
    lua_setfield(state, -2, "sidebar_visible");
    integer(state, "tab_count", context_.tab_count);
    integer(state, "active_tab_index", static_cast<std::uint32_t>(context_.active_tab_index) + 1);
    integer(state, "pane_count", context_.pane_count);
    integer(state, "focused_pane_id", context_.focused_pane_id);

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

  int reference_;
  BindingContext context_;
};

}
