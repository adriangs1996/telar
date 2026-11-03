#pragma once

#include "../diagnostics/trace.hpp"
#include "lua_effects.hpp"
#include "lua_exchange.hpp"
#include "lua_traffic.hpp"
#include "plugin_bootstrap.hpp"
#include "protocol.hpp"
#include "telar_base/memory/recycling_allocator.hpp"
#include "telar_config/history/filters.hpp"
#include "telar_lua/json.hpp"
#include "telar_lua/local_modules.hpp"
#include "telar_platform/read_file.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class Host {
public:
  explicit Host(Memory &memory, const char *entry_path, const ServiceSpec *traffic = nullptr)
      : memory_(memory), vm_(memory_, {Limits::lua_bytes, Limits::lua_instructions, Limits::callback_deadline}) {
    std::array<char, PATH_MAX> resolved;
    if (::realpath(entry_path, resolved.data()) == nullptr) {
      throw SystemError{"Resolve tap entrypoint"};
    }

    const std::string_view path{resolved.data()};
    const auto separator = path.rfind('/');
    package_root_.assign(path.substr(0, separator));
    const auto source = readFile(memory_, resolved.data(), Limits::entry_bytes);
    vm_.execute(bootstrap, "@telar-tap-bootstrap.lua");
    lua_setglobal(vm_.state(), "telar");
    if (traffic) { traffic_.emplace(memory_, *traffic); }
    vm_.invoke(&install, this, 0);
    vm_.resetBudget();
    Entrypoint entry{*this, source};
    vm_.invoke(&loadEntrypoint, &entry, 0);
    lua_settop(vm_.state(), 0);
  }

  Host(const Host &) = delete;
  Host &operator=(const Host &) = delete;

  std::span<const Byte> trafficSetup(std::span<Byte> output) {
    if (!traffic_) { throw EncodingError{"Traffic worker is not configured"}; }
    return traffic_->finish(0, output);
  }

  std::span<const Byte> invokeTraffic(const TrafficEvent &event, std::span<Byte> output) {
    if (!traffic_) { throw EncodingError{"Traffic worker is not configured"}; }
    lua_settop(vm_.state(), 0);
    vm_.resetBudget();
    traffic_->begin();
    TrafficInvocation invocation{*this, event};
    try { vm_.invoke(&invokeTrafficCallback, &invocation, 0); }
    catch (const std::exception &) {
      lua_settop(vm_.state(), 0);
      return Protocol::encodeError(output, event.event_id, "unknown Lua error");
    }
    return traffic_->finish(event.event_id, output);
  }

  std::span<const Byte> invoke(const ExchangeView &exchange, std::span<Byte> output) {
    TELAR_TRACE("plugins.invokeExchange");
    auto *state = vm_.state();
    lua_settop(state, 0);
    vm_.resetBudget();
    Invocation invocation{*this, exchange, output};
    try {
      vm_.invoke(&invokeCallback, &invocation, 0);
    } catch (const std::exception &) {
      lua_settop(state, 0);
      // The reference clears the callback stack before producing its error frame.
      return Protocol::encodeError(output, exchange.identity.id, "unknown Lua error");
    }

    if (invocation.encoding_failed) {
      throw EncodingError{"Tap effects exceed the reply limit"};
    }
    return output.first(invocation.encoded_bytes);
  }

private:
  struct Entrypoint {
    Host &host;
    std::string_view source;
  };

  struct TrafficInvocation {
    Host &host;
    const TrafficEvent &event;
  };

  static int invokeTrafficCallback(lua_State *state) {
    auto &invocation = *static_cast<TrafficInvocation *>(lua_touserdata(state, 1));
    std::array<char, 1024> error{};
    try { invocation.host.traffic_->invoke(state, invocation.event); return 0; }
    catch (const std::exception &failure) { std::snprintf(error.data(), error.size(), "%s", failure.what()); }
    return luaL_error(state, "%s", error.data());
  }

  struct Invocation {
    Host &host;
    const ExchangeView &exchange;
    std::span<Byte> output;
    std::size_t encoded_bytes = 0;
    bool encoding_failed = false;
  };

  static Host &context(lua_State *state) noexcept {
    return *static_cast<Host *>(lua_touserdata(state, 1));
  }

  static std::string_view errorMessage(lua_State *state) {
    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, -1, &size);
    return bytes == nullptr ? std::string_view{"unknown Lua error"} : std::string_view{bytes, size};
  }

  static int install(lua_State *state) {
    auto &host = context(state);
    try {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "redact");
      lua_pushcfunction(state, &redactSecrets);
      lua_setfield(state, -2, "secrets");
      lua_pop(state, 1);
      lua::JsonDecoder<SensitiveMemory>::install(state, host.memory_);
      host.modules_.emplace(state, host.package_root_.view());
      if (host.traffic_) { host.traffic_->install(state); }
      return 0;
    } catch (const std::exception &error) {
      return luaL_error(state, "%s", error.what());
    }
  }

  static int loadEntrypoint(lua_State *state) {
    auto &entry = *static_cast<Entrypoint *>(lua_touserdata(state, 1));
    if (luaL_loadbufferx(state, entry.source.data(), entry.source.size(), "@tap-plugin.lua", "t") != LUA_OK) {
      return lua_error(state);
    }
    lua_call(state, 0, 1);
    if (!lua_istable(state, -1)) {
      return luaL_error(state, "Invalid tap plugin");
    }

    lua_getfield(state, -1, "on_exchange");
    if (!lua_isfunction(state, -1)) {
      if (lua_isnil(state, -1) && entry.host.traffic_ && entry.host.traffic_->listening()) { lua_pop(state, 1); return 0; }
      return luaL_error(state, "Missing exchange handler");
    }
    entry.host.callback_reference_ = luaL_ref(state, LUA_REGISTRYINDEX);
    return 0;
  }

  static int invokeCallback(lua_State *state) {
    auto &invocation = *static_cast<Invocation *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.host.callback_reference_);
    LuaExchange::push(state, invocation.exchange);
    lua_call(state, 1, 1);
    try {
      LuaEffects reader{state};
      const auto effects = reader.read(-1);
      invocation.encoded_bytes = Protocol::encodeEffects(invocation.output, invocation.exchange.identity.id, effects).size();
      return 0;
    } catch (const EncodingError &) {
      invocation.encoding_failed = true;
      return 0;
    } catch (const std::exception &) {
      const auto message = errorMessage(state);
      lua_pushlstring(state, message.data(), message.size());
      return lua_error(state);
    }
  }

  static int redactSecrets(lua_State *state) {
    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, 1, &size);
    if (bytes == nullptr) {
      lua_pushliteral(state, "redact.secrets expects a string");
      return lua_error(state);
    }

    const std::string_view input{bytes, size};
    const auto output = HistoryFilters::looksLikeSecret(input) ? std::string_view{"[REDACTED]"} : input;
    lua_pushlstring(state, output.data(), output.size());
    return 1;
  }

  using SensitiveMemory = RecyclingAllocator<Memory>;
  SensitiveMemory memory_;
  lua::Vm<SensitiveMemory> vm_;
  FixedText<PATH_MAX> package_root_;
  std::optional<lua::LocalModules<lua::ModuleDomain::package>> modules_;
  int callback_reference_ = LUA_NOREF;
  std::optional<LuaTraffic<SensitiveMemory>> traffic_;
};

template <Allocator Memory>
Host(Memory &memory, const char *entry_path) -> Host<Memory>;

}
