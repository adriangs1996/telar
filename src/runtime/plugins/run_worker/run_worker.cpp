module;
#include "telar_platform/trace_macro.hpp"

module telar.runtime.plugins.run_worker;

import telar.lua;
import telar.sys.posix;
import telar.plugins;
import telar.runtime.redirect.direction;
import telar.runtime.vocabulary.frames;
import telar.config.runtime;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.runtime.plugins.tap_configuration;
import telar.runtime.traffic.capture_analysis;
import telar.runtime.traffic.control_backend;
import telar.base.ds;

namespace telar::runtime::plugins {

  namespace {

    // The Lua a tap worker runs before its plugin, and the traffic API it hands the plugin.
    constexpr std::string_view bootstrap{
#include "plugin_bootstrap.inc"
    };

    constexpr std::string_view traffic_api{
#include "traffic_api.inc"
    };

  }

  LuaEffects::LuaEffects(lua_State* state) noexcept
      : state_(state),
        restored_top_(lua_gettop(state)) {}

  LuaEffects::~LuaEffects() {
    lua_settop(state_, restored_top_);
  }

  EffectBatch LuaEffects::read(int index) {
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

      batch.notifications.atMut(effect) = {
          .level = notificationLevel(string(table, "level", false)),
          .duration_ms = static_cast<std::uint32_t>(integer(table, "duration_ms", default_duration_ms)),
          .title = string(table, "title", true),
          .message = string(table, "message", false),
      };
    }

