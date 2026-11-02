#pragma once

#include "protocol.hpp"
#include "service_spec.hpp"
#include "../traffic/interception.hpp"
#include "../traffic/control_protocol.hpp"

namespace telar::runtime::plugins {

struct TrafficLimits {
  static constexpr std::size_t registrations = 32;
  static constexpr std::size_t decisions = 32;
  static constexpr std::size_t controls = 8;
  static constexpr std::size_t reply_bytes = 4 * 1024 * 1024;
};

enum class TrafficStage : Byte { observe, stream, http, control };

struct TrafficRegistration {
  std::uint32_t id = 0;
  TrafficStage stage = TrafficStage::observe;
  traffic::Selection selection = traffic::Selection::packets;
  FixedText<traffic::Limits::filter_bytes + 1> filter;
  FixedText<ProxyHostname::maximum_bytes + 1> host;
  Byte directions = 3;
  Byte visibility = 2;
  std::uint32_t timeout_ms = traffic::default_timeout_ms;
  bool fail_closed = false;
  FixedText<traffic::control::Limits::request_bytes> request;

  std::span<const Byte> requestBytes() const noexcept { const auto bytes = request.view(); return {reinterpret_cast<const Byte *>(bytes.data()), bytes.size()}; }

  traffic::InterceptionRule rule() const noexcept { return {host.view(), directions, visibility, timeout_ms, fail_closed, stage == TrafficStage::http}; }
};

struct TrafficDecision {
  std::uint32_t registration = 0;
  std::span<const Byte> payload;
};

struct TrafficReply {
  std::uint64_t event_id = 0;
  bool changed = false;
  std::array<TrafficRegistration, TrafficLimits::registrations> registrations;
  std::size_t registration_count = 0;
  std::array<TrafficDecision, TrafficLimits::decisions> decisions;
  std::size_t decision_count = 0;
  std::span<const Byte> effects;
};

struct TrafficEvent {
  std::uint64_t event_id;
  std::uint32_t registration;
  std::uint64_t dropped;
  traffic::Event event;
  std::span<const Byte> control;
  std::string_view error;
};

class TrafficProtocol {
public:
  static std::span<const Byte> setup(std::span<Byte> output, const ServiceSpec &specification) {
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_setup);
    writer.integer(specification.plugin_id);
    writer.bytes(specification.digest);
    writer.integer(specification.generation);
    writer.text(specification.name.view());
    writer.boolean(specification.allows(Capability::traffic_observe));
    writer.boolean(specification.allows(Capability::traffic_intercept));
    writer.boolean(specification.allows(Capability::traffic_control));
    writer.boolean(specification.allows(Capability::traffic_record));
    return writer.finish();
  }

  static ServiceSpec setup(std::span<const Byte> input) {
    FrameReader reader{input};
    reader.require(FrameKind::traffic_setup);
    ServiceSpec specification;
    specification.plugin_id = reader.integer<std::uint64_t>();
    const auto digest = reader.bytes();
    if (digest.size() != specification.digest.size()) { throw EncodingError{"Invalid traffic package digest"}; }
    std::ranges::copy(digest, specification.digest.begin());
    specification.generation = reader.integer<std::uint64_t>();
    specification.name.assign(reader.text());
    for (const auto capability : {Capability::traffic_observe, Capability::traffic_intercept, Capability::traffic_control, Capability::traffic_record}) {
      if (reader.boolean()) { specification.declared.insert(capability); specification.granted.insert(capability); }
    }
    reader.finish();
    if (specification.plugin_id == 0 || specification.generation == 0) { throw EncodingError{"Invalid traffic package identity"}; }
    return specification;
  }

  static std::span<const Byte> event(std::span<Byte> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::uint64_t dropped = 0) {
    traffic::Protocol::decode(frame);
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.integer(dropped);
    writer.bytes(frame);
    return writer.finish();
  }

  static TrafficEvent event(std::span<const Byte> input) {
    FrameReader reader{input};
    const auto kind = reader.tag(FrameKind::traffic_control_event);
    if (kind != FrameKind::traffic_event && kind != FrameKind::traffic_control_event) { throw EncodingError{"Unexpected worker event"}; }
    TrafficEvent event{.event_id = reader.integer<std::uint64_t>(), .registration = reader.integer<std::uint32_t>(), .dropped = 0, .event = {}};
    if (kind == FrameKind::traffic_event) { event.dropped = reader.integer<std::uint64_t>(); event.event = traffic::Protocol::decode(reader.bytes()); }
    else {
      event.error = reader.text();
      event.control = reader.bytes();
      if (event.error.size() > 1024 || (event.error.empty() == event.control.empty())) { throw EncodingError{"Invalid worker control result"}; }
      if (!event.control.empty()) { traffic::control::Protocol::reply(event.control); }
    }
    reader.finish();
    return event;
  }

