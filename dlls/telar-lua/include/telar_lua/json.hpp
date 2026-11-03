#pragma once

#include "telar_base/text/json.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_lua/vm.hpp"

namespace telar::runtime::lua {

template <Allocator Memory>
class JsonDecoder {
public:
  static void install(lua_State *state, Memory &memory) {
    lua_createtable(state, 0, 1);
    lua_pushlightuserdata(state, &memory);
    lua_pushcclosure(state, &decode, 1);
    lua_setfield(state, -2, "decode");
    lua_setfield(state, -2, "json");
  }

private:
  explicit JsonDecoder(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  static int decode(lua_State *state) {
    if (lua_type(state, 1) != LUA_TSTRING) {
      return luaL_error(state, "json.decode expects a string");
    }

    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, 1, &size);
    if (size > maximum_input_bytes) {
      return luaL_error(state, "JSON input is too large");
    }

    try {
      const std::string_view input{bytes, size};
      validateUtf8(input);
      const auto document = JsonValue::parse(input, maximum_depth - 1);
      auto &memory = *static_cast<Memory *>(lua_touserdata(state, lua_upvalueindex(1)));
      JsonDecoder decoder{memory};
      decoder.push(state, document, 0);
      return 1;
    } catch (const std::exception &error) {
      return luaL_error(state, "%s", error.what());
    }
  }

  void push(lua_State *state, const JsonValue &value, unsigned depth) {
    if (depth == maximum_depth || !lua_checkstack(state, 6)) {
      throw Error{"JSON exceeds the depth limit"};
    }

    switch (value.encoded().front()) {
    case 'n':
      lua_pushnil(state);
      break;
    case 't':
    case 'f':
      lua_pushboolean(state, value.boolean());
      break;
    case '"':
      value.string(text_);
      lua_pushlstring(state, text_.data(), text_.size());
      break;
    case '[': {
      int count = 0;
      value.eachElement([&](const JsonValue &) { ++count; });
      lua_createtable(state, count, 0);
      const auto table = lua_absindex(state, -1);
      lua_Integer index = 0;
      value.eachElement([&](const JsonValue &element) {
        push(state, element, depth + 1);
        lua_rawseti(state, table, ++index);
      });
      break;
    }
    case '{':
      object(state, value, depth);
      break;
    default:
      text_ = value.encoded();
      if (lua_stringtonumber(state, text_.c_str()) != text_.size() + 1) {
        throw Error{"JSON number is outside its bounds"};
      }
    }
  }

  void object(lua_State *state, const JsonValue &value, unsigned depth) {
    int count = 0;
    value.eachMember([&](const JsonValue &, const JsonValue &) { ++count; });
    lua_createtable(state, 0, count);
    const auto table = lua_absindex(state, -1);
    lua_newtable(state);
    const auto names = lua_absindex(state, -1);
    value.eachMember([&](const JsonValue &key, const JsonValue &member) {
      key.string(text_);
      lua_pushlstring(state, text_.data(), text_.size());
      lua_pushvalue(state, -1);
      lua_rawget(state, names);
      if (!lua_isnil(state, -1)) {
        throw Error{"JSON object contains a duplicate key"};
      }

      lua_pop(state, 1);
      lua_pushvalue(state, -1);
      lua_pushboolean(state, true);
      lua_rawset(state, names);
      push(state, member, depth + 1);
      lua_rawset(state, table);
    });
    lua_pop(state, 1);
  }

  static constexpr std::size_t maximum_input_bytes = 1024 * 1024;
  static constexpr unsigned maximum_depth = 64;
  String<Memory> text_;
};

}
