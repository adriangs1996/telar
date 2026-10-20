#include "lua_value.hpp"
#include <cmath>

namespace lua {
  namespace {
    constexpr int maximum_depth = 16;
  }

  bool readValue(lua_State *state, int index, Value &value, std::exception_ptr &error, int depth) {
    index = index > 0 ? index : lua_gettop(state) + index + 1;
    luaL_checkstack(state, 4, "I/O value is too large");

    if (lua_type(state, index) == LUA_TTABLE) {
      if (depth >= maximum_depth) {
        return luaL_error(state, "I/O tables are nested too deeply"), false;
      }

      try {
        value.data = Value::Object{};
      } catch (...) {
        error = std::current_exception();
        return false;
      }

      lua_pushnil(state);

      while (lua_next(state, index)) {
        if (lua_type(state, -2) != LUA_TSTRING) {
          return luaL_error(state, "I/O option names must be strings"), false;
        }

        std::size_t length = 0;
        const char *key = lua_tolstring(state, -2, &length);
        Value *field = nullptr;

        try {
          field = &std::get<Value::Object>(value.data)[std::string(key, length)];
        } catch (...) {
          error = std::current_exception();
          return false;
        }

        if (!readValue(state, -1, *field, error, depth + 1)) {
          return false;
        }

        lua_pop(state, 1);
      }

      return true;
    }

    const auto type = lua_type(state, index);
    const auto number = lua_tonumber(state, index);

    if (type == LUA_TNUMBER && !std::isfinite(number)) {
      return luaL_error(state, "I/O numbers must be finite"), false;
    }

    std::size_t length = 0;
    const char *bytes = type == LUA_TSTRING ? lua_tolstring(state, index, &length) : nullptr;

    try {
      switch (type) {
      case LUA_TNIL:
        value.data = std::monostate{};
        return true;
      case LUA_TBOOLEAN:
        value.data = static_cast<bool>(lua_toboolean(state, index));
        return true;
      case LUA_TNUMBER:
        value.data = number;
        return true;
      case LUA_TSTRING:
        value.data = std::string(bytes, length);
        return true;
      }
    } catch (...) {
      error = std::current_exception();
      return false;
    }

    return luaL_error(state, "Unsupported I/O value: %s", luaL_typename(state, index)), false;
  }

  void pushValue(lua_State *state, const Value &value) {
    luaL_checkstack(state, 4, "I/O result is too large");

    if (const auto *boolean = std::get_if<bool>(&value.data)) {
      lua_pushboolean(state, *boolean);
    } else if (const auto *number = std::get_if<double>(&value.data)) {
      lua_pushnumber(state, *number);
    } else if (const auto *bytes = std::get_if<std::string>(&value.data)) {
      lua_pushlstring(state, bytes->data(), bytes->size());
    } else if (const auto *array = std::get_if<Value::Array>(&value.data)) {
      lua_createtable(state, static_cast<int>(array->size()), 0);
      int index = 1;

      for (const auto &element : *array) {
        pushValue(state, element);
        lua_rawseti(state, -2, index++);
      }
    } else if (const auto *object = std::get_if<Value::Object>(&value.data)) {
      lua_createtable(state, 0, static_cast<int>(object->size()));

      for (const auto &[key, element] : *object) {
        lua_pushlstring(state, key.data(), key.size());
        pushValue(state, element);
        lua_rawset(state, -3);
      }
    } else {
      lua_pushnil(state);
    }
  }
} // namespace lua
