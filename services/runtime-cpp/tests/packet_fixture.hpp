#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include "telar_base/memory/allocator.hpp"
#include <cstddef>
#include <cstring>
#include <cstdint>
#include <span>
#include <utility>
#include <string_view>
#include <array>
#include <optional>
#include <algorithm>
#include <vector>

#pragma once


import telar.runtime.traffic.control_protocol;

namespace telar::runtime::traffic_test {

inline std::vector<Byte> tcp(bool ipv6, bool incoming, std::uint32_t sequence, Byte flags, std::string_view body = {}) {
  const auto head = ipv6 ? 40u : 20u;
  std::vector<Byte> bytes(head + 20 + body.size());
  const auto word = [&](std::size_t offset, std::uint16_t value) { bytes[offset] = value >> 8; bytes[offset + 1] = value; };
  if (ipv6) {
    bytes[0] = 0x60; word(4, bytes.size() - 40); bytes[6] = 6;
    bytes[23] = incoming ? 2 : 1; bytes[39] = incoming ? 1 : 2;
  } else {
    bytes[0] = 0x45; word(2, bytes.size()); bytes[9] = 6;
    bytes[15] = incoming ? 2 : 1; bytes[19] = incoming ? 1 : 2;
  }
  word(head, incoming ? 80 : 50000); word(head + 2, incoming ? 50000 : 80);
  word(head + 4, sequence >> 16); word(head + 6, sequence);
  bytes[head + 12] = 0x50; bytes[head + 13] = flags;
  std::ranges::copy(body, bytes.begin() + head + 20);
  return bytes;
}

}
