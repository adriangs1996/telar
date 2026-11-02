#pragma once

#include "ip_payload.hpp"
#include <arpa/inet.h>
#include <algorithm>
#include <optional>
#include <string>
#include <pcap/pcap.h>

namespace telar::runtime::traffic {

struct TcpEndpoint {
  std::array<Byte, 16> address{};
  std::uint16_t port = 0;
  bool ipv6 = false;
  auto operator<=>(const TcpEndpoint &) const = default;

  std::string text() const {
    const auto host = IpPayload::addressText(address, ipv6);
    return (ipv6 ? "[" + std::string{host.data()} + "]:" : std::string{host.data()} + ":") + std::to_string(port);
  }
};

struct TcpPacket {
  TcpEndpoint source;
  TcpEndpoint destination;
  std::uint32_t sequence = 0;
  Byte flags = 0;
  std::span<const Byte> bytes;
  bool truncated = false;
};

class TcpPacketDecoder {
public:
  static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return NetworkPacket::word(bytes, offset);
  }

  static std::optional<TcpPacket> decode(const Event &event) noexcept {
    return decodeNetwork(NetworkPacket::decode(event));
  }

  static std::optional<TcpPacket> decodeNetwork(std::span<const Byte> bytes) noexcept {
    const auto ip = IpPayload::decode(bytes);
    return ip ? decodePayload(*ip) : std::nullopt;
  }

  static std::optional<TcpPacket> decodePayload(const IpPayload &ip) noexcept {
    if (ip.protocol != IPPROTO_TCP) { return {}; }
    TcpPacket packet;
    packet.source.address = ip.source;
    packet.destination.address = ip.destination;
    packet.source.ipv6 = packet.destination.ipv6 = ip.ipv6;
    packet.truncated = ip.truncated;
    auto bytes = ip.bytes;
    if (bytes.size() < 20) { return {}; }
    const auto head = static_cast<std::size_t>(bytes[12] >> 4) * 4;
    if (head < 20 || head > bytes.size()) { return {}; }
    packet.source.port = word(bytes, 0);
    packet.destination.port = word(bytes, 2);
    packet.sequence = (std::uint32_t{word(bytes, 4)} << 16) | word(bytes, 6);
    packet.flags = bytes[13];
    packet.bytes = bytes.subspan(head);
    return packet;
  }
};

}
