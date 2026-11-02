#pragma once

#include "../plugins/frame_reader.hpp"
#include "../plugins/frame_writer.hpp"
#include "../http/message_codec.hpp"
#include <array>
#include <cstddef>

namespace telar::runtime::traffic {

inline constexpr std::string_view socket_suffix = ".traffic";

struct Limits {
  static constexpr std::size_t packet_bytes = 262144;
  static constexpr std::size_t metadata_bytes = 1024;
  static constexpr std::size_t frame_bytes = packet_bytes + metadata_bytes;
  static constexpr std::size_t http_frame_bytes = HttpMessageLimits::message_bytes + 2 * metadata_bytes;
  static constexpr std::size_t filter_bytes = 4096;
  static constexpr std::size_t interface_bytes = 64;
  static constexpr std::size_t interfaces = 128;
  static constexpr std::size_t subscribers = 32;
  static constexpr std::size_t pending_frames = 8;
  static constexpr std::size_t filter_link_types = 16;
  static constexpr std::size_t http_part_bytes = static_cast<long>(48) * 1024;
};

enum class Role : Byte {
  subscribe = 1,
  live_capture = 2,
  offline_capture = 3,
  intercept = 4,
};

enum class Kind : Byte {
  ready,
  packet,
  interface_open,
  interface_closed,
  interface_error,
  statistics,
  capture_started,
  capture_stopped,
  error,
  exchange,
  flow_open,
  stream_data,
  flow_close,
  flow_error,
  flow_gap,
  intercept_request,
  http_intercept_request,
  datagram,
};

enum class Selection : Byte {
  packets = 1,
  exchanges = 2,
  both = 3,
  flows = 4,
  datagrams = 8,
  all = 15,
};

struct Event {
  Kind kind = Kind::packet;
  std::uint64_t session = 0;
  std::uint64_t sequence = 0;
  std::uint64_t timestamp_us = 0;
  std::uint32_t interface_index = 0;
  std::uint32_t link_type = 0;
  std::uint32_t original_bytes = 0;
  std::uint64_t kernel_drops = 0;
  std::uint64_t capture_drops = 0;
  std::uint64_t runtime_drops = 0;
  bool offline = false;
  std::string_view interface;
  std::span<const Byte> bytes;
};

// The independent data socket keeps packet backpressure out of terminal control delivery.
class Protocol {
public:
  static constexpr std::uint32_t magic = 0x31525454;
  static constexpr std::size_t prefix_bytes = sizeof(std::uint32_t) + sizeof(std::uint64_t);
  static constexpr std::size_t greeting_bytes = sizeof(std::uint32_t) + (2 * sizeof(Byte)) + sizeof(std::uint32_t);

  static auto greeting(std::span<Byte> output, Role role, std::string_view filter = {}, Selection selection = Selection::packets) -> std::span<const Byte> {
    if (filter.size() > Limits::filter_bytes || filter.contains('\0') || (role != Role::subscribe && !filter.empty())) {
      throw EncodingError{"Invalid traffic subscription"};
    }

    plugins::FrameWriter writer{output};
    writer.integer(magic);
    writer.tag(role);
    writer.tag(selection);
    writer.text(filter);
    return writer.finish();
  }

  static std::size_t encodedSize(const Event &event) {
    validate(event);
    constexpr auto fixed_bytes = 2 * sizeof(Byte) + 6 * sizeof(std::uint64_t) + 5 * sizeof(std::uint32_t);
    return fixed_bytes + event.interface.size() + event.bytes.size();
  }

  static auto encode(std::span<Byte> output, const Event &event) -> std::span<const Byte> {
    validate(event);
    plugins::FrameWriter writer{output};
    writer.tag(event.kind);
    writer.integer(event.session);
    writer.integer(event.sequence);
    writer.integer(event.timestamp_us);
    writer.integer(event.interface_index);
    writer.integer(event.link_type);
    writer.integer(event.original_bytes);
    writer.integer(event.kernel_drops);
    writer.integer(event.capture_drops);
    writer.integer(event.runtime_drops);
    writer.boolean(event.offline);
    writer.text(event.interface);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  static auto decode(std::span<const Byte> input) -> Event {
    if (input.size() > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    plugins::FrameReader reader{input};
    Event event;
    event.kind = reader.tag(Kind::datagram);
    event.session = reader.integer<std::uint64_t>();
    event.sequence = reader.integer<std::uint64_t>();
    event.timestamp_us = reader.integer<std::uint64_t>();
    event.interface_index = reader.integer<std::uint32_t>();
    event.link_type = reader.integer<std::uint32_t>();
    event.original_bytes = reader.integer<std::uint32_t>();
    event.kernel_drops = reader.integer<std::uint64_t>();
    event.capture_drops = reader.integer<std::uint64_t>();
    event.runtime_drops = reader.integer<std::uint64_t>();
    event.offline = reader.boolean();
    event.interface = reader.text();
    event.bytes = reader.bytes();
    reader.finish();
    validate(event);
    return event;
  }

  static auto prefix(std::size_t bytes, std::uint64_t dropped = 0) -> std::array<Byte, prefix_bytes> {
    if (bytes > Limits::http_frame_bytes) {
      throw EncodingError{"Traffic frame exceeds its limit"};
    }

    std::array<Byte, prefix_bytes> output{};
    plugins::FrameWriter writer{output};
    writer.integer(static_cast<std::uint32_t>(bytes));
    writer.integer(dropped);
    return output;
  }

  static auto name(Kind kind) noexcept -> std::string_view {
    constexpr std::array names{"ready", "packet", "interface.open", "interface.closed", "interface.error", "statistics", "capture.started", "capture.stopped", "error", "exchange", "flow.open", "stream.data", "flow.close", "flow.error", "flow.gap", "intercept.request", "http.intercept.request", "datagram"};
    return names.at(static_cast<std::size_t>(kind));
  }

private:
  static void validate(const Event &event) {
    const auto maximum = event.kind == Kind::http_intercept_request ? HttpMessageLimits::message_bytes + Limits::metadata_bytes : Limits::packet_bytes;
    if (event.interface.size() > Limits::interface_bytes || event.interface.contains('\0') || event.bytes.size() > maximum || (event.kind == Kind::packet && event.bytes.size() > event.original_bytes)) {
      throw EncodingError{"Invalid traffic event"};
    }
  }
};

}
