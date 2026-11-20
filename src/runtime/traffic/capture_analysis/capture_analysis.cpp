module telar.runtime.traffic.capture_analysis;

import telar.native.pcap;
import telar.sys.socket;
import telar.runtime.vocabulary.frames;
import telar.base.text.utf8;
import telar.base.ds;

namespace telar::runtime::traffic {
  namespace {

    constexpr unsigned byte_bits = 8;
    constexpr unsigned word_bits = 16;

    // Ethernet framing: its header, where the EtherType sits, and the VLAN tags that may come first.
    constexpr std::size_t ethernet_header_bytes = 14;
    constexpr std::size_t ether_type_offset = 12;
    constexpr std::uint16_t vlan_tag = 0x8100;
    constexpr std::uint16_t provider_vlan_tag = 0x88a8;
    constexpr std::size_t vlan_tag_bytes = 4;
    constexpr unsigned maximum_vlan_tags = 2;
    constexpr std::uint16_t ipv4_ether_type = 0x0800;
    constexpr std::uint16_t ipv6_ether_type = 0x86dd;

    // The link headers of loopback and Linux cooked captures.
    constexpr std::size_t loopback_header_bytes = 4;
    constexpr std::size_t cooked_header_bytes = 16;
    constexpr std::size_t cooked_v2_header_bytes = 20;

    // The IP version is the high nibble of a packet's first byte, and IPv4's header length in words the low one.
    constexpr unsigned high_nibble_shift = 4;
    constexpr unsigned ipv4_version = 4;
    constexpr unsigned ipv6_version = 6;
    constexpr unsigned header_length_bits = 0x0f;
    constexpr std::size_t header_word_bytes = 4;

    // IPv4 header fields.
    constexpr std::size_t ipv4_header_bytes = 20;
    constexpr std::size_t ipv4_length_offset = 2;
    constexpr std::size_t ipv4_identification_offset = 4;
    constexpr std::size_t ipv4_flags_offset = 6;
    constexpr std::size_t ipv4_protocol_offset = 9;
    constexpr std::size_t ipv4_checksum_offset = 10;
    constexpr std::size_t ipv4_source_offset = 12;
    constexpr std::size_t ipv4_destination_offset = 16;
    constexpr std::size_t ipv4_address_bytes = 4;
    constexpr unsigned ipv4_fragment_bits = 0x3fff;
    constexpr unsigned ipv4_fragment_offset_bits = 0x1fff;
    constexpr unsigned ipv4_more_fragments = 0x2000;
    constexpr unsigned ipv4_forbidden_fragment_flags = 0xc000;

    // IPv6 header fields, its extension headers, and the fragment header that ends them.
    constexpr std::size_t ipv6_header_bytes = 40;
    constexpr std::size_t ipv6_length_offset = 4;
    constexpr std::size_t ipv6_next_header_offset = 6;
    constexpr std::size_t ipv6_source_offset = 8;
    constexpr std::size_t ipv6_destination_offset = 24;
    constexpr Byte hop_by_hop_options = 0;
    constexpr Byte routing_header = 43;
    constexpr Byte fragment_header = 44;
    constexpr Byte authentication_header = 51;
    constexpr Byte destination_options = 60;
    constexpr unsigned maximum_extension_headers = 8;
    constexpr std::size_t extension_unit_bytes = 8;
    constexpr std::size_t fragment_header_bytes = 8;
    constexpr std::size_t fragment_flags_offset = 2;
    constexpr std::size_t fragment_identification_offset = 4;
    constexpr unsigned ipv6_fragment_offset_bits = 0xfff8;
    constexpr unsigned ipv6_more_fragments = 1;

    // Fragment offsets count units of eight bytes.
    constexpr std::size_t fragment_unit_bytes = 8;

