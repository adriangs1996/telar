module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <stdlib.h>

#include <cstddef>
#include <cstdint>
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <cstring>


#include <pcap/pcap.h>
#include <arpa/inet.h>
#include <cmath>
#include <cstdio>
#include <cassert>
#include <limits.h>
#include <cerrno>

#include "traffic_api.hpp"

#include "plugin_bootstrap.hpp"
#include <sys/stat.h>
#include <fcntl.h>

#include <poll.h>
#include <sys/uio.h>
#include <unistd.h>

export module telar.runtime.plugins.run_worker;

import std;

export import telar.runtime.plugins.protocol;
export import telar.lua;


export import telar.runtime.http.message;
export import telar.runtime.traffic.capture_analysis;

export import telar.runtime.plugins.worker;


export import telar.runtime.traffic.control_backend;


export import telar.base.memory;


export import telar.config;
export import telar.platform;


export import telar.runtime.plugins.tap_configuration;
import telar.base.diagnostics;
import telar.client.protocol;
import telar.platform.primitives;

// Interface: plugins/lua_effects.cppm
export {
namespace telar::runtime::plugins {

class LuaEffects {
public:
  inline explicit LuaEffects(lua_State *state) noexcept : state_(state), restored_top_(lua_gettop(state)) {}

  inline ~LuaEffects() { lua_settop(state_, restored_top_); }

  LuaEffects(const LuaEffects &) = delete;
  LuaEffects &operator=(const LuaEffects &) = delete;

  inline EffectBatch read(int index) {
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
  inline std::string_view string(int table, const char *field, bool required) {
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

  inline lua_Integer integer(int table, const char *field, lua_Integer fallback) {
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

  inline static NotificationLevel notificationLevel(std::string_view level) {
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
}

// Interface: plugins/lua_exchange.cppm
export {
namespace telar::runtime::plugins {

class LuaExchange {
public:
  inline static void push(lua_State *state, const ExchangeView &exchange, bool traffic = false) {
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
  inline static void setIdentity(lua_State *state, const char *name, std::uint64_t value) {
    std::array<char, 32> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value);
    setString(state, name, {text.data(), result.ptr});
  }

  inline static std::string_view protocolName(ExchangeProtocol protocol) noexcept {
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

  inline static std::string_view outcomeName(CaptureOutcome outcome) noexcept {
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

  inline static void setString(lua_State *state, const char *name, std::string_view text) {
    lua_pushlstring(state, text.data(), text.size());
    lua_setfield(state, -2, name);
  }

  inline static void setInteger(lua_State *state, const char *name, std::int64_t value) {
    lua_pushinteger(state, value);
    lua_setfield(state, -2, name);
  }

  inline static void setBoolean(lua_State *state, const char *name, bool value) {
    lua_pushboolean(state, value);
    lua_setfield(state, -2, name);
  }

  inline static void pushHalf(lua_State *state, const std::optional<HalfView> &half, bool traffic) {
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

  inline static std::string_view trim(std::string_view text) noexcept {
    const auto first = text.find_first_not_of(" \t");
    if (first == std::string_view::npos) {
      return {};
    }
    return text.substr(first, text.find_last_not_of(" \t") - first + 1);
  }

  inline static void pushHead(lua_State *state, std::span<const std::uint8_t> bytes, bool traffic) {
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

  inline static void freeze(lua_State *state) {
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

  inline static int rejectMutation(lua_State *state) {
    lua_pushliteral(state, "exchange is immutable");
    return lua_error(state);
  }
};

}
}

// Interface: plugins/lua_traffic_value.cppm
export {
namespace telar::runtime::plugins {

class LuaTrafficValue {
public:
  inline static void field(lua_State *state, const char *name, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, name);
  }

  inline static void field(lua_State *state, const char *name, bool value) { lua_pushboolean(state, value); lua_setfield(state, -2, name); }
  inline static void number(lua_State *state, const char *name, std::uint64_t value) { lua_pushinteger(state, static_cast<lua_Integer>(value)); lua_setfield(state, -2, name); }
  inline static void identity(lua_State *state, const char *name, std::uint64_t value) {
    std::array<char, 32> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value);
    field(state, name, std::string_view{text.data(), result.ptr});
  }

  inline static void push(lua_State *state, const traffic::Event &event, std::uint64_t dropped) {
    lua_createtable(state, 0, 24);
    field(state, "kind", traffic::Protocol::name(event.kind));
    identity(state, "session_id", event.session);
    identity(state, "sequence", event.sequence);
    identity(state, "subscriber_drops", dropped);
    field(state, "visibility", std::string_view{"wire"});
    number(state, "timestamp_us", event.timestamp_us);
    number(state, "interface_index", event.interface_index);
    number(state, "link_type", event.link_type);
    number(state, "captured_bytes", event.bytes.size());
    number(state, "original_bytes", event.original_bytes);
    identity(state, "kernel_drops", event.kernel_drops);
    identity(state, "capture_drops", event.capture_drops);
    identity(state, "runtime_drops", event.runtime_drops);
    field(state, "interface", event.interface);
    field(state, "offline", event.offline);
    field(state, "truncated", event.kind == traffic::Kind::packet && event.bytes.size() < event.original_bytes);
    field(state, "bytes", std::string_view{reinterpret_cast<const char *>(event.bytes.data()), event.bytes.size()});
    if (event.kind == traffic::Kind::ready && !event.bytes.empty()) { field(state, "reason", std::string_view{reinterpret_cast<const char *>(event.bytes.data()), event.bytes.size()}); }
    if (traffic::isFlow(event.kind) || event.kind == traffic::Kind::intercept_request || event.kind == traffic::Kind::http_intercept_request) {
      const auto flow = traffic::FlowCodec::decode(event.bytes);
      identity(state, "flow_id", flow.id);
      identity(state, "offset", flow.offset);
      identity(state, "ticket", flow.ticket);
      field(state, "client", flow.client);
      field(state, "server", flow.server);
      field(state, "host", flow.host);
      field(state, "reason", flow.reason);
      field(state, "source", std::string_view{flow.source == traffic::FlowSource::proxy ? "proxy" : "capture"});
      field(state, "direction", std::string_view{flow.direction == traffic::Direction::outbound ? "outbound" : "inbound"});
      field(state, "visibility", std::string_view{flow.visibility == traffic::Visibility::plaintext ? "plaintext" : "wire"});
      field(state, "bytes", std::string_view{reinterpret_cast<const char *>(flow.bytes.data()), flow.bytes.size()});
      number(state, "captured_bytes", flow.bytes.size());
      number(state, "original_bytes", flow.bytes.size());
      if (event.kind == traffic::Kind::http_intercept_request) {
        pushMessage(state, HttpMessageCodec::decode(flow.bytes));
        lua_setfield(state, -2, "message");
        field(state, "bytes", std::string_view{});
      }
    } else if (event.kind == traffic::Kind::datagram) {
      const auto item = traffic::DatagramCodec::decode(event.bytes);
      field(state, "transport", traffic::DatagramCodec::name(item.transport));
      field(state, "source", std::string_view{"capture"});
      field(state, "ipv6", item.ipv6);
      field(state, "source_address", std::string_view{traffic::IpPayload::addressText(item.source_address, item.ipv6).data()});
      field(state, "destination_address", std::string_view{traffic::IpPayload::addressText(item.destination_address, item.ipv6).data()});
      field(state, "bytes", std::string_view{reinterpret_cast<const char *>(item.bytes.data()), item.bytes.size()});
      field(state, "truncated", item.truncated);
      number(state, "captured_bytes", item.bytes.size());
      number(state, "original_bytes", item.original_bytes);
      if (item.transport == traffic::DatagramTransport::udp) {
        number(state, "source_port", item.source_port);
        number(state, "destination_port", item.destination_port);
      } else {
        number(state, "icmp_type", item.icmp_type);
        number(state, "icmp_code", item.icmp_code);
        if (item.echo()) {
          number(state, "icmp_identifier", traffic::NetworkPacket::word(item.bytes, 4));
          number(state, "icmp_sequence", traffic::NetworkPacket::word(item.bytes, 6));
        }
      }
    } else if (event.kind == traffic::Kind::exchange) {
      LuaExchange::push(state, Protocol::decodeExchange(event.bytes), true);
      lua_setfield(state, -2, "exchange");
      field(state, "bytes", std::string_view{});
    }
  }

  inline static traffic::Selection selection(const lua::Value &events, traffic::Selection fallback) {
    if (!events.present()) { return fallback; }
    events.onlyFields({"packet", "exchange", "flow", "datagram"});
    Byte mask = 0;
    if (events.field("packet").boolean(false)) { mask |= static_cast<Byte>(traffic::Selection::packets); }
    if (events.field("exchange").boolean(false)) { mask |= static_cast<Byte>(traffic::Selection::exchanges); }
    if (events.field("flow").boolean(false)) { mask |= static_cast<Byte>(traffic::Selection::flows); }
    if (events.field("datagram").boolean(false)) { mask |= static_cast<Byte>(traffic::Selection::datagrams); }
    if (mask == 0) { throw lua::Error{"Traffic events must select packet, flow, exchange or datagram"}; }
    return static_cast<traffic::Selection>(mask);
  }

  inline static HttpMessageView message(const lua::Value &value) {
    value.onlyFields({"protocol", "response", "response_to_head", "stream_id", "method", "target", "reason", "scheme", "authority", "status", "headers", "trailers", "body", "body_decoded"});
    HttpMessageView message;
    const auto protocol = value.field("protocol").string();
    if (protocol != "http10" && protocol != "http11" && protocol != "h2") { throw EncodingError{"Invalid HTTP protocol"}; }
    message.version = protocol == "h2" ? HttpVersion::http2 : protocol == "http10" ? HttpVersion::http10 : HttpVersion::http11;
    message.response = value.field("response").boolean(false);
    message.response_to_head = value.field("response_to_head").boolean(false);
    message.stream = static_cast<std::uint32_t>(value.field("stream_id").boundedInteger(0, 0, INT32_MAX));
    message.method = value.field("method").string();
    message.target = value.field("target").string();
    message.reason = value.field("reason").string();
    message.scheme = value.field("scheme").string();
    message.authority = value.field("authority").string();
    message.status = static_cast<std::uint16_t>(value.field("status").boundedInteger(0, 0, 599));
    message.header_count = fields(value.field("headers"), message.headers);
    message.trailer_count = fields(value.field("trailers"), message.trailers);
    const auto body = value.field("body").string();
    message.body = {reinterpret_cast<const Byte *>(body.data()), body.size()};
    return message;
  }

private:
  inline static std::size_t fields(const lua::Value &value, std::span<HttpMessageView::Field> fields) {
    const auto count = value.arraySize();
    if (count > fields.size()) { throw EncodingError{"Too many HTTP fields"}; }
    for (std::size_t index = 0; index < count; ++index) {
      const auto entry = value.element(static_cast<lua_Integer>(index + 1));
      entry.onlyFields({"name", "value"});
      fields[index] = {entry.field("name").string(), entry.field("value").string()};
    }
    return count;
  }

  inline static void pushFields(lua_State *state, std::span<const HttpMessageView::Field> fields) {
    lua_createtable(state, static_cast<int>(fields.size()), 0);
    lua_Integer index = 1;
    for (const auto &entry : fields) {
      lua_createtable(state, 0, 2);
      field(state, "name", entry.name);
      field(state, "value", entry.value);
      lua_rawseti(state, -2, index++);
    }
  }

  inline static void pushMessage(lua_State *state, const HttpMessageView &message) {
    constexpr std::array protocols{std::string_view{"http10"}, std::string_view{"http11"}, std::string_view{"h2"}};
    lua_createtable(state, 0, 15);
    field(state, "protocol", protocols[static_cast<std::size_t>(message.version)]);
    field(state, "response", message.response);
    field(state, "response_to_head", message.response_to_head);
    number(state, "stream_id", message.stream);
    field(state, "method", message.method);
    field(state, "target", message.target);
    field(state, "reason", message.reason);
    field(state, "scheme", message.scheme);
    field(state, "authority", message.authority);
    number(state, "status", message.status);
    field(state, "body", std::string_view{reinterpret_cast<const char *>(message.body.data()), message.body.size()});
    field(state, "body_decoded", true);
    pushFields(state, std::span{message.headers}.first(message.header_count));
    lua_setfield(state, -2, "headers");
    pushFields(state, std::span{message.trailers}.first(message.trailer_count));
    lua_setfield(state, -2, "trailers");
  }
};

}
}

// Interface: plugins/lua_traffic_control.cppm
export {
namespace telar::runtime::plugins {

class LuaTrafficControl {
public:
  inline static traffic::control::Request request(const lua::Value &options) {
    namespace control = traffic::control;
    namespace recording = traffic::recording;
    auto request = control::Protocol::action(options.field("action").string());
    if (request.recording) {
      options.onlyFields({"action", "id", "cursor", "max_bytes", "max_events", "max_age_ms", "limit", "events", "filter", "host"});
      auto &recording = *request.recording;
      recording.id = identity(options.field("id"));
      recording.cursor = identity(options.field("cursor"));
      recording.max_bytes = options.field("max_bytes").boundedInteger(recording.max_bytes, 1, recording::Limits::session_bytes);
      recording.max_events = options.field("max_events").boundedInteger(recording.max_events, 1, recording::Limits::events);
      recording.max_age_ms = options.field("max_age_ms").boundedInteger(recording.max_age_ms, 1, recording::Limits::age_ms);
      recording.limit = options.field("limit").boundedInteger(recording.limit, 1, recording::Limits::page_events);
      recording.selection = LuaTrafficValue::selection(options.field("events"), recording.selection);
      const auto filter = options.field("filter");
      const auto host = options.field("host");
      if (filter.present()) { recording.filter = filter.string(); }
      if (host.present()) { recording.host = host.string(); }
    } else if (request.operation == control::Operation::redirect_start) {
      options.onlyFields({"action", "targets", "processes", "direction"});
      const auto direction = options.field("direction");
      if (direction.present()) { request.direction = redirect::parseDirection(direction.string()); }
      const auto targets = options.field("targets");
      request.target_count = targets.arraySize();
      if (request.target_count > request.targets.size()) { throw lua::Error{"Too many redirect targets"}; }
      for (std::size_t index = 0; index < request.target_count; ++index) { request.targets[index] = targets.element(index + 1).string(); }
      const auto processes = options.field("processes");
      if (processes.present()) {
        request.process_count = processes.arraySize();
        if (request.process_count == 0 || request.process_count > request.processes.size()) { throw lua::Error{"Redirect requires 1..16 selected processes"}; }
        for (std::size_t index = 0; index < request.process_count; ++index) { request.processes[index] = processes.element(index + 1).boundedInteger(0, 1, INT32_MAX); }
      }
    } else { options.onlyFields({"action"}); }
    return request;
  }

  inline static void push(lua_State *state, const traffic::control::Reply &reply) {
    using Value = LuaTrafficValue;
    constexpr std::array results{"ok", "disabled", "authorization_required", "busy", "failed", "cleanup_required"};
    constexpr std::array capture{"disabled", "idle", "live", "offline"};
    constexpr std::array redirect{"disabled", "idle", "starting", "active", "stopping", "cleanup_required"};
    constexpr std::array trust{"absent", "installed", "stale"};
    lua_createtable(state, 0, 10);
    Value::field(state, "result", std::string_view{results[static_cast<std::size_t>(reply.result)]});
    Value::field(state, "message", reply.message);
    Value::field(state, "administration_enabled", reply.status.administration);
    lua_createtable(state, reply.argument_count, 0);
    for (std::size_t index = 0; index < reply.argument_count; ++index) {
      const auto argument = reply.authorization[index];
      lua_pushlstring(state, argument.data(), argument.size());
      lua_rawseti(state, -2, index + 1);
    }
    lua_setfield(state, -2, "authorization_argv");
    lua_createtable(state, 0, 4);
    Value::field(state, "state", std::string_view{capture[static_cast<std::size_t>(reply.status.capture)]});
    Value::identity(state, "session_id", reply.status.capture_session);
    Value::number(state, "interfaces", reply.status.interfaces);
    Value::number(state, "interface_errors", reply.status.interface_errors);
    lua_setfield(state, -2, "capture");
    lua_createtable(state, 0, 1);
    Value::field(state, "state", std::string_view{redirect[static_cast<std::size_t>(reply.status.redirect)]});
    lua_setfield(state, -2, "redirect");
    lua_createtable(state, 0, 5);
    Value::field(state, "active", reply.status.proxy);
    Value::number(state, "port", reply.status.port);
    Value::field(state, "transparent_tls", reply.status.transparent_tls);
    Value::field(state, "tls_accepting", reply.status.tls_accepting);
    Value::field(state, "interception", reply.status.interception);
    lua_setfield(state, -2, "proxy");
    lua_createtable(state, 0, 4);
    Value::field(state, "trust_record", std::string_view{trust[static_cast<std::size_t>(reply.status.trust)]});
    Value::field(state, "fingerprint_sha1", reply.fingerprint_sha1);
    Value::field(state, "fingerprint_sha256", reply.fingerprint_sha256);
    Value::field(state, "certificate", std::string_view{reinterpret_cast<const char *>(reply.certificate.data()), reply.certificate.size()});
    lua_setfield(state, -2, "ca");
    if (!reply.recording.empty()) { recordings(state, traffic::recording::Protocol::page(reply.recording)); }
  }

private:
  inline static std::uint64_t identity(const lua::Value &value) {
    if (!value.present()) { return 0; }
    const auto text = value.string();
    std::uint64_t result;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
    if (text.empty() || parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) { throw lua::Error{"Invalid recording identity or cursor"}; }
    return result;
  }

  inline static void metadata(lua_State *state, const traffic::recording::Page &page) {
    using Value = LuaTrafficValue;
    lua_createtable(state, 0, 12);
    Value::identity(state, "id", page.id);
    Value::field(state, "active", page.active);
    Value::field(state, "gap", page.gap);
    Value::identity(state, "oldest_cursor", page.oldest);
    Value::identity(state, "next_cursor", page.next);
    Value::identity(state, "end_cursor", page.end);
    Value::identity(state, "evicted", page.evicted);
    Value::identity(state, "dropped", page.dropped);
    Value::identity(state, "contention_drops", page.contention_drops);
    Value::number(state, "retained_bytes", page.bytes);
  }

  inline static void recordings(lua_State *state, const traffic::recording::Page &page) {
    namespace recording = traffic::recording;
    if (page.format == recording::Format::list) {
      lua_createtable(state, page.count, 0);
      FrameReader rows{page.rows};
      for (std::uint32_t index = 0; index < page.count; ++index) { metadata(state, recording::Protocol::page(rows.bytes())); lua_rawseti(state, -2, index + 1); }
      rows.finish();
      lua_setfield(state, -2, "recordings");
      return;
    }
    metadata(state, page);
    LuaTrafficValue::field(state, "pcapng", page.format == recording::Format::pcapng ? std::string_view{reinterpret_cast<const char *>(page.rows.data()), page.rows.size()} : std::string_view{});
    lua_createtable(state, page.format == recording::Format::events ? page.count : 0, 0);
    if (page.format == recording::Format::events) {
      FrameReader rows{page.rows};
      for (std::uint32_t index = 0; index < page.count; ++index) {
        const auto cursor = rows.integer<std::uint64_t>();
        LuaTrafficValue::push(state, traffic::Protocol::decode(rows.bytes()), 0);
        LuaTrafficValue::identity(state, "recording_cursor", cursor);
        lua_rawseti(state, -2, index + 1);
      }
      rows.finish();
    }
    lua_setfield(state, -2, "events");
    lua_setfield(state, -2, "recording");
  }
};

}
}

// Interface: plugins/lua_traffic.cppm
export {
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
  inline explicit LuaTraffic(Memory &memory, ServiceSpec specification)
      : specification_(specification), scratch_(memory, HttpMessageLimits::message_bytes + 32), decisions_(memory, 3 * 1024 * 1024), effects_(memory, Limits::effect_bytes), reply_(makeOwned<TrafficReply>(memory)) {}

  inline void install(lua_State *state) {
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

  inline bool listening() const noexcept {
    return std::ranges::any_of(bindings_, [](const auto &binding) { return binding.callback != LUA_NOREF; });
  }

  inline void begin() noexcept {
    decisions_.clear();
    decision_count_ = 0;
    effect_bytes_ = 0;
  }

  inline void invoke(lua_State *state, const TrafficEvent &event) {
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

  inline std::span<const Byte> finish(std::uint64_t event_id, std::span<Byte> output) {
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
  inline static int call(lua_State *state) {
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

  inline static std::uint32_t identifier(lua_State *state, int index) {
    const lua::Value value{state, index, "Traffic operation identifier"};
    return static_cast<std::uint32_t>(value.boundedInteger(0, 1, UINT32_MAX));
  }

  inline Binding *find(std::uint32_t id) noexcept {
    for (auto &binding : bindings_) {
      if (binding.callback != LUA_NOREF && binding.registration.id == id) { return &binding; }
    }
    return nullptr;
  }

  inline std::uint32_t registerControl(lua_State *state) {
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

  inline std::uint32_t registerCallback(lua_State *state, bool intercept) {
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

  inline static void subscription(const lua::Value &options, TrafficRegistration &registration) {
    options.onlyFields({"filter", "events"});
    const auto filter = options.field("filter");
    if (filter.present()) { registration.filter.assign(filter.string()); }
    if (registration.filter.view().size() > traffic::Limits::filter_bytes) { throw lua::Error{"Traffic filter exceeds its limit"}; }
    if (registration.filter.view().contains('\0')) { throw lua::Error{"Traffic filter contains a zero byte"}; }
    registration.selection = LuaTrafficValue::selection(options.field("events"), registration.selection);
  }

  inline static void interception(const lua::Value &options, TrafficRegistration &registration) {
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

  inline bool decide(lua_State *state) {
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
}

// Interface: plugins/host.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
class Host {
public:
  inline explicit Host(Memory &memory, const char *entry_path, const ServiceSpec *traffic = nullptr)
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

  inline std::span<const Byte> trafficSetup(std::span<Byte> output) {
    if (!traffic_) { throw EncodingError{"Traffic worker is not configured"}; }
    return traffic_->finish(0, output);
  }

  inline std::span<const Byte> invokeTraffic(const TrafficEvent &event, std::span<Byte> output) {
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

  inline std::span<const Byte> invoke(const ExchangeView &exchange, std::span<Byte> output) {
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

  inline static int invokeTrafficCallback(lua_State *state) {
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

  inline static Host &context(lua_State *state) noexcept {
    return *static_cast<Host *>(lua_touserdata(state, 1));
  }

  inline static std::string_view errorMessage(lua_State *state) {
    std::size_t size = 0;
    const auto *bytes = lua_tolstring(state, -1, &size);
    return bytes == nullptr ? std::string_view{"unknown Lua error"} : std::string_view{bytes, size};
  }

  inline static int install(lua_State *state) {
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

  inline static int loadEntrypoint(lua_State *state) {
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

  inline static int invokeCallback(lua_State *state) {
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

  inline static int redactSecrets(lua_State *state) {
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
}

// Interface: plugins/run_worker.cppm
export {
namespace telar::runtime::plugins {

template <Allocator Memory>
void runWorker(Memory &memory, const char *entry_path, bool traffic = false) {
  PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
  FrameChannel channel{stream};
  std::optional<ServiceSpec> specification;
  if (traffic) {
    const auto frame = channel.receive(memory, 4096);
    if (!frame) { return; }
    specification = TrafficProtocol::setup(frame->bytes());
  }
  Host host{memory, entry_path, specification ? &*specification : nullptr};
  SensitiveAllocation output{memory, traffic ? TrafficLimits::reply_bytes : Limits::effect_bytes};
  if (traffic) { channel.send(host.trafficSetup(output.bytes())); }
  while (auto frame = channel.receive(memory, Limits::frame_bytes)) {
    const auto bytes = frame->bytes();
    std::span<const Byte> encoded;
    if (traffic && (bytes.front() == static_cast<Byte>(FrameKind::traffic_event) || bytes.front() == static_cast<Byte>(FrameKind::traffic_control_event))) { encoded = host.invokeTraffic(TrafficProtocol::event(bytes), output.bytes()); }
    else { encoded = host.invoke(Protocol::decodeExchange(bytes), output.bytes().first(Limits::effect_bytes)); }
    channel.send(encoded);
    eraseSensitive(output.bytes().data(), encoded.size());
  }
}

}
}
