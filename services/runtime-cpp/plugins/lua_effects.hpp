#pragma once

#include "effects.hpp"
#include "telar_lua/vm.hpp"

namespace telar::runtime::plugins {

class LuaEffects {
public:
  explicit LuaEffects(lua_State *state) noexcept : state_(state), restored_top_(lua_gettop(state)) {}

  ~LuaEffects() { lua_settop(state_, restored_top_); }

  LuaEffects(const LuaEffects &) = delete;
  LuaEffects &operator=(const LuaEffects &) = delete;

  EffectBatch read(int index) {
    if (lua_isnil(state_, index)) {
      return {};
    }
    if (!lua_istable(state_, index)) {
      throw lua::Error{"Invalid effect batch"};
    }

    const auto absolute = lua_absindex(state_, index);
    const auto count = lua_rawlen(state_, absolute);
    if (count > Limits::effects || !lua_checkstack(state_, static_cast<int>(Limits::effects * fields_per_effect))) {
      throw lua::Error{"Too many effects"};
    }

    EffectBatch batch;
    batch.count = static_cast<Byte>(count);
    for (std::size_t effect = 0; effect < count; ++effect) {
      lua_geti(state_, absolute, static_cast<lua_Integer>(effect + 1));
      if (!lua_istable(state_, -1)) {
        throw lua::Error{"Invalid effect"};
      }

      const auto table = lua_absindex(state_, -1);
      if (string(table, "__telar_kind", true) != "notification") {
        throw lua::Error{"Invalid effect"};
      }

      batch.notifications[effect] = {
          .level = notificationLevel(string(table, "level", false)),
          .duration_ms = static_cast<std::uint32_t>(integer(table, "duration_ms", default_duration_ms)),
          .title = string(table, "title", true),
          .message = string(table, "message", false),
      };
    }
    return batch;
  }

private:
  std::string_view string(int table, const char *field, bool required) {
    lua_getfield(state_, table, field);
    if (!required && lua_isnil(state_, -1)) {
      return {};
    }

    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state_, -1, &size);
    if (bytes == nullptr) {
      throw lua::Error{"Invalid effect"};
    }

    // Numeric fields become temporary Lua strings; keep them rooted until encoding completes.
    return {bytes, size};
  }

  lua_Integer integer(int table, const char *field, lua_Integer fallback) {
    lua_getfield(state_, table, field);
    if (lua_isnil(state_, -1)) {
      return fallback;
    }

    int valid = 0;
    const auto result = lua_tointegerx(state_, -1, &valid);
    if (!valid) {
      throw lua::Error{"Invalid effect"};
    }
    return result;
  }

  static NotificationLevel notificationLevel(std::string_view level) {
    if (level.empty() || level == "info") {
      return NotificationLevel::info;
    }
    if (level == "success") {
      return NotificationLevel::success;
    }
    if (level == "warning") {
      return NotificationLevel::warning;
    }
    if (level == "failure") {
      return NotificationLevel::failure;
    }
    throw lua::Error{"Invalid effect"};
  }

  static constexpr std::size_t fields_per_effect = 6;
  static constexpr std::uint32_t default_duration_ms = 4000;
  lua_State *state_;
  int restored_top_;
};

}