  static std::span<const Byte> controlEvent(std::span<Byte> output, std::uint64_t event_id, std::uint32_t registration, std::span<const Byte> frame, std::string_view error = {}) {
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_control_event);
    writer.integer(event_id);
    writer.integer(registration);
    writer.text(error);
    writer.bytes(frame);
    return writer.finish();
  }

  static std::span<const Byte> reply(std::span<Byte> output, const TrafficReply &reply) {
    if (reply.registration_count > reply.registrations.size() || reply.decision_count > reply.decisions.size() || (!reply.changed && reply.registration_count != 0)) { throw EncodingError{"Invalid traffic worker reply"}; }
    FrameWriter writer{output};
    writer.tag(FrameKind::traffic_reply);
    writer.integer(reply.event_id);
    writer.boolean(reply.changed);
    writer.integer(static_cast<Byte>(reply.registration_count));
    for (const auto &registration : std::span{reply.registrations}.first(reply.registration_count)) { write(writer, registration); }
    writer.integer(static_cast<Byte>(reply.decision_count));
    for (const auto &decision : std::span{reply.decisions}.first(reply.decision_count)) {
      writer.integer(decision.registration);
      writer.bytes(decision.payload);
    }
    writer.bytes(reply.effects);
    return writer.finish();
  }

  static TrafficReply reply(std::span<const Byte> input) {
    TrafficReply reply;
    readReply(input, reply);
    return reply;
  }

  static void readReply(std::span<const Byte> input, TrafficReply &reply) {
    if (input.size() > TrafficLimits::reply_bytes) { throw EncodingError{"Traffic worker reply exceeds its bound"}; }
    FrameReader reader{input};
    reader.require(FrameKind::traffic_reply);
    reply.event_id = reader.integer<std::uint64_t>();
    reply.changed = reader.boolean();
    reply.registration_count = reader.integer<Byte>();
    if (reply.registration_count > reply.registrations.size() || (!reply.changed && reply.registration_count != 0)) { throw EncodingError{"Invalid traffic registration count"}; }
    for (auto &registration : std::span{reply.registrations}.first(reply.registration_count)) { registration = read(reader); }
    reply.decision_count = reader.integer<Byte>();
    if (reply.decision_count > reply.decisions.size()) { throw EncodingError{"Invalid traffic decision count"}; }
    for (auto &decision : std::span{reply.decisions}.first(reply.decision_count)) {
      decision.registration = reader.integer<std::uint32_t>();
      decision.payload = reader.bytes();
    }
    reply.effects = reader.bytes();
    reader.finish();
  }

private:
  static void write(FrameWriter &writer, const TrafficRegistration &registration) {
    writer.integer(registration.id);
    writer.tag(registration.stage);
    writer.tag(registration.selection);
    writer.text(registration.filter.view());
    writer.text(registration.host.view());
    writer.integer(registration.directions);
    writer.integer(registration.visibility);
    writer.integer(registration.timeout_ms);
    writer.boolean(registration.fail_closed);
    writer.bytes(registration.requestBytes());
  }

  static TrafficRegistration read(FrameReader &reader) {
    TrafficRegistration registration;
    registration.id = reader.integer<std::uint32_t>();
    registration.stage = reader.tag(TrafficStage::control);
    registration.selection = reader.tag(traffic::Selection::all);
    registration.filter.assign(reader.text());
    registration.host.assign(reader.text());
    registration.directions = reader.integer<Byte>();
    registration.visibility = reader.integer<Byte>();
    registration.timeout_ms = reader.integer<std::uint32_t>();
    registration.fail_closed = reader.boolean();
    registration.request.assign(reader.text());
    if (registration.id == 0 || static_cast<Byte>(registration.selection) == 0 || registration.filter.view().contains('\0')) { throw EncodingError{"Invalid traffic registration"}; }
    if (registration.stage == TrafficStage::control) { traffic::control::Protocol::request(registration.requestBytes()); }
    else if (!registration.request.view().empty()) { throw EncodingError{"Only control registrations carry requests"}; }
    if ((registration.stage == TrafficStage::stream || registration.stage == TrafficStage::http) && (!registration.filter.view().empty() || !ProxyHostname::validPattern(registration.host.view()) || registration.directions == 0 || registration.directions > 3 || registration.visibility == 0 || registration.visibility > 3 || registration.timeout_ms == 0 || registration.timeout_ms > traffic::maximum_timeout_ms)) { throw EncodingError{"Invalid worker interception rule"}; }
    return registration;
  }
};

}