    // UDP and ICMP headers, and the ICMP echo messages.
    constexpr std::size_t udp_header_bytes = 8;
    constexpr std::size_t icmp_echo_bytes = 8;
    constexpr Byte icmp_echo_reply = 0;
    constexpr Byte icmp_echo_request = 8;
    constexpr Byte icmpv6_echo_request = 128;
    constexpr Byte icmpv6_echo_reply = 129;

    // TCP header fields.
    constexpr std::size_t tcp_header_bytes = 20;
    constexpr std::size_t tcp_sequence_offset = 4;
    constexpr std::size_t tcp_data_offset_offset = 12;
    constexpr std::size_t tcp_flags_offset = 13;

    constexpr std::uint64_t fnv_prime = 1099511628211ULL;

    unsigned ipVersion(std::span<const Byte> bytes) noexcept {
      return unsigned{bytes[0]} >> high_nibble_shift;
    }

    bool isExtension(Byte protocol) noexcept {
      return protocol == hop_by_hop_options || protocol == routing_header || protocol == destination_options || protocol == authentication_header;
    }

    // The bytes of the extension header the given bytes start with: an authentication header counts
    // words of four bytes past the first two, the others units of eight past the first.
    std::size_t extensionBytes(Byte protocol, std::span<const Byte> header) noexcept {
      return protocol == authentication_header ? (std::size_t{header[1]} + 2) * header_word_bytes : (std::size_t{header[1]} + 1) * extension_unit_bytes;
    }

    // Where the fragment header of an IPv6 packet starts, past its extension headers, and the offset of
    // the next-header field that names it.
    struct FragmentHeader {
      std::size_t offset = ipv6_header_bytes;
      std::size_t previous_header = ipv6_next_header_offset;
    };

    ds::Option<FragmentHeader> fragmentHeader(std::span<const Byte> bytes) noexcept {
      auto protocol = bytes[ipv6_next_header_offset];
      FragmentHeader header;

      for (unsigned depth = 0; protocol != fragment_header; ++depth) {
        if (depth == maximum_extension_headers || header.offset > bytes.size() || bytes.size() - header.offset < 2 || !isExtension(protocol)) {
          return {};
        }

        const auto head = extensionBytes(protocol, bytes.subspan(header.offset));

        header.previous_header = header.offset;
        protocol = bytes[header.offset];
        header.offset += head;
      }

      return header;
    }

    tbc::val_a<std::span<const Byte>> linkPayload(tbc::val_a<std::span<const Byte>> bytes, std::size_t header) noexcept {
      return bytes.size() < header ? std::span<const Byte>{} : bytes.subspan(header);
    }

    tbc::val_a<std::span<const Byte>> ethernetPayload(tbc::val_a<std::span<const Byte>> bytes) noexcept {
      if (bytes.size() < ethernet_header_bytes) {
        return {};
      }

      auto protocol = NetworkPacket::word(bytes, ether_type_offset);

      bytes = bytes.subspan(ethernet_header_bytes);
      for (unsigned depth = 0; protocol == vlan_tag || protocol == provider_vlan_tag; ++depth) {
        if (depth == maximum_vlan_tags || bytes.size() < vlan_tag_bytes) {
          return {};
        }

        protocol = NetworkPacket::word(bytes, 2);
        bytes = bytes.subspan(vlan_tag_bytes);
      }

      if (protocol != ipv4_ether_type && protocol != ipv6_ether_type) {
        return {};
      }

      return bytes;
    }

  }

