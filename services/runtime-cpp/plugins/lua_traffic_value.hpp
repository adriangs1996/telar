#pragma once

#include "../http/message_codec.hpp"
#include "../traffic/datagram.hpp"
#include "lua_exchange.hpp"
#include "telar_lua/value.hpp"
#include "traffic_protocol.hpp"
#include <charconv>

namespace telar::runtime::plugins {

class LuaTrafficValue {
public:
  static void field(lua_State *state, const char *name, std::string_view value) {
    lua_pushlstring(state, value.data(), value.size());
    lua_setfield(state, -2, name);
  }

  static void field(lua_State *state, const char *name, bool value) { lua_pushboolean(state, value); lua_setfield(state, -2, name); }
  static void number(lua_State *state, const char *name, std::uint64_t value) { lua_pushinteger(state, static_cast<lua_Integer>(value)); lua_setfield(state, -2, name); }
  static void identity(lua_State *state, const char *name, std::uint64_t value) {
    std::array<char, 32> text;
    const auto result = std::to_chars(text.data(), text.data() + text.size(), value);
    field(state, name, std::string_view{text.data(), result.ptr});
  }

  static void push(lua_State *state, const traffic::Event &event, std::uint64_t dropped) {
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

  static traffic::Selection selection(const lua::Value &events, traffic::Selection fallback) {
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

  static HttpMessageView message(const lua::Value &value) {
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
  static std::size_t fields(const lua::Value &value, std::span<HttpMessageView::Field> fields) {
    const auto count = value.arraySize();
    if (count > fields.size()) { throw EncodingError{"Too many HTTP fields"}; }
    for (std::size_t index = 0; index < count; ++index) {
      const auto entry = value.element(static_cast<lua_Integer>(index + 1));
      entry.onlyFields({"name", "value"});
      fields[index] = {entry.field("name").string(), entry.field("value").string()};
    }
    return count;
  }

  static void pushFields(lua_State *state, std::span<const HttpMessageView::Field> fields) {
    lua_createtable(state, static_cast<int>(fields.size()), 0);
    lua_Integer index = 1;
    for (const auto &entry : fields) {
      lua_createtable(state, 0, 2);
      field(state, "name", entry.name);
      field(state, "value", entry.value);
      lua_rawseti(state, -2, index++);
    }
  }

  static void pushMessage(lua_State *state, const HttpMessageView &message) {
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
