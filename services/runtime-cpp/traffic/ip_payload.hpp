#pragma once

#include "network_packet.hpp"
#include <algorithm>
#include <arpa/inet.h>
#include <optional>

namespace telar::runtime::traffic {

struct IpPayload {
  std::array<Byte, 16> source{};
  std::array<Byte, 16> destination{};
  std::span<const Byte> bytes;
  std::size_t original_bytes = 0;
  Byte protocol = 0;
  bool ipv6 = false;
  bool truncated = false;

  static std::array<char, INET6_ADDRSTRLEN> addressText(const std::array<Byte, 16> &address, bool ipv6) noexcept {
    std::array<char, INET6_ADDRSTRLEN> text{};
    ::inet_ntop(ipv6 ? AF_INET6 : AF_INET, address.data(), text.data(), text.size());
    return text;
  }

  static std::optional<IpPayload> decode(std::span<const Byte> bytes) noexcept {
    if (bytes.empty()) { return {}; }
    IpPayload result;
    if ((bytes[0] >> 4) == 4) {
      if (bytes.size() < 20 || (NetworkPacket::word(bytes, 6) & 0x3fff) != 0) { return {}; }
      const auto head = std::size_t{bytes[0] & 15u} * 4;
      const auto length = NetworkPacket::word(bytes, 2);
      if (head < 20 || length < head || bytes.size() < head) { return {}; }
      result.truncated = bytes.size() < length;
      result.protocol = bytes[9];
      result.original_bytes = length - head;
      std::ranges::copy(bytes.subspan(12, 4), result.source.begin());
      std::ranges::copy(bytes.subspan(16, 4), result.destination.begin());
      result.bytes = bytes.first(std::min(bytes.size(), std::size_t{length})).subspan(head);
    } else if ((bytes[0] >> 4) == 6) {
      if (bytes.size() < 40 || NetworkPacket::word(bytes, 4) == 0) { return {}; }
      result.ipv6 = true;
      std::ranges::copy(bytes.subspan(8, 16), result.source.begin());
      std::ranges::copy(bytes.subspan(24, 16), result.destination.begin());
      const auto length = std::size_t{NetworkPacket::word(bytes, 4)} + 40;
      result.truncated = bytes.size() < length;
      result.protocol = bytes[6];
      bytes = bytes.first(std::min(bytes.size(), length)).subspan(40);
      result.original_bytes = length - 40;
      for (unsigned depth = 0; result.protocol == 0 || result.protocol == 43 || result.protocol == 60 || result.protocol == 51; ++depth) {
        if (depth == 8 || bytes.size() < 2) { return {}; }
        const auto head = result.protocol == 51 ? (std::size_t{bytes[1]} + 2) * 4 : (std::size_t{bytes[1]} + 1) * 8;
        if (head > bytes.size()) { return {}; }
        result.protocol = bytes[0];
        bytes = bytes.subspan(head);
        result.original_bytes -= head;
      }
      result.bytes = bytes;
    } else { return {}; }
    return result;
  }
};

}
