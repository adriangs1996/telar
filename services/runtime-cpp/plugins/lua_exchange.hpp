#pragma once

#include "../lua/api.hpp"
#include "exchange_view.hpp"
#include <bit>
#include <charconv>
#include <array>

namespace telar::runtime::plugins {

class LuaExchange {
public:
  static void push(lua_State *state, const ExchangeView &exchange, bool traffic = false) {
    if (!exchange.request && !exchange.response) {
      luaL_error(state, "exchange has no captured half");
    }

    const auto &final_half = exchange.response ? *exchange.response : *exchange.request;
    lua_createtable(state, 0, 13);
    if (traffic) { setIdentity(state, "id", exchange.identity.id); }
    else { setInteger(state, "id", std::bit_cast<std::int64_t>(exchange.identity.id)); }
    setString(state, "host", exchange.host);
    setString(state, "protocol", protocolName(exchange.protocol));
    if (traffic) { setIdentity(state, "connection_id", exchange.key.connection); }
    else { setInteger(state, "connection_id", std::bit_cast<std::int64_t>(exchange.key.connection)); }
    setInteger(state, "stream_id", exchange.key.stream);
    setString(state, "method", exchange.method);
    setString(state, "target", exchange.target);
    setInteger(state, "status", exchange.response ? exchange.response->status_code : 0);
    setString(state, "outcome", outcomeName(final_half.outcome));
    setInteger(state, "started_at_ms", exchange.started_at_ms);
    setInteger(state, "finished_at_ms", final_half.finished_at_ms);
    pushHalf(state, exchange.request, traffic);
    lua_setfield(state, -2, "request");
    pushHalf(state, exchange.response, traffic);
    lua_setfield(state, -2, "response");
    freeze(state);
  }

private:
  static void setIdentity(lua_State *state, const char *name, std::uint64_t value) {
    std::array<char, 32> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value);
    setString(state, name, {text.data(), result.ptr});
  }

  static std::string_view protocolName(ExchangeProtocol protocol) noexcept {
    switch (protocol) {
    case ExchangeProtocol::http11:
      return "http11";
    case ExchangeProtocol::h2:
      return "h2";
    case ExchangeProtocol::upgraded:
      return "upgraded";
    }
    return "";
  }

  static std::string_view outcomeName(CaptureOutcome outcome) noexcept {
    switch (outcome) {
    case CaptureOutcome::finished:
      return "finished";
    case CaptureOutcome::failed:
      return "failed";
    case CaptureOutcome::reset:
      return "reset";
    }
    return "";
  }

  static void setString(lua_State *state, const char *name, std::string_view text) {
    lua_pushlstring(state, text.data(), text.size());
    lua_setfield(state, -2, name);
  }

  static void setInteger(lua_State *state, const char *name, std::int64_t value) {
    lua_pushinteger(state, value);
    lua_setfield(state, -2, name);
  }

  static void setBoolean(lua_State *state, const char *name, bool value) {
    lua_pushboolean(state, value);
    lua_setfield(state, -2, name);
  }

  static void pushHalf(lua_State *state, const std::optional<HalfView> &half, bool traffic) {
    if (!half) {
      lua_pushnil(state);
      return;
    }

    lua_createtable(state, 0, 5);
    pushHead(state, half->head, traffic);
    lua_setfield(state, -2, "head");
    setString(state, "body", {reinterpret_cast<const char *>(half->body.data()), half->body.size()});
    setBoolean(state, "body_truncated", half->body_truncated);
    setString(state, "body_encoding", half->encoding);
    setBoolean(state, "body_decoded", half->decoded);
    if (traffic) {
      setBoolean(state, "head_truncated", half->head_truncated);
      setInteger(state, "status", half->status_code);
      setString(state, "outcome", outcomeName(half->outcome));
      setInteger(state, "finished_at_ms", half->finished_at_ms);
    }
    freeze(state);
  }

  static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }
    return text.substr(first, text.find_last_not_of(" \t") - first + 1);
  }

  static void pushHead(lua_State *state, std::span<const std::uint8_t> bytes, bool traffic) {
    std::string_view remaining{reinterpret_cast<const char *>(bytes.data()), bytes.size()};
    lua_createtable(state, 0, 2);
    setString(state, "raw", remaining);
    lua_createtable(state, 0, 0);
    lua_Integer index = 1;
    while (!remaining.empty()) {
      const auto end = remaining.find("\r\n");
      const auto line = remaining.substr(0, end);
      const auto colon = line.find(':', line.starts_with(':') && line.size() > 1 ? 1 : 0);
      if (colon != std::string_view::npos) {
        lua_createtable(state, 0, 2);
        setString(state, "name", traffic ? line.substr(0, colon) : trim(line.substr(0, colon)));
        auto value = line.substr(colon + 1);
        if (traffic) {
          const auto first = value.find_first_not_of(" \t");
          value = first == std::string_view::npos ? std::string_view{} : value.substr(first);
        } else { value = trim(value); }
        setString(state, "value", value);
        freeze(state);
        lua_seti(state, -2, index++);
      }
      if (end == std::string_view::npos) {
        break;
      }

      remaining.remove_prefix(end + 2);
    }
    freeze(state);
    lua_setfield(state, -2, "fields");
    freeze(state);
  }

  static void freeze(lua_State *state) {
    lua_createtable(state, 0, 0);
    lua_createtable(state, 0, 3);
    lua_pushvalue(state, -3);
    lua_setfield(state, -2, "__index");
    lua_pushcfunction(state, &rejectMutation);
    lua_setfield(state, -2, "__newindex");
    lua_pushboolean(state, false);
    lua_setfield(state, -2, "__metatable");
    lua_setmetatable(state, -2);
    lua_remove(state, -2);
  }

  static int rejectMutation(lua_State *state) {
    lua_pushliteral(state, "exchange is immutable");
    return lua_error(state);
  }
};

}
