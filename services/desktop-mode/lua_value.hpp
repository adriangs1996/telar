#pragma once

#include "lua_api.hpp"
#include <exception>
#include <map>
#include <string>
#include <variant>
#include <vector>

namespace lua {
  struct Value {
    using Array = std::vector<Value>;
    using Object = std::map<std::string, Value, std::less<>>;
    std::variant<std::monostate, bool, double, std::string, Array, Object> data;
  };

  // Call under a protected Lua frame; owned values must live outside that frame.
  bool
  readValue(lua_State *state, int index, Value &value, std::exception_ptr &error, int depth = 0);
  void pushValue(lua_State *state, const Value &value);
} // namespace lua