    return batch;
  }

  std::string_view LuaEffects::string(int table, const char* field, bool required) {
    lua_getfield(state_, table, field);
    if (!required && lua_isnil(state_, -1)) {
      return {};
    }

    std::size_t size = 0;
    const auto* bytes = lua_tolstring(state_, -1, &size);
    if (bytes == nullptr) {
      throw lua::Error{"Invalid effect"};
    }

    // Numeric fields become temporary Lua strings; keep them rooted until encoding completes.
    return {bytes, size};
  }

  lua_Integer LuaEffects::integer(int table, const char* field, lua_Integer fallback) {
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

  NotificationLevel LuaEffects::notificationLevel(std::string_view level) {
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

  void LuaExchange::push(lua_State* state, const ExchangeView& exchange, bool traffic) {
    if (!exchange.request && !exchange.response) {
      luaL_error(state, "exchange has no captured half");
    }

    const auto& final_half = exchange.response ? *exchange.response : *exchange.request;

    lua_createtable(state, 0, 13);
    if (traffic) {
      setIdentity(state, "id", exchange.identity.id);
    } else {
      lua::setField(state, "id", static_cast<lua_Integer>(std::bit_cast<std::int64_t>(exchange.identity.id)));
    }

    lua::setField(state, "host", exchange.host);
    lua::setField(state, "protocol", protocolName(exchange.protocol));
    if (traffic) {
      setIdentity(state, "connection_id", exchange.key.connection);
    } else {
      lua::setField(state, "connection_id", static_cast<lua_Integer>(std::bit_cast<std::int64_t>(exchange.key.connection)));
    }

    lua::setField(state, "stream_id", static_cast<lua_Integer>(exchange.key.stream));
    lua::setField(state, "method", exchange.method);
    lua::setField(state, "target", exchange.target);
    lua::setField(state, "status", static_cast<lua_Integer>(exchange.response ? exchange.response->status_code : 0));
    lua::setField(state, "outcome", outcomeName(final_half.outcome));
    lua::setField(state, "started_at_ms", static_cast<lua_Integer>(exchange.started_at_ms));
    lua::setField(state, "finished_at_ms", static_cast<lua_Integer>(final_half.finished_at_ms));
    pushHalf(state, exchange.request, traffic);
    lua_setfield(state, -2, "request");
    pushHalf(state, exchange.response, traffic);
    lua_setfield(state, -2, "response");
    lua::pushReadOnly(state, "exchange is immutable");
  }

  void LuaExchange::setIdentity(lua_State* state, const char* name, std::uint64_t value) {
    ds::Array<char, 32> text;
    const auto result = std::to_chars(text.dataMut(), text.dataMut() + text.size(), value);

    lua::setField(state, name, {text.data(), static_cast<std::size_t>(result.ptr - text.data())});
  }

  std::string_view LuaExchange::protocolName(ExchangeProtocol protocol) noexcept {
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

  std::string_view LuaExchange::outcomeName(CaptureOutcome outcome) noexcept {
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

  void LuaExchange::pushHalf(lua_State* state, const ds::Option<HalfView>& half, bool traffic) {
    if (!half) {
      lua_pushnil(state);
      return;
    }

    lua_createtable(state, 0, 5);
    pushHead(state, half->head, traffic);
    lua_setfield(state, -2, "head");
    lua::setField(state, "body", {reinterpret_cast<const char*>(half->body.data()), half->body.size()});
    lua::setField(state, "body_truncated", half->body_truncated);
    lua::setField(state, "body_encoding", half->encoding);
    lua::setField(state, "body_decoded", half->decoded);
    if (traffic) {
      lua::setField(state, "head_truncated", half->head_truncated);
      lua::setField(state, "status", static_cast<lua_Integer>(half->status_code));
      lua::setField(state, "outcome", outcomeName(half->outcome));
      lua::setField(state, "finished_at_ms", static_cast<lua_Integer>(half->finished_at_ms));
    }

    lua::pushReadOnly(state, "exchange is immutable");
  }

  void LuaExchange::pushHead(lua_State* state, std::span<const std::uint8_t> bytes, bool traffic) {
    std::string_view remaining{reinterpret_cast<const char*>(bytes.data()), bytes.size()};

    lua_createtable(state, 0, 2);
    lua::setField(state, "raw", remaining);
    lua_createtable(state, 0, 0);
    lua_Integer index = 1;

    while (!remaining.empty()) {
      const auto end = remaining.find("\r\n");
      const auto line = remaining.substr(0, end);
      const auto colon = line.find(':', line.starts_with(':') && line.size() > 1 ? 1 : 0);
      if (colon != std::string_view::npos) {
        lua_createtable(state, 0, 2);
        lua::setField(state, "name", traffic ? line.substr(0, colon) : trimText(line.substr(0, colon), " \t"));
        auto value = line.substr(colon + 1);

        if (traffic) {
          const auto first = value.find_first_not_of(" \t");

          value = first == std::string_view::npos ? std::string_view{} : value.substr(first);
        } else {
          value = trimText(value, " \t");
        }

        lua::setField(state, "value", value);
        lua::pushReadOnly(state, "exchange is immutable");
        lua_seti(state, -2, index++);
      }

      if (end == std::string_view::npos) {
        break;
      }

      remaining.remove_prefix(end + 2);
    }

    lua::pushReadOnly(state, "exchange is immutable");
    lua_setfield(state, -2, "fields");
    lua::pushReadOnly(state, "exchange is immutable");
  }

  void LuaTrafficValue::push(lua_State* state, const traffic::Event& event, std::uint64_t dropped) {
    lua_createtable(state, 0, 24);
    lua::setField(state, "kind", traffic::Protocol::name(event.kind));
    lua::setDecimal(state, "session_id", event.session);
    lua::setDecimal(state, "sequence", event.sequence);
    lua::setDecimal(state, "subscriber_drops", dropped);
    lua::setField(state, "visibility", std::string_view{"wire"});
    lua::setField(state, "timestamp_us", static_cast<lua_Integer>(event.timestamp_us));
    lua::setField(state, "interface_index", static_cast<lua_Integer>(event.interface_index));
    lua::setField(state, "link_type", static_cast<lua_Integer>(event.link_type));
    lua::setField(state, "captured_bytes", static_cast<lua_Integer>(event.bytes.size()));
    lua::setField(state, "original_bytes", static_cast<lua_Integer>(event.original_bytes));
    lua::setDecimal(state, "kernel_drops", event.kernel_drops);
    lua::setDecimal(state, "capture_drops", event.capture_drops);
    lua::setDecimal(state, "runtime_drops", event.runtime_drops);
    lua::setField(state, "interface", event.interface);
    lua::setField(state, "offline", event.offline);
    lua::setField(state, "truncated", event.kind == traffic::Kind::packet && event.bytes.size() < event.original_bytes);
    lua::setField(state, "bytes", std::string_view{reinterpret_cast<const char*>(event.bytes.data()), event.bytes.size()});
    if (event.kind == traffic::Kind::ready && !event.bytes.empty()) {
      lua::setField(state, "reason", std::string_view{reinterpret_cast<const char*>(event.bytes.data()), event.bytes.size()});
    }

    if (traffic::isFlow(event.kind) || event.kind == traffic::Kind::intercept_request || event.kind == traffic::Kind::http_intercept_request) {
      const auto flow = traffic::FlowCodec::decode(event.bytes);

      lua::setDecimal(state, "flow_id", flow.id);
      lua::setDecimal(state, "offset", flow.offset);
      lua::setDecimal(state, "ticket", flow.ticket);
      lua::setField(state, "client", flow.client);
      lua::setField(state, "server", flow.server);
      lua::setField(state, "host", flow.host);
      lua::setField(state, "reason", flow.reason);
      lua::setField(state, "source", std::string_view{flow.source == traffic::FlowSource::proxy ? "proxy" : "capture"});
      lua::setField(state, "direction", std::string_view{flow.direction == traffic::Direction::outbound ? "outbound" : "inbound"});
      lua::setField(state, "visibility", std::string_view{flow.visibility == traffic::Visibility::plaintext ? "plaintext" : "wire"});
      lua::setField(state, "bytes", std::string_view{reinterpret_cast<const char*>(flow.bytes.data()), flow.bytes.size()});
      lua::setField(state, "captured_bytes", static_cast<lua_Integer>(flow.bytes.size()));
      lua::setField(state, "original_bytes", static_cast<lua_Integer>(flow.bytes.size()));
      if (event.kind == traffic::Kind::http_intercept_request) {
        pushMessage(state, HttpMessageCodec::decode(flow.bytes));
        lua_setfield(state, -2, "message");
        lua::setField(state, "bytes", std::string_view{});
      }
    } else if (event.kind == traffic::Kind::datagram) {
      const auto item = traffic::DatagramCodec::decode(event.bytes);

      lua::setField(state, "transport", traffic::DatagramCodec::name(item.transport));
      lua::setField(state, "source", std::string_view{"capture"});
      lua::setField(state, "ipv6", item.ipv6);
      lua::setField(state, "source_address", std::string_view{traffic::IpPayload::addressText(item.source_address, item.ipv6).data()});
      lua::setField(state, "destination_address", std::string_view{traffic::IpPayload::addressText(item.destination_address, item.ipv6).data()});
      lua::setField(state, "bytes", std::string_view{reinterpret_cast<const char*>(item.bytes.data()), item.bytes.size()});
      lua::setField(state, "truncated", item.truncated);
      lua::setField(state, "captured_bytes", static_cast<lua_Integer>(item.bytes.size()));
      lua::setField(state, "original_bytes", static_cast<lua_Integer>(item.original_bytes));
      if (item.transport == traffic::DatagramTransport::udp) {
        lua::setField(state, "source_port", static_cast<lua_Integer>(item.source_port));
        lua::setField(state, "destination_port", static_cast<lua_Integer>(item.destination_port));
      } else {
        lua::setField(state, "icmp_type", static_cast<lua_Integer>(item.icmp_type));
        lua::setField(state, "icmp_code", static_cast<lua_Integer>(item.icmp_code));
        if (item.echo()) {
          lua::setField(state, "icmp_identifier", static_cast<lua_Integer>(traffic::NetworkPacket::word(item.bytes, 4)));
          lua::setField(state, "icmp_sequence", static_cast<lua_Integer>(traffic::NetworkPacket::word(item.bytes, 6)));
        }
      }
    } else if (event.kind == traffic::Kind::exchange) {
      LuaExchange::push(state, Protocol::decodeExchange(event.bytes), true);
      lua_setfield(state, -2, "exchange");
      lua::setField(state, "bytes", std::string_view{});
    }
  }

  traffic::Selection LuaTrafficValue::selection(const lua::Value& events, traffic::Selection fallback) {
    if (!events.present()) {
      return fallback;
    }

    events.onlyFields({"packet", "exchange", "flow", "datagram"});
    Byte mask = 0;

    if (events.field("packet").boolean(false)) {
      mask |= static_cast<Byte>(traffic::Selection::packets);
    }

    if (events.field("exchange").boolean(false)) {
      mask |= static_cast<Byte>(traffic::Selection::exchanges);
    }

    if (events.field("flow").boolean(false)) {
      mask |= static_cast<Byte>(traffic::Selection::flows);
    }

    if (events.field("datagram").boolean(false)) {
      mask |= static_cast<Byte>(traffic::Selection::datagrams);
    }

    if (mask == 0) {
      throw lua::Error{"Traffic events must select packet, flow, exchange or datagram"};
    }

    return static_cast<traffic::Selection>(mask);
  }

  tbc::view<HttpMessageView, tbc::lt::a> LuaTrafficValue::message(const lua::Value& value) {
    value.onlyFields({"protocol", "response", "response_to_head", "stream_id", "method", "target", "reason", "scheme", "authority", "status", "headers", "trailers", "body", "body_decoded"});
    HttpMessageView message;
    const auto protocol = value.field("protocol").string();
    if (protocol != "http10" && protocol != "http11" && protocol != "h2") {
      throw EncodingError{"Invalid HTTP protocol"};
    }

    message.version = protocol == "h2" ? HttpVersion::http2 : protocol == "http10" ? HttpVersion::http10
                                                                                   : HttpVersion::http11;
    message.response = value.field("response").boolean(false);
    message.response_to_head = value.field("response_to_head").boolean(false);
    message.stream = static_cast<std::uint32_t>(value.field("stream_id").boundedInteger(0, 0, std::numeric_limits<std::int32_t>::max()));
    message.method = value.field("method").string();
    message.target = value.field("target").string();
    message.reason = value.field("reason").string();
    message.scheme = value.field("scheme").string();
    message.authority = value.field("authority").string();
    message.status = static_cast<std::uint16_t>(value.field("status").boundedInteger(0, 0, 599));
    message.header_count = fields(value.field("headers"), message.headers.viewMut());
    message.trailer_count = fields(value.field("trailers"), message.trailers.viewMut());
    const auto body = value.field("body").string();

    message.body = {reinterpret_cast<const Byte*>(body.data()), body.size()};
    return message;
  }

  std::size_t LuaTrafficValue::fields(const lua::Value& value, tbc::view<std::span<HttpMessageView::Field>, tbc::lt::a> fields) {
    const auto count = value.arraySize();
    if (count > fields.size()) {
      throw EncodingError{"Too many HTTP fields"};
    }

    for (std::size_t index = 0; index < count; ++index) {
      const auto entry = value.element(static_cast<lua_Integer>(index + 1));

      entry.onlyFields({"name", "value"});
      fields[index] = {entry.field("name").string(), entry.field("value").string()};
    }

    return count;
  }

  void LuaTrafficValue::pushFields(lua_State* state, std::span<const HttpMessageView::Field> fields) {
    lua_createtable(state, static_cast<int>(fields.size()), 0);
    lua_Integer index = 1;

    for (const auto& entry : fields) {
      lua_createtable(state, 0, 2);
      lua::setField(state, "name", entry.name);
      lua::setField(state, "value", entry.value);
      lua_rawseti(state, -2, index++);
    }
  }

  void LuaTrafficValue::pushMessage(lua_State* state, const HttpMessageView& message) {
    constexpr ds::Array protocols{std::string_view{"http10"}, std::string_view{"http11"}, std::string_view{"h2"}};

    lua_createtable(state, 0, 15);
    lua::setField(state, "protocol", protocols[static_cast<std::size_t>(message.version)]);
    lua::setField(state, "response", message.response);
    lua::setField(state, "response_to_head", message.response_to_head);
    lua::setField(state, "stream_id", static_cast<lua_Integer>(message.stream));
    lua::setField(state, "method", message.method);
    lua::setField(state, "target", message.target);
    lua::setField(state, "reason", message.reason);
    lua::setField(state, "scheme", message.scheme);
    lua::setField(state, "authority", message.authority);
    lua::setField(state, "status", static_cast<lua_Integer>(message.status));
    lua::setField(state, "body", std::string_view{reinterpret_cast<const char*>(message.body.data()), message.body.size()});
    lua::setField(state, "body_decoded", true);
    pushFields(state, std::span{message.headers}.first(message.header_count));
    lua_setfield(state, -2, "headers");
    pushFields(state, std::span{message.trailers}.first(message.trailer_count));
    lua_setfield(state, -2, "trailers");
  }

  traffic::control::Request LuaTrafficControl::request(const lua::Value& options) {
    namespace control = traffic::control;
    namespace recording = traffic::recording;
    auto request = control::Protocol::action(options.field("action").string());
    if (request.recording) {
      options.onlyFields({"action", "id", "cursor", "max_bytes", "max_events", "max_age_ms", "limit", "events", "filter", "host"});
      auto& recording = request.recording.getMut();

      recording.id = identity(options.field("id"));
      recording.cursor = identity(options.field("cursor"));
      recording.max_bytes = options.field("max_bytes").boundedInteger(recording.max_bytes, 1, recording::Limits::session_bytes);
      recording.max_events = options.field("max_events").boundedInteger(recording.max_events, 1, recording::Limits::events);
      recording.max_age_ms = options.field("max_age_ms").boundedInteger(recording.max_age_ms, 1, recording::Limits::age_ms);
      recording.limit = options.field("limit").boundedInteger(recording.limit, 1, recording::Limits::page_events);
      recording.selection = LuaTrafficValue::selection(options.field("events"), recording.selection);
      const auto filter = options.field("filter");
      const auto host = options.field("host");

      if (filter.present()) {
        recording.filter = filter.string();
      }

      if (host.present()) {
        recording.host = host.string();
      }
    } else if (request.operation == control::Operation::redirect_start) {
      options.onlyFields({"action", "targets", "processes", "direction"});
      const auto direction = options.field("direction");
      if (direction.present()) {
        request.direction = redirect::parseDirection(direction.string());
      }

      const auto targets = options.field("targets");

      request.target_count = targets.arraySize();
      if (request.target_count > request.targets.size()) {
        throw lua::Error{"Too many redirect targets"};
      }

      for (std::size_t index = 0; index < request.target_count; ++index) {
        request.targets.atMut(index) = targets.element(index + 1).string();
      }

      const auto processes = options.field("processes");
      if (processes.present()) {
        request.process_count = processes.arraySize();
        if (request.process_count == 0 || request.process_count > request.processes.size()) {
          throw lua::Error{"Redirect requires 1..16 selected processes"};
        }

        for (std::size_t index = 0; index < request.process_count; ++index) {
          request.processes.atMut(index) = processes.element(index + 1).boundedInteger(0, 1, std::numeric_limits<std::int32_t>::max());
        }
      }
    } else {
      options.onlyFields({"action"});
    }

    return request;
  }

  void LuaTrafficControl::push(lua_State* state, const traffic::control::Reply& reply) {
    constexpr ds::Array results{"ok", "disabled", "authorization_required", "busy", "failed", "cleanup_required"};
    constexpr ds::Array capture{"disabled", "idle", "live", "offline"};
    constexpr ds::Array redirect{"disabled", "idle", "starting", "active", "stopping", "cleanup_required"};
    constexpr ds::Array trust{"absent", "installed", "stale"};

    lua_createtable(state, 0, 10);
    lua::setField(state, "result", std::string_view{results[static_cast<std::size_t>(reply.result)]});
    lua::setField(state, "message", reply.message);
    lua::setField(state, "administration_enabled", reply.status.administration);
    lua_createtable(state, reply.argument_count, 0);
    for (std::size_t index = 0; index < reply.argument_count; ++index) {
      const auto argument = reply.authorization[index];

      lua_pushlstring(state, argument.data(), argument.size());
      lua_rawseti(state, -2, index + 1);
    }

    lua_setfield(state, -2, "authorization_argv");
    lua_createtable(state, 0, 4);
    lua::setField(state, "state", std::string_view{capture[static_cast<std::size_t>(reply.status.capture)]});
    lua::setDecimal(state, "session_id", reply.status.capture_session);
    lua::setField(state, "interfaces", static_cast<lua_Integer>(reply.status.interfaces));
    lua::setField(state, "interface_errors", static_cast<lua_Integer>(reply.status.interface_errors));
    lua_setfield(state, -2, "capture");
    lua_createtable(state, 0, 1);
    lua::setField(state, "state", std::string_view{redirect[static_cast<std::size_t>(reply.status.redirect)]});
    lua_setfield(state, -2, "redirect");
    lua_createtable(state, 0, 5);
    lua::setField(state, "active", reply.status.proxy);
    lua::setField(state, "port", static_cast<lua_Integer>(reply.status.port));
    lua::setField(state, "transparent_tls", reply.status.transparent_tls);
    lua::setField(state, "tls_accepting", reply.status.tls_accepting);
    lua::setField(state, "interception", reply.status.interception);
    lua_setfield(state, -2, "proxy");
    lua_createtable(state, 0, 4);
    lua::setField(state, "trust_record", std::string_view{trust[static_cast<std::size_t>(reply.status.trust)]});
    lua::setField(state, "fingerprint_sha1", reply.fingerprint_sha1);
    lua::setField(state, "fingerprint_sha256", reply.fingerprint_sha256);
    lua::setField(state, "certificate", std::string_view{reinterpret_cast<const char*>(reply.certificate.data()), reply.certificate.size()});
    lua_setfield(state, -2, "ca");
    if (!reply.recording.empty()) {
      recordings(state, traffic::recording::Protocol::page(reply.recording));
    }
  }

  std::uint64_t LuaTrafficControl::identity(const lua::Value& value) {
    if (!value.present()) {
      return 0;
    }

    const auto text = value.string();
    const auto result = parseExact<std::uint64_t>(text);
    if (!result) {
      throw lua::Error{"Invalid recording identity or cursor"};
    }

    return *result;
  }

  void LuaTrafficControl::metadata(lua_State* state, const traffic::recording::Page& page) {
    lua_createtable(state, 0, 12);
    lua::setDecimal(state, "id", page.id);
    lua::setField(state, "active", page.active);
    lua::setField(state, "gap", page.gap);
    lua::setDecimal(state, "oldest_cursor", page.oldest);
    lua::setDecimal(state, "next_cursor", page.next);
    lua::setDecimal(state, "end_cursor", page.end);
    lua::setDecimal(state, "evicted", page.evicted);
    lua::setDecimal(state, "dropped", page.dropped);
    lua::setDecimal(state, "contention_drops", page.contention_drops);
    lua::setField(state, "retained_bytes", static_cast<lua_Integer>(page.bytes));
  }

  void LuaTrafficControl::recordings(lua_State* state, const traffic::recording::Page& page) {
    namespace recording = traffic::recording;

    if (page.format == recording::Format::list) {
      lua_createtable(state, page.count, 0);
      FrameReader rows{page.rows};

      for (std::uint32_t index = 0; index < page.count; ++index) {
        metadata(state, recording::Protocol::page(rows.bytes()));
        lua_rawseti(state, -2, index + 1);
      }

      rows.finish();
      lua_setfield(state, -2, "recordings");
      return;
    }

    metadata(state, page);
    lua::setField(state, "pcapng", page.format == recording::Format::pcapng ? std::string_view{reinterpret_cast<const char*>(page.rows.data()), page.rows.size()} : std::string_view{});
    lua_createtable(state, page.format == recording::Format::events ? page.count : 0, 0);
    if (page.format == recording::Format::events) {
      FrameReader rows{page.rows};

      for (std::uint32_t index = 0; index < page.count; ++index) {
        const auto cursor = rows.integer<std::uint64_t>();

        LuaTrafficValue::push(state, traffic::Protocol::decode(rows.bytes()), 0);
        lua::setDecimal(state, "recording_cursor", cursor);
        lua_rawseti(state, -2, index + 1);
      }

      rows.finish();
    }

    lua_setfield(state, -2, "events");
    lua_setfield(state, -2, "recording");
  }

  template <Allocator Memory>
  LuaTraffic<Memory>::LuaTraffic(Memory& memory, ServiceSpec specification)
      : specification_(specification),
        scratch_(memory, HttpMessageLimits::message_bytes + 32),
        decisions_(memory, 3 * 1024 * 1024),
        effects_(memory, Limits::effect_bytes),
        reply_(ds::makeBox<TrafficReply>(memory)) {}

  template <Allocator Memory>
  void LuaTraffic<Memory>::install(lua_State* state) {
    if (luaL_loadbufferx(state, traffic_api.data(), traffic_api.size(), "@telar-traffic-api.lua", "t") != LUA_OK) {
      lua_error(state);
    }

    lua_call(state, 0, 1);
    lua_getglobal(state, "telar");
    lua_newtable(state);
    lua_pushvalue(state, -1);
    lua_setfield(state, -3, "traffic");
    lua_remove(state, -2);
    lua_createtable(state, 0, 5);
    constexpr ds::Array operations{
        std::pair{"traffic_subscribe", Operation::subscribe},
        std::pair{"traffic_intercept", Operation::intercept},
        std::pair{"traffic_decide", Operation::decide},
        std::pair{"cancel", Operation::cancel},
        std::pair{"traffic_control", Operation::control},
    };

    for (const auto& [name, operation] : operations) {
      lua_pushlightuserdata(state, this);
      lua_pushinteger(state, static_cast<int>(operation));
      lua_pushcclosure(state, &call, 2);
      lua_setfield(state, -2, name);
    }

    lua_call(state, 2, 0);
  }

  template <Allocator Memory>
  bool LuaTraffic<Memory>::listening() const noexcept {
    return std::ranges::any_of(bindings_, [](const auto& binding) {
      return binding.callback != LUA_NOREF;
    });
  }

  template <Allocator Memory>
  void LuaTraffic<Memory>::begin() noexcept {
    decisions_.clear();
    decision_count_ = 0;
    effect_bytes_ = 0;
  }

  template <Allocator Memory>
  void LuaTraffic<Memory>::invoke(lua_State* state, const TrafficEvent& event) {
    auto* binding = find(event.registration);
    if (!binding) {
      return;
    }

    const auto stage = binding->registration.stage;

    lua_rawgeti(state, LUA_REGISTRYINDEX, binding->callback);
    if (stage == TrafficStage::control) {
      unbind(state, *binding);
      if (!event.error.empty()) {
        lua_pushlstring(state, event.error.data(), event.error.size());
        lua_pushnil(state);
      } else {
        lua_pushnil(state);
        LuaTrafficControl::push(state, traffic::control::Protocol::reply(event.control));
      }

      lua_call(state, 2, 1);
      LuaEffects reader{state};

      effect_bytes_ = Protocol::encodeEffects(effects_.bytesMut(), event.event_id, reader.read(-1)).size();
      return;
    }

    lua_pushnil(state);
    LuaTrafficValue::push(state, event.event, event.dropped);
    lua_createtable(state, 0, 3);
    lua::setField(state, "id", specification_.name.view());
    lua::setDecimal(state, "generation", specification_.generation);
    ds::Array<char, 64> digest;

    lua::setField(state, "digest", encodeLowerHex(specification_.digest, digest.viewMut()));
    lua_setfield(state, -2, "app");
    lua_call(state, 2, 1);
    if (stage == TrafficStage::observe) {
      LuaEffects reader{state};

      effect_bytes_ = Protocol::encodeEffects(effects_.bytesMut(), event.event_id, reader.read(-1)).size();
    }
  }

  template <Allocator Memory>
  tbc::view<std::span<const Byte>, tbc::lt::a> LuaTraffic<Memory>::finish(std::uint64_t event_id, tbc::view<std::span<Byte>, tbc::lt::a> output) {
    auto& reply = reply_.getMut();

    reply.event_id = event_id;
    reply.changed = changed_;
    reply.registration_count = 0;
    if (changed_) {
      for (const auto& binding : bindings_) {
        if (binding.callback != LUA_NOREF) {
          reply.registrations.atMut(reply.registration_count++) = binding.registration;
        }
      }
    }

    // The outcome views this host's buffers only while the reply is encoded.
    TrafficOutcome outcome;

    outcome.decision_count = decision_count_;
    for (std::size_t index = 0; index < decision_count_; ++index) {
      const auto& queued = queued_[index];

      outcome.decisions.atMut(index) = {queued.registration, decisions_.readable().subspan(queued.offset, queued.bytes)};
    }

    outcome.effects = effects_.bytes().first(effect_bytes_);
    const auto encoded = TrafficProtocol::reply(output, reply, outcome);

    changed_ = false;
    return encoded;
  }

  template <Allocator Memory>
  int LuaTraffic<Memory>::call(lua_State* state) {
    auto& self = *static_cast<LuaTraffic*>(lua_touserdata(state, lua_upvalueindex(1)));
    const auto operation = static_cast<Operation>(lua_tointeger(state, lua_upvalueindex(2)));
    ds::Array<char, 1024> error{};

    try {
      switch (operation) {
      case Operation::subscribe:
        lua_pushinteger(state, self.registerCallback(state, false));
        return 1;
      case Operation::intercept:
        lua_pushinteger(state, self.registerCallback(state, true));
        return 1;
      case Operation::decide:
        lua_pushboolean(state, self.decide(state));
        return 1;
      case Operation::cancel: {
        const auto id = identifier(state, 1);
        if (auto* binding = self.find(id)) {
          self.unbind(state, *binding);
        }

        return 0;
      }
      case Operation::control:
        lua_pushinteger(state, self.registerControl(state));
        return 1;
      }
    } catch (const std::exception& failure) {
      std::snprintf(error.dataMut(), error.size(), "%s", failure.what());
    }

    return luaL_error(state, "%s", error.data());
  }

  template <Allocator Memory>
  std::uint32_t LuaTraffic<Memory>::identifier(lua_State* state, int index) {
    const lua::Value value{state, index, "Traffic operation identifier"};

    return static_cast<std::uint32_t>(value.boundedInteger(0, 1, std::numeric_limits<std::uint32_t>::max()));
  }

  template <Allocator Memory>
  auto LuaTraffic<Memory>::find(std::uint32_t id) noexcept -> Binding* {
    for (auto& binding : bindings_.viewMut()) {
      if (binding.callback != LUA_NOREF && binding.registration.id == id) {
        return &binding;
      }
    }

    return nullptr;
  }

  template <Allocator Memory>
  std::uint32_t LuaTraffic<Memory>::registerControl(lua_State* state) {
    if (lua_type(state, 2) != LUA_TFUNCTION) {
      throw lua::Error{"Traffic callback must be a function"};
    }

    if (next_identifier_ == std::numeric_limits<std::uint32_t>::max()) {
      throw lua::Error{"Traffic identifiers exhausted"};
    }

    const lua::Value options{state, 1, "Traffic control options"};
    const auto request = LuaTrafficControl::request(options);
    if (!traffic::control::authorized(specification_, request)) {
      throw lua::Error{"Traffic capability denied"};
    }

    const auto active = std::ranges::count_if(bindings_, [](const auto& binding) {
      return binding.callback != LUA_NOREF && binding.registration.stage == TrafficStage::control;
    });
    if (static_cast<std::size_t>(active) >= TrafficLimits::controls) {
      throw lua::Error{"Traffic control request limit reached"};
    }

    const auto encoded = traffic::control::Protocol::encode(scratch_.bytesMut(), request);
    TrafficRegistration registration;

    registration.stage = TrafficStage::control;
    registration.request.assign({reinterpret_cast<const char*>(encoded.data()), encoded.size()});
    return bind(state, registration);
  }

  template <Allocator Memory>
  std::uint32_t LuaTraffic<Memory>::registerCallback(lua_State* state, bool intercept) {
    if (!specification_.allows(intercept ? Capability::traffic_intercept : Capability::traffic_observe)) {
      throw lua::Error{"Traffic capability denied"};
    }

    if (lua_type(state, 2) != LUA_TFUNCTION) {
      throw lua::Error{"Traffic callback must be a function"};
    }

    if (next_identifier_ == std::numeric_limits<std::uint32_t>::max()) {
      throw lua::Error{"Traffic identifiers exhausted"};
    }

    TrafficRegistration registration;
    const lua::Value options{state, 1, "Traffic options"};

    if (intercept) {
      interception(options, registration);
    } else {
      subscription(options, registration);
    }

    return bind(state, registration);
  }

  template <Allocator Memory>
  std::uint32_t LuaTraffic<Memory>::bind(lua_State* state, TrafficRegistration registration) {
    for (auto& binding : bindings_.viewMut()) {
      if (binding.callback != LUA_NOREF) {
        continue;
      }

      lua_pushvalue(state, 2);
      binding.callback = luaL_ref(state, LUA_REGISTRYINDEX);
      registration.id = ++next_identifier_;
      binding.registration = registration;
      changed_ = true;
      return registration.id;
    }

    throw lua::Error{"Traffic registration limit reached"};
  }

  template <Allocator Memory>
  void LuaTraffic<Memory>::unbind(lua_State* state, Binding& binding) noexcept {
    luaL_unref(state, LUA_REGISTRYINDEX, binding.callback);
    binding.callback = LUA_NOREF;
    changed_ = true;
  }

  template <Allocator Memory>
  void LuaTraffic<Memory>::subscription(const lua::Value& options, TrafficRegistration& registration) {
    options.onlyFields({"filter", "events"});
    const auto filter = options.field("filter");
    if (filter.present()) {
      registration.filter.assign(filter.string());
    }

    if (registration.filter.view().size() > traffic::Limits::filter_bytes) {
      throw lua::Error{"Traffic filter exceeds its limit"};
    }

    if (registration.filter.view().contains('\0')) {
      throw lua::Error{"Traffic filter contains a zero byte"};
    }

    registration.selection = LuaTrafficValue::selection(options.field("events"), registration.selection);
  }

  template <Allocator Memory>
  void LuaTraffic<Memory>::interception(const lua::Value& options, TrafficRegistration& registration) {
    options.onlyFields({"host", "stage", "direction", "visibility", "timeout_ms", "failure"});
    registration.host.assign(options.field("host").string());
    if (!ProxyHostname::validPattern(registration.host.view())) {
      throw lua::Error{"Interception requires a valid host scope"};
    }

    const auto stage = options.field("stage");
    const auto stage_name = stage.present() ? stage.string() : std::string_view{"stream"};
    if (stage_name != "stream" && stage_name != "http") {
      throw lua::Error{"Interception stage must be stream or http"};
    }

    registration.stage = stage_name == "http" ? TrafficStage::http : TrafficStage::stream;
    const auto direction = options.field("direction");
    if (direction.present()) {
      const auto name = direction.string();
      if (name != "outbound" && name != "inbound" && name != "both") {
        throw lua::Error{"Invalid interception direction"};
      }

      registration.directions = name == "outbound" ? 1 : name == "inbound" ? 2
                                                                           : 3;
    }

    const auto visibility = options.field("visibility");

    registration.visibility = registration.stage == TrafficStage::http ? 3 : 2;
    if (visibility.present()) {
      const auto name = visibility.string();
      if (name != "wire" && name != "plaintext" && name != "both") {
        throw lua::Error{"Invalid interception visibility"};
      }

      registration.visibility = name == "wire" ? 1 : name == "plaintext" ? 2
                                                                         : 3;
    }

    registration.timeout_ms = static_cast<std::uint32_t>(options.field("timeout_ms").boundedInteger(traffic::default_timeout_ms, 1, traffic::maximum_timeout_ms));
    const auto failure = options.field("failure");
    if (failure.present()) {
      const auto name = failure.string();
      if (name != "allow" && name != "reject") {
        throw lua::Error{"Invalid interception failure policy"};
      }

      registration.fail_closed = name == "reject";
    }
  }

  template <Allocator Memory>
  bool LuaTraffic<Memory>::decide(lua_State* state) {
    const auto id = identifier(state, 1);
    const auto* binding = find(id);
    if (!binding || (binding->registration.stage != TrafficStage::stream && binding->registration.stage != TrafficStage::http)) {
      return false;
    }

    const lua::Value ticket_value{state, 2, "Interception ticket"};
    const auto text = ticket_value.string();
    const auto ticket = parseExact<std::uint64_t>(text).valueOr(0);
    if (ticket == 0) {
      throw lua::Error{"Invalid interception ticket"};
    }

    const lua::Value decision{state, 3, "Interception decision"};
    const auto action = decision.field("action").string();
    const auto verdict = action == "allow" ? traffic::Verdict::allow : action == "replace" ? traffic::Verdict::replace
                                                                   : action == "reject"    ? traffic::Verdict::reject
                                                                                           : traffic::Verdict::pending;
    if (verdict == traffic::Verdict::pending) {
      throw lua::Error{"Invalid interception action"};
    }

    std::span<const Byte> encoded;

    if (verdict == traffic::Verdict::replace && binding->registration.stage == TrafficStage::http) {
      decision.onlyFields({"action", "message"});
      const auto message = LuaTrafficValue::message(decision.field("message"));
      constexpr auto header_bytes = 2 * sizeof(Byte) + sizeof(std::uint64_t) + sizeof(std::uint32_t);
      const auto payload = HttpMessageCodec::encode(scratch_.bytesMut().subspan(header_bytes), message);
      FrameWriter writer{scratch_.bytesMut().first(header_bytes)};

      writer.tag(traffic::InterceptionCodec::Command::decision);
      writer.integer(ticket);
      writer.tag(verdict);
      writer.integer(static_cast<std::uint32_t>(payload.size()));
      encoded = scratch_.bytes().first(header_bytes + payload.size());
    } else {
      decision.onlyFields(verdict == traffic::Verdict::replace ? std::initializer_list<std::string_view>{"action", "bytes"} : std::initializer_list<std::string_view>{"action"});
      const auto bytes = verdict == traffic::Verdict::replace ? decision.field("bytes").string() : std::string_view{};
      if (bytes.size() > traffic::FlowControl::chunk_bytes) {
        throw lua::Error{"Stream replacement exceeds its bound"};
      }

      encoded = traffic::InterceptionCodec::decision(scratch_.bytesMut(), ticket, verdict, {reinterpret_cast<const Byte*>(bytes.data()), bytes.size()});
    }

    if (decision_count_ == queued_.size()) {
      throw lua::Error{"Too many traffic decisions in one callback"};
    }

    const auto offset = decisions_.size();

    decisions_.append(encoded);
    queued_.atMut(decision_count_++) = {id, offset, encoded.size()};
    return true;
  }

  Host::Host(Memory& memory, const char* entry_path, const ServiceSpec* traffic)
      : memory_(memory),
        vm_(erased_, {Limits::lua_bytes, Limits::lua_instructions, Limits::callback_deadline}) {
    ds::Array<char, PATH_MAX> resolved;
    if (::realpath(entry_path, resolved.dataMut()) == nullptr) {
      throw SystemError{"Resolve tap entrypoint"};
    }

    const std::string_view path{resolved.data()};
    const auto separator = path.rfind('/');

    package_root_.assign(path.substr(0, separator));
    const auto source = readFile(memory_, resolved.data(), Limits::entry_bytes);

    vm_.execute(bootstrap, "@telar-tap-bootstrap.lua");
    lua_setglobal(vm_.state(), "telar");
    if (traffic) {
      traffic_.emplace(memory_, *traffic);
    }

    vm_.invoke(&install, this, 0);
    vm_.resetBudget();
    Entrypoint entry{*this, source};

    vm_.invoke(&loadEntrypoint, &entry, 0);
    lua_settop(vm_.state(), 0);
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Host::trafficSetup(tbc::view<std::span<Byte>, tbc::lt::a> output) {
    if (!traffic_) {
      throw EncodingError{"Traffic worker is not configured"};
    }

    return traffic_.getMut().finish(0, output);
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Host::invokeTraffic(const TrafficEvent& event, tbc::view<std::span<Byte>, tbc::lt::a> output) {
    if (!traffic_) {
      throw EncodingError{"Traffic worker is not configured"};
    }

    lua_settop(vm_.state(), 0);
    vm_.resetBudget();
    traffic_.getMut().begin();
    TrafficInvocation invocation{*this, event};

    try {
      vm_.invoke(&invokeTrafficCallback, &invocation, 0);
    } catch (const std::exception&) {
      lua_settop(vm_.state(), 0);
      return Protocol::encodeError(output, event.event_id, "unknown Lua error");
    }

    return traffic_.getMut().finish(event.event_id, output);
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> Host::invoke(const ExchangeView& exchange, tbc::view<std::span<Byte>, tbc::lt::a> output) {
    TELAR_TRACE("plugins.invokeExchange");
    auto* state = vm_.state();

    lua_settop(state, 0);
    vm_.resetBudget();
    Invocation invocation{*this, exchange, output};

    try {
      vm_.invoke(&invokeCallback, &invocation, 0);
    } catch (const std::exception&) {
      lua_settop(state, 0);
      // The reference clears the callback stack before producing its error frame.
      return Protocol::encodeError(output, exchange.identity.id, "unknown Lua error");
    }

    if (invocation.encoding_failed) {
      throw EncodingError{"Tap effects exceed the reply limit"};
    }

    return output.first(invocation.encoded_bytes);
  }

  tbc::view<void*, tbc::lt::static_storage> Host::callContext(lua_State* state) noexcept {
    return lua_touserdata(state, 1);
  }

  int Host::invokeTrafficCallback(lua_State* state) {
    auto& invocation = *static_cast<TrafficInvocation*>(callContext(state));
    const auto event = invocation.event;
    ds::Array<char, 1024> error{};

    try {
      invocation.host.traffic_.getMut().invoke(state, event);
      return 0;
    } catch (const std::exception& failure) {
      std::snprintf(error.dataMut(), error.size(), "%s", failure.what());
    }

    return luaL_error(state, "%s", error.data());
  }

  auto Host::context(lua_State* state) noexcept -> tbc::view<Host&, tbc::lt::static_storage> {
    return *static_cast<Host*>(callContext(state));
  }

  std::string_view Host::errorMessage(lua_State* state) {
    std::size_t size = 0;
    const auto* bytes = lua_tolstring(state, -1, &size);

    return bytes == nullptr ? std::string_view{"unknown Lua error"} : std::string_view{bytes, size};
  }

  int Host::install(lua_State* state) {
    auto& host = context(state);

    try {
      lua_getglobal(state, "telar");
      lua_getfield(state, -1, "redact");
      lua_pushcfunction(state, &redactSecrets);
      lua_setfield(state, -2, "secrets");
      lua_pop(state, 1);
      lua::JsonDecoder<ErasingMemory>::install(state, host.erased_);
      host.modules_.emplace(state, host.package_root_.view());
      if (host.traffic_) {
        host.traffic_.getMut().install(state);
      }

      return 0;
    } catch (const std::exception& error) {
      return luaL_error(state, "%s", error.what());
    }
  }

  int Host::loadEntrypoint(lua_State* state) {
    auto& entry = *static_cast<Entrypoint*>(lua_touserdata(state, 1));
    if (luaL_loadbufferx(state, entry.source.data(), entry.source.size(), "@tap-plugin.lua", "t") != LUA_OK) {
      return lua_error(state);
    }

    lua_call(state, 0, 1);
    if (!lua_istable(state, -1)) {
      return luaL_error(state, "Invalid tap plugin");
    }

    lua_getfield(state, -1, "on_exchange");
    if (!lua_isfunction(state, -1)) {
      if (lua_isnil(state, -1) && entry.host.traffic_ && entry.host.traffic_->listening()) {
        lua_pop(state, 1);
        return 0;
      }

      return luaL_error(state, "Missing exchange handler");
    }

    entry.host.callback_reference_ = luaL_ref(state, LUA_REGISTRYINDEX);
    return 0;
  }

  int Host::invokeCallback(lua_State* state) {
    auto& invocation = *static_cast<Invocation*>(lua_touserdata(state, 1));

    lua_rawgeti(state, LUA_REGISTRYINDEX, invocation.host.callback_reference_);
    LuaExchange::push(state, invocation.exchange);
    lua_call(state, 1, 1);
    try {
      LuaEffects reader{state};
      const auto effects = reader.read(-1);

      invocation.encoded_bytes = Protocol::encodeEffects(invocation.output, invocation.exchange.identity.id, effects).size();
      return 0;
    } catch (const EncodingError&) {
      invocation.encoding_failed = true;
      return 0;
    } catch (const std::exception&) {
      const auto message = errorMessage(state);

      lua_pushlstring(state, message.data(), message.size());
      return lua_error(state);
    }
  }

  int Host::redactSecrets(lua_State* state) {
    std::size_t size = 0;
    const auto* bytes = lua_tolstring(state, 1, &size);
    if (bytes == nullptr) {
      lua_pushliteral(state, "redact.secrets expects a string");
      return lua_error(state);
    }

    const std::string_view input{bytes, size};
    const auto output = HistoryFilters::looksLikeSecret(input) ? std::string_view{"[REDACTED]"} : input;

    lua_pushlstring(state, output.data(), output.size());
    return 1;
  }

  void runWorker(Memory& memory, const char* entry_path, bool traffic) {
    PipeStream stream{STDIN_FILENO, STDOUT_FILENO};
    FrameChannel channel{stream};
    ds::Option<ServiceSpec> specification;

    if (traffic) {
      const auto frame = channel.receive(memory, 4096);
      if (!frame) {
        return;
      }

      specification = TrafficProtocol::setup(frame->bytes());
    }

    Host host{memory, entry_path, specification ? &*specification : nullptr};
    SensitiveAllocation output{memory, traffic ? TrafficLimits::reply_bytes : Limits::effect_bytes};

    if (traffic) {
      channel.send(host.trafficSetup(output.bytesMut()));
    }

    while (auto frame = channel.receive(memory, Limits::frame_bytes)) {
      const auto bytes = frame->bytes();
      std::span<const Byte> encoded;

      if (traffic && (bytes.front() == static_cast<Byte>(FrameKind::traffic_event) || bytes.front() == static_cast<Byte>(FrameKind::traffic_control_event))) {
        encoded = host.invokeTraffic(TrafficProtocol::event(bytes), output.bytesMut());
      } else {
        encoded = host.invoke(Protocol::decodeExchange(bytes), output.bytesMut().first(Limits::effect_bytes));
      }

      channel.send(encoded);
      eraseSensitive(output.bytesMut().data(), encoded.size());
    }
  }

}
