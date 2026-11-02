#pragma once

#include "protocol.hpp"
#include <pcap/pcap.h>

namespace telar::runtime::traffic {

class NetworkPacket {
public:
  static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>((std::uint16_t{bytes[offset]} << 8) | bytes[offset + 1]);
  }

  static std::span<const Byte> decode(const Event &event) noexcept {
    auto bytes = event.bytes;
    switch (event.link_type) {
    case DLT_EN10MB: {
      if (bytes.size() < 14) { return {}; }
      auto protocol = word(bytes, 12);
      bytes = bytes.subspan(14);
      for (unsigned depth = 0; protocol == 0x8100 || protocol == 0x88a8; ++depth) {
        if (depth == 2 || bytes.size() < 4) { return {}; }
        protocol = word(bytes, 2);
        bytes = bytes.subspan(4);
      }
      if (protocol != 0x0800 && protocol != 0x86dd) { return {}; }
      return bytes;
    }
    case DLT_NULL:
    case DLT_LOOP:
      return bytes.size() < 4 ? std::span<const Byte>{} : bytes.subspan(4);
    case DLT_LINUX_SLL:
      return bytes.size() < 16 ? std::span<const Byte>{} : bytes.subspan(16);
#ifdef DLT_LINUX_SLL2
    case DLT_LINUX_SLL2:
      return bytes.size() < 20 ? std::span<const Byte>{} : bytes.subspan(20);
#endif
    case DLT_RAW:
    case DLT_IPV4:
    case DLT_IPV6:
      return bytes;
    default: return {};
    }
  }
};

}
