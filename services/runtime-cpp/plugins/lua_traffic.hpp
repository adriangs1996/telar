#pragma once

#include "lua_traffic_value.hpp"
#include "lua_traffic_control.hpp"
#include "lua_effects.hpp"
#include "traffic_api.hpp"
#include "../memory/byte_queue.hpp"
#include "../memory/sensitive_allocation.hpp"

namespace telar::runtime::plugins {

template <Allocator Memory>
class LuaTraffic {
  struct Binding {
    TrafficRegistration registration;
    int callback = LUA_NOREF;
  };
  struct QueuedDecision {
    std::uint32_t registration;
    std::size_t offset;
    std::size_t bytes;
  };
  enum class Operation { subscribe, intercept, decide, cancel, control };

public:
  explicit LuaTraffic(Memory &memory, ServiceSpec specification)
      : specification_(specification), scratch_(memory, HttpMessageLimits::message_bytes + 32), decisions_(memory, 3 * 1024 * 1024), effects_(memory, Limits::effect_bytes), reply_(makeOwned<TrafficReply>(memory)) {}

  void install(lua_State *state) {
    if (luaL_loadbufferx(state, traffic_api.data(), traffic_api.size(), "@telar-traffic-api.lua", "t") != LUA_OK) { lua_error(state); }
    lua_call(state, 0, 1);
    lua_getglobal(state, "telar");
    lua_newtable(state);
    lua_pushvalue(state, -1);
    lua_setfield(state, -3, "traffic");
    lua_remove(state, -2);
    lua_createtable(state, 0, 5);
    constexpr std::array operations{
        std::pair{"traffic_subscribe", Operation::subscribe}, std::pair{"traffic_intercept", Operation::intercept},
        std::pair{"traffic_decide", Operation::decide}, std::pair{"cancel", Operation::cancel}, std::pair{"traffic_control", Operation::control},
    };
    for (const auto &[name, operation] : operations) {
      lua_pushlightuserdata(state, this);
      lua_pushinteger(state, static_cast<int>(operation));
      lua_pushcclosure(state, &call, 2);
      lua_setfield(state, -2, name);
    }
    lua_call(state, 2, 0);
  }

  bool listening() const noexcept {
    return std::ranges::any_of(bindings_, [](const auto &binding) { return binding.callback != LUA_NOREF; });
  }

  void begin() noexcept {
    decisions_.clear();
    decision_count_ = 0;
    effect_bytes_ = 0;
  }

  void invoke(lua_State *state, const TrafficEvent &event) {
    auto *binding = find(event.registration);
    if (!binding) { return; }
    const auto stage = binding->registration.stage;
    lua_rawgeti(state, LUA_REGISTRYINDEX, binding->callback);
    if (stage == TrafficStage::control) {
      luaL_unref(state, LUA_REGISTRYINDEX, binding->callback);
      binding->callback = LUA_NOREF;
      changed_ = true;
      if (!event.error.empty()) { lua_pushlstring(state, event.error.data(), event.error.size()); lua_pushnil(state); }
      else { lua_pushnil(state); LuaTrafficControl::push(state, traffic::control::Protocol::reply(event.control)); }
      lua_call(state, 2, 1);
      LuaEffects reader{state};
      effect_bytes_ = Protocol::encodeEffects(effects_.bytes(), event.event_id, reader.read(-1)).size();
      return;
    }
    lua_pushnil(state);
    LuaTrafficValue::push(state, event.event, event.dropped);
    lua_createtable(state, 0, 3);
    LuaTrafficValue::field(state, "id", specification_.name.view());
    LuaTrafficValue::identity(state, "generation", specification_.generation);
    std::array<char, 64> digest;
    constexpr std::string_view hex = "0123456789abcdef";
    for (std::size_t index = 0; index < specification_.digest.size(); ++index) {
      digest[index * 2] = hex[specification_.digest[index] >> 4];
      digest[index * 2 + 1] = hex[specification_.digest[index] & 15];
    }
    LuaTrafficValue::field(state, "digest", std::string_view{digest.data(), digest.size()});
    lua_setfield(state, -2, "app");
    lua_call(state, 2, 1);
    if (stage == TrafficStage::observe) {
      LuaEffects reader{state};
      effect_bytes_ = Protocol::encodeEffects(effects_.bytes(), event.event_id, reader.read(-1)).size();
    }
  }