  std::uint16_t NetworkPacket::word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>((unsigned{bytes[offset]} << byte_bits) | bytes[offset + 1]);
  }

  std::span<const Byte> NetworkPacket::decode(const Event& event) noexcept {
    switch (event.link_type) {
    case DLT_EN10MB:
      return ethernetPayload(event.bytes);
    case DLT_NULL:
    case DLT_LOOP:
      return linkPayload(event.bytes, loopback_header_bytes);
    case DLT_LINUX_SLL:
      return linkPayload(event.bytes, cooked_header_bytes);
    case DLT_LINUX_SLL2:
      return linkPayload(event.bytes, cooked_v2_header_bytes);
    case DLT_RAW:
    case DLT_IPV4:
    case DLT_IPV6:
      return event.bytes;
    default:
      return {};
    }
  }

  ds::Array<char, INET6_ADDRSTRLEN> IpPayload::addressText(const ds::Array<Byte, address_bytes>& address, bool ipv6) noexcept {
    ds::Array<char, INET6_ADDRSTRLEN> text{};

    ::inet_ntop(ipv6 ? AF_INET6 : AF_INET, address.data(), text.dataMut(), text.size());
    return text;
  }

  ds::Option<IpPayload> IpPayload::decode(std::span<const Byte> bytes) noexcept {
    if (bytes.empty()) {
      return {};
    }

    IpPayload result;

    if (ipVersion(bytes) == ipv4_version) {
      if (bytes.size() < ipv4_header_bytes || (NetworkPacket::word(bytes, ipv4_flags_offset) & ipv4_fragment_bits) != 0) {
        return {};
      }

      const auto head = std::size_t{bytes[0] & header_length_bits} * header_word_bytes;
      const auto length = NetworkPacket::word(bytes, ipv4_length_offset);
      if (head < ipv4_header_bytes || length < head || bytes.size() < head) {
        return {};
      }

      result.truncated = bytes.size() < length;
      result.protocol = bytes[ipv4_protocol_offset];
      result.original_bytes = length - head;
      std::ranges::copy(bytes.subspan(ipv4_source_offset, ipv4_address_bytes), result.source.viewMut().begin());
      std::ranges::copy(bytes.subspan(ipv4_destination_offset, ipv4_address_bytes), result.destination.viewMut().begin());
      result.bytes = bytes.first(std::min(bytes.size(), std::size_t{length})).subspan(head);
    } else if (ipVersion(bytes) == ipv6_version) {
      if (bytes.size() < ipv6_header_bytes || NetworkPacket::word(bytes, ipv6_length_offset) == 0) {
        return {};
      }

      result.ipv6 = true;
      std::ranges::copy(bytes.subspan(ipv6_source_offset, address_bytes), result.source.viewMut().begin());
      std::ranges::copy(bytes.subspan(ipv6_destination_offset, address_bytes), result.destination.viewMut().begin());
      const auto length = std::size_t{NetworkPacket::word(bytes, ipv6_length_offset)} + ipv6_header_bytes;

      result.truncated = bytes.size() < length;
      result.protocol = bytes[ipv6_next_header_offset];
      bytes = bytes.first(std::min(bytes.size(), length)).subspan(ipv6_header_bytes);
      result.original_bytes = length - ipv6_header_bytes;
      for (unsigned depth = 0; isExtension(result.protocol); ++depth) {
        if (depth == maximum_extension_headers || bytes.size() < 2) {
          return {};
        }

        const auto head = extensionBytes(result.protocol, bytes);
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
    return transport != DatagramTransport::udp && icmp_code == 0 && bytes.size() >= icmp_echo_bytes && (transport == DatagramTransport::icmp ? icmp_type == icmp_echo_reply || icmp_type == icmp_echo_request : icmp_type == icmpv6_echo_request || icmp_type == icmpv6_echo_reply);
  }

  std::string_view DatagramCodec::name(DatagramTransport transport) noexcept {
    constexpr ds::Array names{std::string_view{"udp"}, std::string_view{"icmp"}, std::string_view{"icmpv6"}};

    return names[static_cast<std::size_t>(transport)];
  }

  tbc::val_a<std::span<const Byte>> DatagramCodec::encode(tbc::val_a<std::span<Byte>> output, const DatagramEvent& event) {
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

    std::ranges::copy(source, event.source_address.viewMut().begin());
    std::ranges::copy(destination, event.destination_address.viewMut().begin());
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

  ds::Option<DatagramEvent> DatagramCodec::parse(const IpPayload& payload) noexcept {
    DatagramEvent event{.ipv6 = payload.ipv6, .source_address = payload.source, .destination_address = payload.destination};

    if (payload.protocol == IPPROTO_UDP) {
      if (payload.bytes.size() < udp_header_bytes) {
        return {};
      }

      const auto length = NetworkPacket::word(payload.bytes, 4);
      if (length < udp_header_bytes || length > payload.original_bytes) {
        return {};
      }

      event.source_port = NetworkPacket::word(payload.bytes, 0);
      event.destination_port = NetworkPacket::word(payload.bytes, 2);
      event.original_bytes = length - udp_header_bytes;
      event.bytes = payload.bytes.first(std::min(payload.bytes.size(), std::size_t{length})).subspan(udp_header_bytes);
    } else if ((!payload.ipv6 && payload.protocol == IPPROTO_ICMP) || (payload.ipv6 && payload.protocol == IPPROTO_ICMPV6)) {
      if (payload.bytes.size() < 4) {
        return {};
      }

      event.transport = payload.ipv6 ? DatagramTransport::icmpv6 : DatagramTransport::icmp;
      event.icmp_type = payload.bytes[0];
      event.icmp_code = payload.bytes[1];
      event.original_bytes = static_cast<std::uint32_t>(payload.original_bytes);
      event.bytes = payload.bytes;
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

  auto IpFragments::parse(std::span<const Byte> bytes) noexcept -> ds::Option<Fragment> {
    if (bytes.empty()) {
      return {};
    }

    Fragment part;

    if (ipVersion(bytes) == ipv4_version) {
      if (bytes.size() < ipv4_header_bytes || (NetworkPacket::word(bytes, ipv4_flags_offset) & ipv4_fragment_bits) == 0) {
        return {};
      }

      const auto flags = NetworkPacket::word(bytes, ipv4_flags_offset);

      part.offset = std::size_t{flags & ipv4_fragment_offset_bits} * fragment_unit_bytes;
      part.more = (flags & ipv4_more_fragments) != 0;
      part.key.identification = NetworkPacket::word(bytes, ipv4_identification_offset);
      part.key.protocol = bytes[ipv4_protocol_offset];
      std::copy_n(bytes.begin() + ipv4_source_offset, 2 * ipv4_address_bytes, part.key.addresses.dataMut());
      const auto head = std::size_t{bytes[0] & header_length_bits} * header_word_bytes;
      const auto length = NetworkPacket::word(bytes, ipv4_length_offset);
      if (head < ipv4_header_bytes || head > bytes.size() || length <= head || length > bytes.size() || (flags & ipv4_forbidden_fragment_flags) != 0) {
        part.error = "ip_fragment_invalid_or_truncated";
        return part;
      }

      part.prefix = bytes.first(head);
      part.payload = bytes.subspan(head, length - head);
    } else if (ipVersion(bytes) == ipv6_version) {
      if (bytes.size() < ipv6_header_bytes) {
        return {};
      }

      const auto length = std::size_t{NetworkPacket::word(bytes, ipv6_length_offset)} + ipv6_header_bytes;
      const auto header = fragmentHeader(bytes);
      if (!header) {
        return {};
      }

      const auto offset = header->offset;

      part.previous_header = header->previous_header;
      part.key.ipv6 = true;
      if (offset > bytes.size() || bytes.size() - offset < fragment_header_bytes || length > bytes.size() || length <= offset + fragment_header_bytes || offset > maximum_prefix) {
        part.error = "ip_fragment_invalid_or_truncated";
        return part;
      }

      const auto identification = offset + fragment_identification_offset;

      std::copy_n(bytes.begin() + ipv6_source_offset, 2 * IpPayload::address_bytes, part.key.addresses.dataMut());
      part.key.identification = (std::uint32_t{NetworkPacket::word(bytes, identification)} << word_bits) | NetworkPacket::word(bytes, identification + 2);
      const auto flags = NetworkPacket::word(bytes, offset + fragment_flags_offset);

      part.offset = flags & ipv6_fragment_offset_bits;
      part.more = (flags & ipv6_more_fragments) != 0;
      part.next_header = bytes[offset];
      part.prefix = bytes.first(offset);
      part.payload = bytes.subspan(offset + fragment_header_bytes, length - offset - fragment_header_bytes);
    } else {
      return {};
    }

    if ((part.more && part.payload.size() % fragment_unit_bytes != 0) || part.offset + part.payload.size() > maximum_payload) {
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

  tbc::val_static<std::string_view> IpFragments::append(Entry& entry, const Fragment& part) {
    const auto end = part.offset + part.payload.size();
    if (entry.length && (end > *entry.length || (!part.more && end != *entry.length))) {
      return "ip_fragment_conflicting_length";
    }

    for (const auto& range : std::span{entry.ranges}.first(entry.count)) {
      if (range.offset == part.offset && range.size == part.payload.size() && range.more == part.more && std::ranges::equal(entry.storage.getMut().bytesMut().subspan(maximum_prefix + part.offset, range.size), part.payload)) {
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

    store(entry, part);
    entry.ranges.atMut(entry.count++) = {.offset = part.offset, .size = part.payload.size(), .more = part.more};
    entry.received += part.payload.size();
    if (!part.more) {
      entry.length = end;
    }

    if (entry.prefix != 0 && entry.length && entry.prefix - (entry.key.ipv6 ? ipv6_header_bytes : 0) + *entry.length > std::numeric_limits<std::uint16_t>::max()) {
      return "ip_fragment_size_limit";
    }

    return {};
  }

  void IpFragments::store(Entry& entry, const Fragment& part) {
    const auto storage = entry.storage.getMut().bytesMut();

    if (part.offset == 0) {
      entry.prefix = part.prefix.size();
      entry.next_header = part.next_header;
      std::ranges::copy(part.prefix, storage.subspan(maximum_prefix - entry.prefix).begin());
      if (part.key.ipv6) {
        storage[maximum_prefix - entry.prefix + part.previous_header] = part.next_header;
      }
    }

    std::ranges::copy(part.payload, storage.subspan(maximum_prefix + part.offset).begin());
  }

  std::span<const Byte> IpFragments::assembled(Entry& entry) {
    auto bytes = entry.storage.getMut().bytesMut().subspan(maximum_prefix - entry.prefix, entry.prefix + *entry.length);
    const auto length = bytes.size() - (entry.key.ipv6 ? ipv6_header_bytes : 0);
    const auto offset = entry.key.ipv6 ? ipv6_length_offset : ipv4_length_offset;

    bytes[offset] = static_cast<Byte>(length >> byte_bits);
    bytes[offset + 1] = static_cast<Byte>(length);
    if (!entry.key.ipv6) {
      bytes[ipv4_flags_offset] = bytes[ipv4_flags_offset + 1] = bytes[ipv4_checksum_offset] = bytes[ipv4_checksum_offset + 1] = 0;
      std::uint32_t sum = 0;

      for (std::size_t index = 0; index < entry.prefix; index += 2) {
        sum += NetworkPacket::word(bytes, index);
      }

      while ((sum >> word_bits) != 0U) {
        sum = (sum & std::numeric_limits<std::uint16_t>::max()) + (sum >> word_bits);
      }

      const auto checksum = static_cast<std::uint16_t>(~sum);

      bytes[ipv4_checksum_offset] = static_cast<Byte>(checksum >> byte_bits);
      bytes[ipv4_checksum_offset + 1] = static_cast<Byte>(checksum);
    }

    return bytes;
  }

  FixedText<TcpEndpoint::text_bytes> TcpEndpoint::text() const {
    const auto host = IpPayload::addressText(address, ipv6);
    const std::string_view name{host.data()};
    ds::Array<char, text_bytes> buffer; // NOLINT(cppcoreguidelines-pro-type-member-init): every flow event formats two endpoints, and only what format_to_n writes is read
    const auto written = ipv6 ? std::format_to_n(buffer.dataMut(), buffer.size(), "[{}]:{}", name, port) : std::format_to_n(buffer.dataMut(), buffer.size(), "{}:{}", name, port);
    FixedText<text_bytes> text;

    text.assign({buffer.data(), static_cast<std::size_t>(written.out - buffer.data())});
    return text;
  }

  std::uint16_t TcpPacketDecoder::word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return NetworkPacket::word(bytes, offset);
  }

  ds::Option<TcpPacket> TcpPacketDecoder::decode(const Event& event) noexcept {
    return decodeNetwork(NetworkPacket::decode(event));
  }

  ds::Option<TcpPacket> TcpPacketDecoder::decodeNetwork(std::span<const Byte> bytes) noexcept {
    const auto payload = IpPayload::decode(bytes);

    return payload ? decodePayload(*payload) : ds::none;
  }

  tbc::val_a<ds::Option<TcpPacket>> TcpPacketDecoder::decodePayload(const IpPayload& payload) noexcept {
    if (payload.protocol != IPPROTO_TCP) {
      return {};
    }

    TcpPacket packet;

    packet.source.address = payload.source;
    packet.destination.address = payload.destination;
    packet.source.ipv6 = packet.destination.ipv6 = payload.ipv6;
    packet.truncated = payload.truncated;
    const auto bytes = payload.bytes;
    if (bytes.size() < tcp_header_bytes) {
      return {};
    }

    const auto head = static_cast<std::size_t>(unsigned{bytes[tcp_data_offset_offset]} >> high_nibble_shift) * header_word_bytes;
    if (head < tcp_header_bytes || head > bytes.size()) {
      return {};
    }

    packet.source.port = word(bytes, 0);
    packet.destination.port = word(bytes, 2);
    packet.sequence = (std::uint32_t{word(bytes, tcp_sequence_offset)} << word_bits) | word(bytes, tcp_sequence_offset + 2);
    packet.flags = bytes[tcp_flags_offset];
    packet.bytes = bytes.subspan(head);
    return packet;
  }

  std::uint64_t TcpFlows::Hash::operator()(const Key& key) const noexcept {
    std::size_t hash = key.session;
    const auto add = [&](unsigned value) {
      hash = (hash ^ value) * fnv_prime;
    };

    add(key.interface);
    for (const auto character : key.name) {
      add(static_cast<unsigned char>(character));
    }

    for (const auto* endpoint : {&key.first, &key.second}) {
      for (const auto byte : endpoint->address) {
        add(byte);
      }

      add(endpoint->port);
      add(static_cast<unsigned int>(endpoint->ipv6));
    }

    // The table reads the low bits of the hash and the high ones apart, so every bit is mixed.
    return ds::Hash{}(static_cast<std::uint64_t>(hash));
  }

  TcpFlows::Side::Side(Secure& memory)
      : pending(memory) {}

  TcpFlows::Flow::Flow(Secure& memory, std::uint64_t flow_id, bool reversed, bool replayed)
      : id(flow_id),
        reverse(reversed),
        offline(replayed),
        outbound(memory),
        inbound(memory) {}

  TcpFlows::TcpFlows(ConcurrentMemory& memory)
      : memory_(memory),
        flows_(memory_) {}

  std::int32_t TcpFlows::distance(std::uint32_t a, std::uint32_t b) noexcept {
    return std::bit_cast<std::int32_t>(a - b);
  }

  CaptureAnalysis::CaptureAnalysis(ConcurrentMemory& memory)
      : memory_(memory),
        fragments_(memory),
        tcp_(memory) {}

}
