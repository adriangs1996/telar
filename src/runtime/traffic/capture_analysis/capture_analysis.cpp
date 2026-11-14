module;
#include <pcap/pcap.h>

module telar.runtime.traffic.capture_analysis;

import telar.sys.socket;

namespace telar::runtime::traffic {

  std::uint16_t NetworkPacket::word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>((std::uint16_t{bytes[offset]} << 8) | bytes[offset + 1]);
  }

  std::span<const Byte> NetworkPacket::decode(const Event& event) noexcept {
    auto bytes = event.bytes;

    switch (event.link_type) {
    case DLT_EN10MB: {
      if (bytes.size() < 14) {
        return {};
      }

      auto protocol = word(bytes, 12);

      bytes = bytes.subspan(14);
      for (unsigned depth = 0; protocol == 0x8100 || protocol == 0x88a8; ++depth) {
        if (depth == 2 || bytes.size() < 4) {
          return {};
        }

        protocol = word(bytes, 2);
        bytes = bytes.subspan(4);
      }

      if (protocol != 0x0800 && protocol != 0x86dd) {
        return {};
      }

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
    default:
      return {};
    }
  }

  std::array<char, INET6_ADDRSTRLEN> IpPayload::addressText(const std::array<Byte, 16>& address, bool ipv6) noexcept {
    std::array<char, INET6_ADDRSTRLEN> text{};

    ::inet_ntop(ipv6 ? AF_INET6 : AF_INET, address.data(), text.data(), text.size());
    return text;
  }

  std::optional<IpPayload> IpPayload::decode(std::span<const Byte> bytes) noexcept {
    if (bytes.empty()) {
      return {};
    }

    IpPayload result;

    if ((bytes[0] >> 4) == 4) {
      if (bytes.size() < 20 || (NetworkPacket::word(bytes, 6) & 0x3fff) != 0) {
        return {};
      }

      const auto head = std::size_t{bytes[0] & 15u} * 4;
      const auto length = NetworkPacket::word(bytes, 2);
      if (head < 20 || length < head || bytes.size() < head) {
        return {};
      }

      result.truncated = bytes.size() < length;
      result.protocol = bytes[9];
      result.original_bytes = length - head;
      std::ranges::copy(bytes.subspan(12, 4), result.source.begin());
      std::ranges::copy(bytes.subspan(16, 4), result.destination.begin());
      result.bytes = bytes.first(std::min(bytes.size(), std::size_t{length})).subspan(head);
    } else if ((bytes[0] >> 4) == 6) {
      if (bytes.size() < 40 || NetworkPacket::word(bytes, 4) == 0) {
        return {};
      }

      result.ipv6 = true;
      std::ranges::copy(bytes.subspan(8, 16), result.source.begin());
      std::ranges::copy(bytes.subspan(24, 16), result.destination.begin());
      const auto length = std::size_t{NetworkPacket::word(bytes, 4)} + 40;

      result.truncated = bytes.size() < length;
      result.protocol = bytes[6];
      bytes = bytes.first(std::min(bytes.size(), length)).subspan(40);
      result.original_bytes = length - 40;
      for (unsigned depth = 0; result.protocol == 0 || result.protocol == 43 || result.protocol == 60 || result.protocol == 51; ++depth) {
        if (depth == 8 || bytes.size() < 2) {
          return {};
        }

        const auto head = result.protocol == 51 ? (std::size_t{bytes[1]} + 2) * 4 : (std::size_t{bytes[1]} + 1) * 8;
        if (head > bytes.size()) {
          return {};
        }

        result.protocol = bytes[0];
        bytes = bytes.subspan(head);
        result.original_bytes -= head;
      }

      result.bytes = bytes;
    } else {
      return {};
    }

    return result;
  }

  bool DatagramEvent::echo() const noexcept {
    return transport != DatagramTransport::udp && icmp_code == 0 && bytes.size() >= 8 && (transport == DatagramTransport::icmp ? icmp_type == 0 || icmp_type == 8 : icmp_type == 128 || icmp_type == 129);
  }

  std::string_view DatagramCodec::name(DatagramTransport transport) noexcept {
    constexpr std::array names{std::string_view{"udp"}, std::string_view{"icmp"}, std::string_view{"icmpv6"}};

    return names[static_cast<std::size_t>(transport)];
  }

  tbc::view<std::span<const Byte>, tbc::lt::a> DatagramCodec::encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const DatagramEvent& event) {
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

  DatagramEvent DatagramCodec::decode(std::span<const Byte> input) {
    plugins::FrameReader reader{input};
    DatagramEvent event;

    event.transport = reader.tag(DatagramTransport::icmpv6);
    event.ipv6 = reader.boolean();
    const auto source = reader.bytes();
    const auto destination = reader.bytes();
    if (source.size() != event.source_address.size() || destination.size() != event.destination_address.size()) {
      throw EncodingError{"Invalid datagram address length"};
    }

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

  std::optional<DatagramEvent> DatagramCodec::parse(const IpPayload& ip) noexcept {
    DatagramEvent event{.ipv6 = ip.ipv6, .source_address = ip.source, .destination_address = ip.destination};

    if (ip.protocol == IPPROTO_UDP) {
      if (ip.bytes.size() < 8) {
        return {};
      }

      const auto length = NetworkPacket::word(ip.bytes, 4);
      if (length < 8 || length > ip.original_bytes) {
        return {};
      }

      event.source_port = NetworkPacket::word(ip.bytes, 0);
      event.destination_port = NetworkPacket::word(ip.bytes, 2);
      event.original_bytes = length - 8;
      event.bytes = ip.bytes.first(std::min(ip.bytes.size(), std::size_t{length})).subspan(8);
    } else if ((!ip.ipv6 && ip.protocol == IPPROTO_ICMP) || (ip.ipv6 && ip.protocol == IPPROTO_ICMPV6)) {
      if (ip.bytes.size() < 4) {
        return {};
      }

      event.transport = ip.ipv6 ? DatagramTransport::icmpv6 : DatagramTransport::icmp;
      event.icmp_type = ip.bytes[0];
      event.icmp_code = ip.bytes[1];
      event.original_bytes = static_cast<std::uint32_t>(ip.original_bytes);
      event.bytes = ip.bytes;
    } else {
      return {};
    }

    event.truncated = event.bytes.size() < event.original_bytes;
    return event;
  }

  void DatagramCodec::validate(const DatagramEvent& event) {
    if (static_cast<Byte>(event.transport) > static_cast<Byte>(DatagramTransport::icmpv6) || event.original_bytes > std::numeric_limits<std::uint16_t>::max() || event.bytes.size() > event.original_bytes || event.truncated != (event.bytes.size() < event.original_bytes) || (event.transport == DatagramTransport::icmp && event.ipv6) || (event.transport == DatagramTransport::icmpv6 && !event.ipv6)) {
      throw EncodingError{"Invalid datagram metadata"};
    }

    if (!event.ipv6 && (std::ranges::any_of(std::span{event.source_address}.subspan(4), [](Byte value) {
          return value != 0;
        }) || std::ranges::any_of(std::span{event.destination_address}.subspan(4), [](Byte value) {
          return value != 0;
        }))) {
      throw EncodingError{"Invalid IPv4 datagram address padding"};
    }

    if (event.transport != DatagramTransport::udp && (event.bytes.size() < 4 || event.bytes[0] != event.icmp_type || event.bytes[1] != event.icmp_code || event.source_port != 0 || event.destination_port != 0)) {
      throw EncodingError{"Invalid ICMP message metadata"};
    }
  }

  IpFragments::IpFragments(ConcurrentMemory& memory) noexcept
      : memory_(memory) {}

  auto IpFragments::parse(std::span<const Byte> bytes) noexcept -> std::optional<Fragment> {
    if (bytes.empty()) {
      return {};
    }

    Fragment part;

    if ((bytes[0] >> 4) == 4) {
      if (bytes.size() < 20 || (NetworkPacket::word(bytes, 6) & 0x3fff) == 0) {
        return {};
      }

      const auto flags = NetworkPacket::word(bytes, 6);

      part.offset = std::size_t{flags & 0x1fffu} * 8;
      part.more = (flags & 0x2000) != 0;
      part.key.identification = NetworkPacket::word(bytes, 4);
      part.key.protocol = bytes[9];
      std::copy_n(bytes.begin() + 12, 8, part.key.addresses.begin());
      const auto head = std::size_t{bytes[0] & 15u} * 4;
      const auto length = NetworkPacket::word(bytes, 2);
      if (head < 20 || head > bytes.size() || length <= head || length > bytes.size() || (flags & 0xc000) != 0) {
        part.error = "ip_fragment_invalid_or_truncated";
        return part;
      }

      part.prefix = bytes.first(head);
      part.payload = bytes.subspan(head, length - head);
    } else if ((bytes[0] >> 4) == 6) {
      if (bytes.size() < 40) {
        return {};
      }

      const auto length = std::size_t{NetworkPacket::word(bytes, 4)} + 40;
      auto protocol = bytes[6];
      std::size_t offset = 40;

      part.previous_header = 6;
      for (unsigned depth = 0; protocol != 44; ++depth) {
        if (depth == 8 || offset > bytes.size() || bytes.size() - offset < 2 || (protocol != 0 && protocol != 43 && protocol != 60 && protocol != 51)) {
          return {};
        }

        const auto head = protocol == 51 ? (std::size_t{bytes[offset + 1]} + 2) * 4 : (std::size_t{bytes[offset + 1]} + 1) * 8;

        part.previous_header = offset;
        protocol = bytes[offset];
        offset += head;
      }

      part.key.ipv6 = true;
      if (offset > bytes.size() || bytes.size() - offset < 8 || length > bytes.size() || length <= offset + 8 || offset > maximum_prefix) {
        part.error = "ip_fragment_invalid_or_truncated";
        return part;
      }

      std::copy_n(bytes.begin() + 8, 32, part.key.addresses.begin());
      part.key.identification = (std::uint32_t{NetworkPacket::word(bytes, offset + 4)} << 16) | NetworkPacket::word(bytes, offset + 6);
      const auto flags = NetworkPacket::word(bytes, offset + 2);

      part.offset = flags & 0xfff8u;
      part.more = (flags & 1) != 0;
      part.next_header = bytes[offset];
      part.prefix = bytes.first(offset);
      part.payload = bytes.subspan(offset + 8, length - offset - 8);
    } else {
      return {};
    }

    if ((part.more && part.payload.size() % 8 != 0) || part.offset + part.payload.size() > maximum_payload) {
      part.error = "ip_fragment_size_limit";
    }

    return part;
  }

  void IpFragments::initialize(Entry& entry, Event event, const Key& key) noexcept {
    entry.key = key;
    event.bytes = {};
    event.interface = {};
    entry.event = event;
    entry.created = Clock::now();
  }

  tbc::view<std::string_view, tbc::lt::static_storage> IpFragments::append(Entry& entry, const Fragment& part) {
    const auto end = part.offset + part.payload.size();
    if (entry.length && (end > *entry.length || (!part.more && end != *entry.length))) {
      return "ip_fragment_conflicting_length";
    }

    for (const auto& range : std::span{entry.ranges}.first(entry.count)) {
      if (range.offset == part.offset && range.size == part.payload.size() && range.more == part.more && std::ranges::equal(entry.storage->bytes().subspan(maximum_prefix + part.offset, range.size), part.payload)) {
        if (part.offset == 0 && (entry.prefix != part.prefix.size() || (part.key.ipv6 && entry.next_header != part.next_header))) {
          return "ip_fragment_overlap";
        }

        return {};
      }

      if (part.offset < range.offset + range.size && range.offset < end) {
        return "ip_fragment_overlap";
      }

      if (!part.more && range.offset + range.size > end) {
        return "ip_fragment_conflicting_length";
      }
    }

    if (entry.count == entry.ranges.size()) {
      return "ip_fragment_piece_limit";
    }

    if (part.offset == 0) {
      entry.prefix = part.prefix.size();
      entry.next_header = part.next_header;
      std::ranges::copy(part.prefix, entry.storage->bytes().begin() + maximum_prefix - entry.prefix);
      if (part.key.ipv6) {
        entry.storage->bytes()[maximum_prefix - entry.prefix + part.previous_header] = part.next_header;
      }
    }

    std::ranges::copy(part.payload, entry.storage->bytes().begin() + maximum_prefix + part.offset);
    entry.ranges[entry.count++] = {part.offset, part.payload.size(), part.more};
    entry.received += part.payload.size();
    if (!part.more) {
      entry.length = end;
    }

    if (entry.prefix != 0 && entry.length && entry.prefix - (entry.key.ipv6 ? 40 : 0) + *entry.length > std::numeric_limits<std::uint16_t>::max()) {
      return "ip_fragment_size_limit";
    }

    return {};
  }

  std::span<const Byte> IpFragments::assembled(Entry& entry) {
    auto bytes = entry.storage->bytes().subspan(maximum_prefix - entry.prefix, entry.prefix + *entry.length);
    const auto length = bytes.size() - (entry.key.ipv6 ? 40 : 0);
    const auto offset = entry.key.ipv6 ? 4u : 2u;

    bytes[offset] = static_cast<Byte>(length >> 8);
    bytes[offset + 1] = static_cast<Byte>(length);
    if (!entry.key.ipv6) {
      bytes[6] = bytes[7] = bytes[10] = bytes[11] = 0;
      std::uint32_t sum = 0;

      for (std::size_t index = 0; index < entry.prefix; index += 2) {
        sum += NetworkPacket::word(bytes, index);
      }

      while (sum >> 16) {
        sum = (sum & std::numeric_limits<std::uint16_t>::max()) + (sum >> 16);
      }

      const auto checksum = static_cast<std::uint16_t>(~sum);

      bytes[10] = static_cast<Byte>(checksum >> 8);
      bytes[11] = static_cast<Byte>(checksum);
    }

    return bytes;
  }

  std::string TcpEndpoint::text() const {
    const auto host = IpPayload::addressText(address, ipv6);

    return (ipv6 ? "[" + std::string{host.data()} + "]:" : std::string{host.data()} + ":") + std::to_string(port);
  }

  std::uint16_t TcpPacketDecoder::word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return NetworkPacket::word(bytes, offset);
  }

  std::optional<TcpPacket> TcpPacketDecoder::decode(const Event& event) noexcept {
    return decodeNetwork(NetworkPacket::decode(event));
  }

  std::optional<TcpPacket> TcpPacketDecoder::decodeNetwork(std::span<const Byte> bytes) noexcept {
    const auto ip = IpPayload::decode(bytes);

    return ip ? decodePayload(*ip) : std::nullopt;
  }

  tbc::view<std::optional<TcpPacket>, tbc::lt::a> TcpPacketDecoder::decodePayload(const IpPayload& ip) noexcept {
    if (ip.protocol != IPPROTO_TCP) {
      return {};
    }

    TcpPacket packet;

    packet.source.address = ip.source;
    packet.destination.address = ip.destination;
    packet.source.ipv6 = packet.destination.ipv6 = ip.ipv6;
    packet.truncated = ip.truncated;
    auto bytes = ip.bytes;
    if (bytes.size() < 20) {
      return {};
    }

    const auto head = static_cast<std::size_t>(bytes[12] >> 4) * 4;
    if (head < 20 || head > bytes.size()) {
      return {};
    }

    packet.source.port = word(bytes, 0);
    packet.destination.port = word(bytes, 2);
    packet.sequence = (std::uint32_t{word(bytes, 4)} << 16) | word(bytes, 6);
    packet.flags = bytes[13];
    packet.bytes = bytes.subspan(head);
    return packet;
  }

  std::size_t TcpFlows::Hash::operator()(const Key& key) const noexcept {
    std::size_t hash = key.session;
    auto add = [&](unsigned value) {
      hash = (hash ^ value) * 1099511628211ull;
    };

    add(key.interface);
    for (const auto c : key.name) {
      add(static_cast<unsigned char>(c));
    }

    for (const auto* endpoint : {&key.first, &key.second}) {
      for (const auto byte : endpoint->address) {
        add(byte);
      }

      add(endpoint->port);
      add(endpoint->ipv6);
    }

    return hash;
  }

  TcpFlows::Side::Side(Secure& memory)
      : pending(AllocatorRef<Segment, Secure>{memory}) {}

  TcpFlows::Flow::Flow(Secure& memory, std::uint64_t id, bool reverse, bool offline)
      : id(id),
        reverse(reverse),
        offline(offline),
        outbound(memory),
        inbound(memory) {}

  TcpFlows::TcpFlows(ConcurrentMemory& memory)
      : memory_(memory),
        flows_(0, Hash{}, std::equal_to<Key>{}, AllocatorRef<Entry, Secure>{memory_}) {}

  std::int32_t TcpFlows::distance(std::uint32_t a, std::uint32_t b) noexcept {
    return std::bit_cast<std::int32_t>(a - b);
  }

  CaptureAnalysis::CaptureAnalysis(ConcurrentMemory& memory)
      : memory_(memory),
        fragments_(memory),
        tcp_(memory) {}

}
