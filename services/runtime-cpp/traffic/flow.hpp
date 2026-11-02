#pragma once

#include "protocol.hpp"
#include <chrono>
#include <optional>

namespace telar::runtime::traffic {

enum class Direction : Byte { outbound, inbound };
enum class Visibility : Byte { wire, plaintext };
enum class FlowSource : Byte { proxy, capture };
enum class Verdict : Byte { pending, allow, replace, reject };
class HttpControl;

struct FlowEvent {
  std::uint64_t id = 0;
  Direction direction = Direction::outbound;
  Visibility visibility = Visibility::wire;
  FlowSource source = FlowSource::proxy;
  std::uint64_t offset = 0;
  std::uint64_t ticket = 0;
  std::string_view client;
  std::string_view server;
  std::string_view host;
  std::string_view reason;
  std::span<const Byte> bytes;
};

class FlowCodec {
public:
  static auto encode(std::span<Byte> output, const FlowEvent &event) -> std::span<const Byte> {
    plugins::FrameWriter writer{output};
    writer.integer(event.id);
    writer.tag(event.direction);
    writer.tag(event.visibility);
    writer.tag(event.source);
    writer.integer(event.offset);
    writer.integer(event.ticket);
    writer.text(event.client);
    writer.text(event.server);
    writer.text(event.host);
    writer.text(event.reason);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  static FlowEvent decode(std::span<const Byte> input) {
    plugins::FrameReader reader{input};
    FlowEvent event;
    event.id = reader.integer<std::uint64_t>();
    event.direction = reader.tag(Direction::inbound);
    event.visibility = reader.tag(Visibility::plaintext);
    event.source = reader.tag(FlowSource::capture);
    event.offset = reader.integer<std::uint64_t>();
    event.ticket = reader.integer<std::uint64_t>();
    event.client = reader.text();
    event.server = reader.text();
    event.host = reader.text();
    event.reason = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    if (event.client.size() > 128 || event.server.size() > 128 || event.host.size() > 253 || event.reason.size() > 128) {
      throw EncodingError{"Invalid flow metadata"};
    }
    return event;
  }
};

class FlowControl {
public:
  using Time = std::chrono::steady_clock::time_point;
  static constexpr std::size_t chunk_bytes = 64 * 1024;
  struct Decision { Verdict verdict; std::size_t bytes = 0; };

  virtual ~FlowControl() = default;
  virtual void observeFlow(Kind kind, const FlowEvent &event) noexcept = 0;
  virtual std::uint64_t intercept(const FlowEvent &event) noexcept = 0;
  virtual Decision poll(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
  virtual void cancel(std::uint64_t ticket) noexcept = 0;
  virtual std::optional<Time> deadline(std::uint64_t ticket) noexcept = 0;
  virtual int descriptor() const noexcept = 0;
  virtual void drain() noexcept = 0;
  virtual HttpControl *http() noexcept { return nullptr; }
};

struct HttpPolicy {
  bool enabled = false;
  bool fail_closed = false;
};

class HttpControl {
public:
  virtual ~HttpControl() = default;
  virtual HttpPolicy policy(const FlowEvent &context) noexcept = 0;
  virtual std::uint64_t interceptHttp(const FlowEvent &event) noexcept = 0;
  virtual FlowControl::Decision pollHttp(std::uint64_t ticket, std::span<Byte> replacement) noexcept = 0;
  virtual void cancelHttp(std::uint64_t ticket) noexcept = 0;
  virtual std::optional<FlowControl::Time> httpDeadline(std::uint64_t ticket) noexcept = 0;
  virtual void httpUnavailable(const FlowEvent &event) noexcept = 0;
};

inline bool isFlow(Kind kind) noexcept {
  return kind >= Kind::flow_open && kind <= Kind::flow_gap;
}

inline bool selects(Selection selection, Selection flag) noexcept {
  return (static_cast<Byte>(selection) & static_cast<Byte>(flag)) != 0;
}

}
