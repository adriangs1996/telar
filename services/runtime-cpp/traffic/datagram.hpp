#pragma once

#include "ip_payload.hpp"

namespace telar::runtime::traffic {

enum class DatagramTransport : Byte { udp, icmp, icmpv6 };

struct DatagramEvent {
  DatagramTransport transport = DatagramTransport::udp;
  bool ipv6 = false;
  std::array<Byte, 16> source_address{};
  std::array<Byte, 16> destination_address{};
  std::uint16_t source_port = 0;
  std::uint16_t destination_port = 0;
  Byte icmp_type = 0;
  Byte icmp_code = 0;
  std::uint32_t original_bytes = 0;
  bool truncated = false;
  std::span<const Byte> bytes;

  bool echo() const noexcept {
    return transport != DatagramTransport::udp && icmp_code == 0 && bytes.size() >= 8 && (transport == DatagramTransport::icmp ? icmp_type == 0 || icmp_type == 8 : icmp_type == 128 || icmp_type == 129);
  }
};

class DatagramCodec {
public:
  static std::string_view name(DatagramTransport transport) noexcept {
    constexpr std::array names{std::string_view{"udp"}, std::string_view{"icmp"}, std::string_view{"icmpv6"}};
    return names[static_cast<std::size_t>(transport)];
  }

  static std::span<const Byte> encode(std::span<Byte> output, const DatagramEvent &event) {
    validate(event);
    plugins::FrameWriter writer{output};
    writer.tag(event.transport);
    writer.boolean(event.ipv6);
    writer.bytes(event.source_address);
    writer.bytes(event.destination_address);
    writer.integer(event.source_port);
    writer.integer(event.destination_port);
    writer.integer(event.icmp_type);
    writer.integer(event.icmp_code);
    writer.integer(event.original_bytes);
    writer.boolean(event.truncated);
    writer.bytes(event.bytes);
    return writer.finish();
  }

  static DatagramEvent decode(std::span<const Byte> input) {
    plugins::FrameReader reader{input};
    DatagramEvent event;
    event.transport = reader.tag(DatagramTransport::icmpv6);
    event.ipv6 = reader.boolean();
    const auto source = reader.bytes();
    const auto destination = reader.bytes();
    if (source.size() != event.source_address.size() || destination.size() != event.destination_address.size()) { throw EncodingError{"Invalid datagram address length"}; }
    std::ranges::copy(source, event.source_address.begin());
    std::ranges::copy(destination, event.destination_address.begin());
    event.source_port = reader.integer<std::uint16_t>();
    event.destination_port = reader.integer<std::uint16_t>();
    event.icmp_type = reader.integer<Byte>();
    event.icmp_code = reader.integer<Byte>();
    event.original_bytes = reader.integer<std::uint32_t>();
    event.truncated = reader.boolean();
    event.bytes = reader.bytes();
    reader.finish();
    validate(event);
    return event;
  }

  static std::optional<DatagramEvent> parse(const IpPayload &ip) noexcept {
    DatagramEvent event{.ipv6 = ip.ipv6, .source_address = ip.source, .destination_address = ip.destination};
    if (ip.protocol == IPPROTO_UDP) {
      if (ip.bytes.size() < 8) { return {}; }
      const auto length = NetworkPacket::word(ip.bytes, 4);
      if (length < 8 || length > ip.original_bytes) { return {}; }
      event.source_port = NetworkPacket::word(ip.bytes, 0);
      event.destination_port = NetworkPacket::word(ip.bytes, 2);
      event.original_bytes = length - 8;
      event.bytes = ip.bytes.first(std::min(ip.bytes.size(), std::size_t{length})).subspan(8);
    } else if ((!ip.ipv6 && ip.protocol == IPPROTO_ICMP) || (ip.ipv6 && ip.protocol == IPPROTO_ICMPV6)) {
      if (ip.bytes.size() < 4) { return {}; }
      event.transport = ip.ipv6 ? DatagramTransport::icmpv6 : DatagramTransport::icmp;
      event.icmp_type = ip.bytes[0];
      event.icmp_code = ip.bytes[1];
      event.original_bytes = static_cast<std::uint32_t>(ip.original_bytes);
      event.bytes = ip.bytes;
    } else { return {}; }
    event.truncated = event.bytes.size() < event.original_bytes;
    return event;
  }

private:
  static void validate(const DatagramEvent &event) {
    if (static_cast<Byte>(event.transport) > static_cast<Byte>(DatagramTransport::icmpv6) || event.original_bytes > UINT16_MAX || event.bytes.size() > event.original_bytes || event.truncated != (event.bytes.size() < event.original_bytes) || (event.transport == DatagramTransport::icmp && event.ipv6) || (event.transport == DatagramTransport::icmpv6 && !event.ipv6)) { throw EncodingError{"Invalid datagram metadata"}; }
    if (!event.ipv6 && (std::ranges::any_of(std::span{event.source_address}.subspan(4), [](Byte value) { return value != 0; }) || std::ranges::any_of(std::span{event.destination_address}.subspan(4), [](Byte value) { return value != 0; }))) { throw EncodingError{"Invalid IPv4 datagram address padding"}; }
    if (event.transport != DatagramTransport::udp && (event.bytes.size() < 4 || event.bytes[0] != event.icmp_type || event.bytes[1] != event.icmp_code || event.source_port != 0 || event.destination_port != 0)) { throw EncodingError{"Invalid ICMP message metadata"}; }
  }
};

}
