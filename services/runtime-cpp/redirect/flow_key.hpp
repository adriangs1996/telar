#pragma once

#include "target.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <optional>
#include <span>

namespace telar::runtime::redirect {

struct FlowKey {
  Target source;
  Target destination;

  bool matches(const FlowKey &other) const noexcept {
    return same(source, other.source) && same(destination, other.destination);
  }

  static bool same(const Target &left, const Target &right) noexcept {
    return left.port == right.port && left.host.view() == right.host.view();
  }

  static std::optional<FlowKey> syn(std::span<const Byte> frame) {
    if (frame.size() < sizeof(std::uint32_t)) {
      return std::nullopt;
    }
    std::uint32_t encoded_family;
    std::memcpy(&encoded_family, frame.data(), sizeof(encoded_family));
    const auto family = ntohl(encoded_family);
    const auto packet = frame.subspan(sizeof(encoded_family));
    std::size_t offset;
    std::size_t source;
    std::size_t destination;
    if (family == AF_INET && packet.size() >= 20 && packet[0] >> 4 == 4) {
      offset = (packet[0] & 0x0f) * 4;
      if (offset < 20 || offset > packet.size() || number(packet, 2) != packet.size() || (number(packet, 6) & 0x3fff) != 0 || packet[9] != IPPROTO_TCP) {
        return std::nullopt;
      }
      source = 12;
      destination = 16;
    } else if (family == AF_INET6 && packet.size() >= 40 && packet[0] >> 4 == 6) {
      if (number(packet, 4) + 40 != packet.size()) {
        return std::nullopt;
      }
      offset = 40;
      unsigned next = packet[6];
      for (std::size_t count = 0; next != IPPROTO_TCP; ++count) {
        if (count == 8 || offset + 2 > packet.size() || (next != IPPROTO_HOPOPTS && next != IPPROTO_ROUTING && next != IPPROTO_DSTOPTS && next != IPPROTO_AH)) {
          return std::nullopt;
        }
        const auto length = next == IPPROTO_AH ? (packet[offset + 1] + 2) * 4 : (packet[offset + 1] + 1) * 8;
        next = packet[offset];
        offset += static_cast<std::size_t>(length);
      }
      source = 8;
      destination = 24;
    } else {
      return std::nullopt;
    }
    if (offset + 20 > packet.size() || (packet[offset + 13] & 0x17) != 0x02) {
      return std::nullopt;
    }
    const auto header = static_cast<std::size_t>(packet[offset + 12] >> 4) * 4;
    if (header < 20 || header > packet.size() - offset) {
      return std::nullopt;
    }
    try {
      return FlowKey{.source = endpoint(family, packet.subspan(source), number(packet, offset)), .destination = endpoint(family, packet.subspan(destination), number(packet, offset + 2))};
    } catch (const std::invalid_argument &) {
      return std::nullopt;
    }
  }

private:
  static std::uint16_t number(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(static_cast<unsigned>(bytes[offset]) << 8 | bytes[offset + 1]);
  }

  static Target endpoint(unsigned family, std::span<const Byte> bytes, std::uint16_t port) {
    std::array<char, INET6_ADDRSTRLEN> host{};
    if (::inet_ntop(static_cast<int>(family), bytes.data(), host.data(), host.size()) == nullptr) {
      throw std::invalid_argument{"Invalid discovery address"};
    }
    std::array<char, INET6_ADDRSTRLEN + 16> text{};
    std::snprintf(text.data(), text.size(), family == AF_INET6 ? "[%s]:%u" : "%s:%u", host.data(), port);
    return Target::parse(text.data());
  }
};

}