  std::span<const Byte> finish(std::uint64_t event_id, std::span<Byte> output) {
    auto &reply = *reply_;
    reply.event_id = event_id;
    reply.changed = changed_;
    reply.registration_count = 0;
    if (changed_) {
      for (const auto &binding : bindings_) {
        if (binding.callback != LUA_NOREF) { reply.registrations[reply.registration_count++] = binding.registration; }
      }
    }
    reply.decision_count = decision_count_;
    for (std::size_t index = 0; index < decision_count_; ++index) {
      const auto &queued = queued_[index];
      reply.decisions[index] = {queued.registration, decisions_.readable().subspan(queued.offset, queued.bytes)};
    }
    reply.effects = effects_.bytes().first(effect_bytes_);
    const auto encoded = TrafficProtocol::reply(output, reply);
    changed_ = false;
    return encoded;
  }

private:
  static int call(lua_State *state) {
    auto &self = *static_cast<LuaTraffic *>(lua_touserdata(state, lua_upvalueindex(1)));
    const auto operation = static_cast<Operation>(lua_tointeger(state, lua_upvalueindex(2)));
    std::array<char, 1024> error{};
    try {
      switch (operation) {
      case Operation::subscribe: lua_pushinteger(state, self.registerCallback(state, false)); return 1;
      case Operation::intercept: lua_pushinteger(state, self.registerCallback(state, true)); return 1;
      case Operation::decide: lua_pushboolean(state, self.decide(state)); return 1;
      case Operation::cancel: {
        const auto id = identifier(state, 1);
        if (auto *binding = self.find(id)) {
          luaL_unref(state, LUA_REGISTRYINDEX, binding->callback);
          binding->callback = LUA_NOREF;
          self.changed_ = true;
        }
        return 0;
      }
      case Operation::control: lua_pushinteger(state, self.registerControl(state)); return 1;
      }
    } catch (const std::exception &failure) { std::snprintf(error.data(), error.size(), "%s", failure.what()); }
    return luaL_error(state, "%s", error.data());
  }

  static std::uint32_t identifier(lua_State *state, int index) {
    const lua::Value value{state, index, "Traffic operation identifier"};
    return static_cast<std::uint32_t>(value.boundedInteger(0, 1, UINT32_MAX));
  }

  Binding *find(std::uint32_t id) noexcept {
    for (auto &binding : bindings_) {
      if (binding.callback != LUA_NOREF && binding.registration.id == id) { return &binding; }
    }
    return nullptr;
  }

  std::uint32_t registerControl(lua_State *state) {
    if (lua_type(state, 2) != LUA_TFUNCTION) { throw lua::Error{"Traffic callback must be a function"}; }
    if (next_identifier_ == UINT32_MAX) { throw lua::Error{"Traffic identifiers exhausted"}; }
    const lua::Value options{state, 1, "Traffic control options"};
    const auto request = LuaTrafficControl::request(options);
    if (!traffic::control::authorized(specification_, request)) { throw lua::Error{"Traffic capability denied"}; }
    const auto active = std::ranges::count_if(bindings_, [](const auto &binding) { return binding.callback != LUA_NOREF && binding.registration.stage == TrafficStage::control; });
    if (static_cast<std::size_t>(active) >= TrafficLimits::controls) { throw lua::Error{"Traffic control request limit reached"}; }
    const auto encoded = traffic::control::Protocol::encode(scratch_.bytes(), request);
    for (auto &binding : bindings_) {
      if (binding.callback != LUA_NOREF) { continue; }
      TrafficRegistration registration;
      registration.stage = TrafficStage::control;
      registration.request.assign({reinterpret_cast<const char *>(encoded.data()), encoded.size()});
      registration.id = ++next_identifier_;
      lua_pushvalue(state, 2);
      const auto reference = luaL_ref(state, LUA_REGISTRYINDEX);
      binding.registration = registration;
      binding.callback = reference;
      changed_ = true;
      return registration.id;
    }
    throw lua::Error{"Traffic registration limit reached"};
  }

  std::uint32_t registerCallback(lua_State *state, bool intercept) {
    if (!specification_.allows(intercept ? Capability::traffic_intercept : Capability::traffic_observe)) { throw lua::Error{"Traffic capability denied"}; }
    if (lua_type(state, 2) != LUA_TFUNCTION) { throw lua::Error{"Traffic callback must be a function"}; }
    if (next_identifier_ == UINT32_MAX) { throw lua::Error{"Traffic identifiers exhausted"}; }
    TrafficRegistration registration;
    const lua::Value options{state, 1, "Traffic options"};
    if (intercept) { interception(options, registration); }
    else { subscription(options, registration); }
    for (auto &binding : bindings_) {
      if (binding.callback != LUA_NOREF) { continue; }
      lua_pushvalue(state, 2);
      const auto reference = luaL_ref(state, LUA_REGISTRYINDEX);
      registration.id = ++next_identifier_;
      binding.registration = registration;
      binding.callback = reference;
      changed_ = true;
      return registration.id;
    }
    throw lua::Error{"Traffic registration limit reached"};
  }

  static void subscription(const lua::Value &options, TrafficRegistration &registration) {
    options.onlyFields({"filter", "events"});
    const auto filter = options.field("filter");
    if (filter.present()) { registration.filter.assign(filter.string()); }
    if (registration.filter.view().size() > traffic::Limits::filter_bytes) { throw lua::Error{"Traffic filter exceeds its limit"}; }
    if (registration.filter.view().contains('\0')) { throw lua::Error{"Traffic filter contains a zero byte"}; }
    registration.selection = LuaTrafficValue::selection(options.field("events"), registration.selection);
  }

