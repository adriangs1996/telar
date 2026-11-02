#pragma once

#include "protocol.hpp"

namespace telar::runtime::traffic {

class Pcapng {
public:
  static constexpr std::size_t section_bytes = 28;

  static void section(plugins::FrameWriter &writer) {
    writer.integer<std::uint32_t>(0x0a0d0d0a);
    writer.integer<std::uint32_t>(section_bytes);
    writer.integer<std::uint32_t>(0x1a2b3c4d);
    writer.integer<std::uint16_t>(1);
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint64_t>(UINT64_MAX);
    writer.integer<std::uint32_t>(section_bytes);
  }

  static std::size_t packetBytes(const Event &event) { return 20 + 8 + padded(event.interface.size()) + 32 + padded(event.bytes.size()); }

  static void packet(plugins::FrameWriter &writer, const Event &event, std::uint32_t interface) {
    if (event.kind != Kind::packet || event.link_type > UINT16_MAX) { throw EncodingError{"Packet cannot be represented in PCAPNG"}; }
    const auto interface_bytes = static_cast<std::uint32_t>(20 + 8 + padded(event.interface.size()));
    writer.integer<std::uint32_t>(1);
    writer.integer(interface_bytes);
    writer.integer(static_cast<std::uint16_t>(event.link_type));
    writer.integer<std::uint16_t>(0);
    writer.integer<std::uint32_t>(Limits::packet_bytes);
    writer.integer<std::uint16_t>(2);
    writer.integer(static_cast<std::uint16_t>(event.interface.size()));
    raw(writer, {reinterpret_cast<const Byte *>(event.interface.data()), event.interface.size()});
    writer.integer<std::uint32_t>(0);
    writer.integer(interface_bytes);
    const auto packet_bytes = static_cast<std::uint32_t>(32 + padded(event.bytes.size()));
    writer.integer<std::uint32_t>(6);
    writer.integer(packet_bytes);
    writer.integer(interface);
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us >> 32));
    writer.integer(static_cast<std::uint32_t>(event.timestamp_us));
    writer.integer(static_cast<std::uint32_t>(event.bytes.size()));
    writer.integer(event.original_bytes);
    raw(writer, event.bytes);
    writer.integer(packet_bytes);
  }

private:
  static std::size_t padded(std::size_t size) noexcept { return (size + 3) & ~std::size_t{3}; }

  static void raw(plugins::FrameWriter &writer, std::span<const Byte> bytes) {
    writer.append(bytes);
    for (std::size_t index = bytes.size(); index < padded(bytes.size()); ++index) { writer.integer<Byte>(0); }
  }
};

}
