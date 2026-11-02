#pragma once

#include "lua_traffic_value.hpp"
#include "../traffic/control_access.hpp"

namespace telar::runtime::plugins {

class LuaTrafficControl {
public:
  static traffic::control::Request request(const lua::Value &options) {
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

  static void push(lua_State *state, const traffic::control::Reply &reply) {
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
  static std::uint64_t identity(const lua::Value &value) {
    if (!value.present()) { return 0; }
    const auto text = value.string();
    std::uint64_t result;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
    if (text.empty() || parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) { throw lua::Error{"Invalid recording identity or cursor"}; }
    return result;
  }

  static void metadata(lua_State *state, const traffic::recording::Page &page) {
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

  static void recordings(lua_State *state, const traffic::recording::Page &page) {
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