  static void interception(const lua::Value &options, TrafficRegistration &registration) {
    options.onlyFields({"host", "stage", "direction", "visibility", "timeout_ms", "failure"});
    registration.host.assign(options.field("host").string());
    if (!ProxyHostname::validPattern(registration.host.view())) { throw lua::Error{"Interception requires a valid host scope"}; }
    const auto stage = options.field("stage");
    const auto stage_name = stage.present() ? stage.string() : std::string_view{"stream"};
    if (stage_name != "stream" && stage_name != "http") { throw lua::Error{"Interception stage must be stream or http"}; }
    registration.stage = stage_name == "http" ? TrafficStage::http : TrafficStage::stream;
    const auto direction = options.field("direction");
    if (direction.present()) {
      const auto name = direction.string();
      if (name != "outbound" && name != "inbound" && name != "both") { throw lua::Error{"Invalid interception direction"}; }
      registration.directions = name == "outbound" ? 1 : name == "inbound" ? 2 : 3;
    }
    const auto visibility = options.field("visibility");
    registration.visibility = registration.stage == TrafficStage::http ? 3 : 2;
    if (visibility.present()) {
      const auto name = visibility.string();
      if (name != "wire" && name != "plaintext" && name != "both") { throw lua::Error{"Invalid interception visibility"}; }
      registration.visibility = name == "wire" ? 1 : name == "plaintext" ? 2 : 3;
    }
    registration.timeout_ms = static_cast<std::uint32_t>(options.field("timeout_ms").boundedInteger(traffic::default_timeout_ms, 1, traffic::maximum_timeout_ms));
    const auto failure = options.field("failure");
    if (failure.present()) {
      const auto name = failure.string();
      if (name != "allow" && name != "reject") { throw lua::Error{"Invalid interception failure policy"}; }
      registration.fail_closed = name == "reject";
    }
  }

  bool decide(lua_State *state) {
    const auto id = identifier(state, 1);
    const auto *binding = find(id);
    if (!binding || (binding->registration.stage != TrafficStage::stream && binding->registration.stage != TrafficStage::http)) { return false; }
    const lua::Value ticket_value{state, 2, "Interception ticket"};
    const auto text = ticket_value.string();
    std::uint64_t ticket;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), ticket);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size() || ticket == 0) { throw lua::Error{"Invalid interception ticket"}; }
    const lua::Value decision{state, 3, "Interception decision"};
    const auto action = decision.field("action").string();
    const auto verdict = action == "allow" ? traffic::Verdict::allow : action == "replace" ? traffic::Verdict::replace : action == "reject" ? traffic::Verdict::reject : traffic::Verdict::pending;
    if (verdict == traffic::Verdict::pending) { throw lua::Error{"Invalid interception action"}; }
    std::span<const Byte> encoded;
    if (verdict == traffic::Verdict::replace && binding->registration.stage == TrafficStage::http) {
      decision.onlyFields({"action", "message"});
      const auto message = LuaTrafficValue::message(decision.field("message"));
      constexpr auto header_bytes = 2 * sizeof(Byte) + sizeof(std::uint64_t) + sizeof(std::uint32_t);
      const auto payload = HttpMessageCodec::encode(scratch_.bytes().subspan(header_bytes), message);
      FrameWriter writer{scratch_.bytes().first(header_bytes)};
      writer.tag(traffic::InterceptionCodec::Command::decision);
      writer.integer(ticket);
      writer.tag(verdict);
      writer.integer(static_cast<std::uint32_t>(payload.size()));
      encoded = scratch_.bytes().first(header_bytes + payload.size());
    } else {
      decision.onlyFields(verdict == traffic::Verdict::replace ? std::initializer_list<std::string_view>{"action", "bytes"} : std::initializer_list<std::string_view>{"action"});
      const auto bytes = verdict == traffic::Verdict::replace ? decision.field("bytes").string() : std::string_view{};
      if (bytes.size() > traffic::FlowControl::chunk_bytes) { throw lua::Error{"Stream replacement exceeds its bound"}; }
      encoded = traffic::InterceptionCodec::decision(scratch_.bytes(), ticket, verdict, {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()});
    }
    if (decision_count_ == queued_.size()) { throw lua::Error{"Too many traffic decisions in one callback"}; }
    const auto offset = decisions_.size();
    decisions_.append(encoded);
    queued_[decision_count_++] = {id, offset, encoded.size()};
    return true;
  }

  ServiceSpec specification_;
  std::array<Binding, TrafficLimits::registrations> bindings_;
  std::uint32_t next_identifier_ = 0;
  bool changed_ = true;
  SensitiveAllocation<Memory> scratch_;
  ByteQueue<Memory> decisions_;
  SensitiveAllocation<Memory> effects_;
  std::size_t effect_bytes_ = 0;
  std::array<QueuedDecision, TrafficLimits::decisions> queued_;
  std::size_t decision_count_ = 0;
  Owned<TrafficReply, Memory> reply_;
};

}
