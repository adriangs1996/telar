#pragma once

#include "vm.hpp"
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <optional>

namespace telar::runtime::lua {

class Value {
public:
  explicit Value(lua_State *state, int index, const char *label)
      : state_(state),
        index_(lua_absindex(state, index)),
        restored_top_(lua_gettop(state)),
        label_(label) {}

  ~Value() {
    lua_settop(state_, restored_top_);
  }

  Value(const Value &) = delete;
  Value &operator=(const Value &) = delete;

  Value field(const char *name) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, name};
  }

  Value element(lua_Integer position) const {
    require(LUA_TTABLE, "must be an array");
    return Value{*this, position};
  }

  Value entry(std::string_view key) const {
    require(LUA_TTABLE, "must be a table");
    return Value{*this, key};
  }

  bool present() const noexcept {
    return lua_type(state_, index_) != LUA_TNIL;
  }

  bool is(int type) const noexcept {
    return lua_type(state_, index_) == type;
  }

  void pushCopy() const {
    lua_pushvalue(state_, index_);
  }

  std::string_view string() const {
    require(LUA_TSTRING, "must be a string");
    std::size_t size = 0;
    const auto *text = lua_tolstring(state_, index_, &size);
    return {text, size};
  }

  bool boolean(bool fallback) const {
    if (!present()) {
      return fallback;
    }

    require(LUA_TBOOLEAN, "must be a boolean");
    return lua_toboolean(state_, index_) != 0;
  }

  lua_Integer integer() const {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);
    if (!valid) {
      fail("must be an integer");
    }

    return result;
  }

  std::optional<lua_Integer> asInteger() const noexcept {
    int valid = 0;
    const auto result = lua_tointegerx(state_, index_, &valid);
    return valid ? std::optional{result} : std::nullopt;
  }

  std::uint64_t boundedInteger(std::uint64_t fallback, std::uint64_t minimum, std::uint64_t maximum) const {
    if (!present()) {
      return fallback;
    }

    const auto result = integer();
    if (result < 0 || static_cast<std::uint64_t>(result) < minimum || static_cast<std::uint64_t>(result) > maximum) {
      fail("is outside its bounds");
    }

    return static_cast<std::uint64_t>(result);
  }

  double boundedNumber(double fallback, double minimum, double maximum) const {
    if (!present()) {
      return fallback;
    }

    require(LUA_TNUMBER, "must be a number");
    const auto result = lua_tonumber(state_, index_);
    if (!std::isfinite(result) || result < minimum || result > maximum) {
      fail("is outside its bounds");
    }

    return result;
  }

  void onlyFields(std::initializer_list<std::string_view> allowed, bool allow_children = false) const {
    require(LUA_TTABLE, "must be a table");
    const auto children = allow_children ? lua_rawlen(state_, index_) : 0;
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      if (children != 0 && lua_isinteger(state_, -2)) {
        const auto position = lua_tointeger(state_, -2);
        if (position < 1 || static_cast<std::uint64_t>(position) > children) {
          fail("children must form an array");
        }
        lua_pop(state_, 1);
        continue;
      }

      {
        const Value key{state_, -2, label_};
        const auto name = key.string();
        if (std::find(allowed.begin(), allowed.end(), name) == allowed.end()) {
          key.fail("contains an unknown field");
        }
      }

      lua_pop(state_, 1);
    }
  }

  std::size_t arraySize() const {
    require(LUA_TTABLE, "must be an array");
    const auto size = lua_rawlen(state_, index_);
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      int valid = 0;
      const auto key = lua_tointegerx(state_, -2, &valid);
      if (!valid || lua_type(state_, -2) != LUA_TNUMBER || key < 1 || static_cast<std::uint64_t>(key) > size) {
        fail("contains a non-array key");
      }

      lua_pop(state_, 1);
    }

    return size;
  }

  std::size_t listLength() const {
    require(LUA_TTABLE, "must be a table");
    return lua_rawlen(state_, index_);
  }

  template <typename Consumer>
  void eachField(Consumer &&consume) const {
    require(LUA_TTABLE, "must be a table");
    lua_pushnil(state_);
    while (lua_next(state_, index_) != 0) {
      {
        const Value key{state_, -2, label_};
        const Value value{state_, -1, label_};
        consume(key.string(), value);
      }
      lua_pop(state_, 1);
    }
  }

  [[noreturn]] void fail(const char *message) const {
    std::array<char, 512> description;
    std::snprintf(description.data(), description.size(), "%s %s", label_, message);
    throw Error{description.data()};
  }

private:
  Value(const Value &parent, std::string_view key)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_pushlstring(state_, key.data(), key.size());
    lua_rawget(state_, parent.index_);
  }

  Value(const Value &parent, const char *name)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(name) {
    lua_getfield(state_, parent.index_, name);
  }

  Value(const Value &parent, lua_Integer position)
      : state_(parent.state_),
        index_(lua_gettop(state_) + 1),
        restored_top_(lua_gettop(state_)),
        label_(parent.label_) {
    lua_rawgeti(state_, parent.index_, position);
  }

  void require(int type, const char *message) const {
    if (lua_type(state_, index_) != type) {
      fail(message);
    }
  }

  lua_State *state_;
  int index_;
  int restored_top_;
  const char *label_;
};

}
