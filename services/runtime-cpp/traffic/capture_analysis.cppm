module;
#include "tbc/view.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>

#include <cstddef>
#include <cstring>
#include <cstdint>
#include <pcap/pcap.h>

#include <arpa/inet.h>




export module telar.runtime.traffic.capture_analysis;

import std;

export import telar.runtime.traffic.control_protocol;


export import telar.base.memory;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: traffic/network_packet.cppm
export {
namespace telar::runtime::traffic {

class NetworkPacket {
public:
  inline static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>((std::uint16_t{bytes[offset]} << 8) | bytes[offset + 1]);
  }

  inline static std::span<const Byte> decode(const Event &event) noexcept {
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
}

// Interface: traffic/ip_payload.cppm
export {
namespace telar::runtime::traffic {

// The addresses of an IP packet and its payload, which views the packet, region `a`.
struct IpPayload {
  std::array<Byte, 16> source{};
  std::array<Byte, 16> destination{};
  tbc::view<std::span<const Byte>, tbc::lt::a> bytes;
  std::size_t original_bytes = 0;
  Byte protocol = 0;
  bool ipv6 = false;
  bool truncated = false;

  inline static std::array<char, INET6_ADDRSTRLEN> addressText(const std::array<Byte, 16> &address, bool ipv6) noexcept {
    std::array<char, INET6_ADDRSTRLEN> text{};
    ::inet_ntop(ipv6 ? AF_INET6 : AF_INET, address.data(), text.data(), text.size());
    return text;
  }

  inline static std::optional<IpPayload> decode(std::span<const Byte> bytes) noexcept {
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
}

// Interface: traffic/datagram.cppm
export {
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

  inline bool echo() const noexcept {
    return transport != DatagramTransport::udp && icmp_code == 0 && bytes.size() >= 8 && (transport == DatagramTransport::icmp ? icmp_type == 0 || icmp_type == 8 : icmp_type == 128 || icmp_type == 129);
  }
};

class DatagramCodec {
public:
  inline static std::string_view name(DatagramTransport transport) noexcept {
    constexpr std::array names{std::string_view{"udp"}, std::string_view{"icmp"}, std::string_view{"icmpv6"}};
    return names[static_cast<std::size_t>(transport)];
  }

  inline static tbc::view<std::span<const Byte>, tbc::lt::a> encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const DatagramEvent &event) {
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

  inline static DatagramEvent decode(std::span<const Byte> input) {
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

  inline static std::optional<DatagramEvent> parse(const IpPayload &ip) noexcept {
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
  inline static void validate(const DatagramEvent &event) {
    if (static_cast<Byte>(event.transport) > static_cast<Byte>(DatagramTransport::icmpv6) || event.original_bytes > UINT16_MAX || event.bytes.size() > event.original_bytes || event.truncated != (event.bytes.size() < event.original_bytes) || (event.transport == DatagramTransport::icmp && event.ipv6) || (event.transport == DatagramTransport::icmpv6 && !event.ipv6)) { throw EncodingError{"Invalid datagram metadata"}; }
    if (!event.ipv6 && (std::ranges::any_of(std::span{event.source_address}.subspan(4), [](Byte value) { return value != 0; }) || std::ranges::any_of(std::span{event.destination_address}.subspan(4), [](Byte value) { return value != 0; }))) { throw EncodingError{"Invalid IPv4 datagram address padding"}; }
    if (event.transport != DatagramTransport::udp && (event.bytes.size() < 4 || event.bytes[0] != event.icmp_type || event.bytes[1] != event.icmp_code || event.source_port != 0 || event.destination_port != 0)) { throw EncodingError{"Invalid ICMP message metadata"}; }
  }
};

}
}

// Interface: traffic/ip_fragments.cppm
export {
namespace telar::runtime::traffic {

template <Allocator Memory>
class IpFragments {
  using Clock = std::chrono::steady_clock;
  struct Key {
    std::uint64_t session = 0;
    std::uint32_t interface = 0;
    std::uint32_t link_type = 0;
    std::array<char, Limits::interface_bytes> name{};
    std::array<Byte, 32> addresses{};
    std::uint32_t identification = 0;
    Byte protocol = 0;
    bool ipv6 = false;
    bool operator==(const Key &) const = default;
  };
  struct Fragment {
    Key key;
    std::span<const Byte> prefix;
    std::span<const Byte> payload;
    std::size_t offset = 0;
    std::size_t previous_header = 0;
    Byte next_header = 0;
    bool more = false;
    std::string_view error;
  };
  struct Range { std::size_t offset; std::size_t size; bool more; };
  struct Entry {
    Key key;
    Event event;
    Clock::time_point created;
    std::optional<SensitiveAllocation<Memory>> storage;
    std::array<Range, 128> ranges;
    std::size_t count = 0;
    std::size_t received = 0;
    std::size_t prefix = 0;
    Byte next_header = 0;
    std::optional<std::size_t> length;
  };

public:
  static constexpr std::size_t maximum_datagrams = 32;
  static constexpr std::size_t maximum_payload = UINT16_MAX;
  static constexpr std::size_t maximum_prefix = 256;
  static constexpr auto lifetime = std::chrono::seconds{60};

  inline explicit IpFragments(Memory &memory) noexcept : memory_(memory) {}

  template <typename Consume, typename Report>
  inline void packet(const Event &event, Consume consume, Report report) {
    const auto network = NetworkPacket::decode(event);
    auto fragment = parse(network);
    if (!fragment) { consume(network); return; }
    auto &part = *fragment;
    part.key.session = event.session;
    part.key.interface = event.interface_index;
    part.key.link_type = event.link_type;
    std::ranges::copy(event.interface.substr(0, part.key.name.size()), part.key.name.begin());
    if (!part.error.empty()) { report(event, part.error); return; }
    if (part.key.ipv6 && part.offset == 0 && !part.more) {
      Entry atomic;
      initialize(atomic, event, part.key);
      atomic.storage.emplace(memory_, maximum_prefix + maximum_payload);
      const auto error = append(atomic, part);
      if (!error.empty()) { report(event, error); return; }
      consume(assembled(atomic));
      return;
    }

    const auto now = Clock::now();
    std::optional<Entry> *slot = nullptr;
    for (auto &entry : entries_) {
      if (entry && entry->key == part.key) { slot = &entry; break; }
    }
    if (slot && now - (*slot)->created >= lifetime) {
      if ((*slot)->storage) { failure(**slot, "ip_fragment_timeout", report); }
      slot->reset();
    }
    if (!slot) {
      const auto free = std::ranges::find_if(entries_, [](const auto &entry) { return !entry; });
      slot = free == entries_.end() ? &*std::min_element(entries_.begin(), entries_.end(), [](const auto &first, const auto &second) { return first->created < second->created; }) : &*free;
      if (*slot && (*slot)->storage) { failure(**slot, "ip_fragment_capacity", report); }
      slot->reset();
    }
    if (!*slot) {
      Entry entry;
      initialize(entry, event, part.key);
      entry.storage.emplace(memory_, maximum_prefix + maximum_payload);
      slot->emplace(std::move(entry));
    }
    auto &entry = **slot;
    if (!entry.storage) { return; }
    const auto error = append(entry, part);
    if (!error.empty()) { failure(entry, error, report); return; }
    if (entry.prefix != 0 && entry.length && entry.received == *entry.length) {
      auto completed = std::move(*slot);
      slot->reset();
      consume(assembled(*completed));
    }
  }

  template <typename Report>
  inline void expire(Report report, bool stop = false, Clock::time_point now = Clock::now()) {
    for (auto &entry : entries_) {
      if (entry && (stop || now - entry->created >= lifetime)) {
        if (entry->storage) { failure(*entry, stop ? "ip_fragment_capture_stopped" : "ip_fragment_timeout", report); }
        entry.reset();
      }
    }
  }

private:
  inline static std::optional<Fragment> parse(std::span<const Byte> bytes) noexcept {
    if (bytes.empty()) { return {}; }
    Fragment part;
    if ((bytes[0] >> 4) == 4) {
      if (bytes.size() < 20 || (NetworkPacket::word(bytes, 6) & 0x3fff) == 0) { return {}; }
      const auto flags = NetworkPacket::word(bytes, 6);
      part.offset = std::size_t{flags & 0x1fffu} * 8;
      part.more = (flags & 0x2000) != 0;
      part.key.identification = NetworkPacket::word(bytes, 4);
      part.key.protocol = bytes[9];
      std::copy_n(bytes.begin() + 12, 8, part.key.addresses.begin());
      const auto head = std::size_t{bytes[0] & 15u} * 4;
      const auto length = NetworkPacket::word(bytes, 2);
      if (head < 20 || head > bytes.size() || length <= head || length > bytes.size() || (flags & 0xc000) != 0) { part.error = "ip_fragment_invalid_or_truncated"; return part; }
      part.prefix = bytes.first(head);
      part.payload = bytes.subspan(head, length - head);
    } else if ((bytes[0] >> 4) == 6) {
      if (bytes.size() < 40) { return {}; }
      const auto length = std::size_t{NetworkPacket::word(bytes, 4)} + 40;
      auto protocol = bytes[6];
      std::size_t offset = 40;
      part.previous_header = 6;
      for (unsigned depth = 0; protocol != 44; ++depth) {
        if (depth == 8 || offset > bytes.size() || bytes.size() - offset < 2 || (protocol != 0 && protocol != 43 && protocol != 60 && protocol != 51)) { return {}; }
        const auto head = protocol == 51 ? (std::size_t{bytes[offset + 1]} + 2) * 4 : (std::size_t{bytes[offset + 1]} + 1) * 8;
        part.previous_header = offset;
        protocol = bytes[offset];
        offset += head;
      }
      part.key.ipv6 = true;
      if (offset > bytes.size() || bytes.size() - offset < 8 || length > bytes.size() || length <= offset + 8 || offset > maximum_prefix) { part.error = "ip_fragment_invalid_or_truncated"; return part; }
      std::copy_n(bytes.begin() + 8, 32, part.key.addresses.begin());
      part.key.identification = (std::uint32_t{NetworkPacket::word(bytes, offset + 4)} << 16) | NetworkPacket::word(bytes, offset + 6);
      const auto flags = NetworkPacket::word(bytes, offset + 2);
      part.offset = flags & 0xfff8u;
      part.more = (flags & 1) != 0;
      part.next_header = bytes[offset];
      part.prefix = bytes.first(offset);
      part.payload = bytes.subspan(offset + 8, length - offset - 8);
    } else { return {}; }
    if ((part.more && part.payload.size() % 8 != 0) || part.offset + part.payload.size() > maximum_payload) { part.error = "ip_fragment_size_limit"; }
    return part;
  }

  inline static void initialize(Entry &entry, Event event, const Key &key) noexcept {
    entry.key = key;
    event.bytes = {};
    event.interface = {};
    entry.event = event;
    entry.created = Clock::now();
  }

  // The reason a fragment is refused, a literal, or empty.
  inline static tbc::view<std::string_view, tbc::lt::static_storage> append(Entry &entry, const Fragment &part) {
    const auto end = part.offset + part.payload.size();
    if (entry.length && (end > *entry.length || (!part.more && end != *entry.length))) { return "ip_fragment_conflicting_length"; }
    for (const auto &range : std::span{entry.ranges}.first(entry.count)) {
      if (range.offset == part.offset && range.size == part.payload.size() && range.more == part.more && std::ranges::equal(entry.storage->bytes().subspan(maximum_prefix + part.offset, range.size), part.payload)) {
        if (part.offset == 0 && (entry.prefix != part.prefix.size() || (part.key.ipv6 && entry.next_header != part.next_header))) { return "ip_fragment_overlap"; }
        return {};
      }
      if (part.offset < range.offset + range.size && range.offset < end) { return "ip_fragment_overlap"; }
      if (!part.more && range.offset + range.size > end) { return "ip_fragment_conflicting_length"; }
    }
    if (entry.count == entry.ranges.size()) { return "ip_fragment_piece_limit"; }
    if (part.offset == 0) {
      entry.prefix = part.prefix.size();
      entry.next_header = part.next_header;
      std::ranges::copy(part.prefix, entry.storage->bytes().begin() + maximum_prefix - entry.prefix);
      if (part.key.ipv6) { entry.storage->bytes()[maximum_prefix - entry.prefix + part.previous_header] = part.next_header; }
    }
    std::ranges::copy(part.payload, entry.storage->bytes().begin() + maximum_prefix + part.offset);
    entry.ranges[entry.count++] = {part.offset, part.payload.size(), part.more};
    entry.received += part.payload.size();
    if (!part.more) { entry.length = end; }
    if (entry.prefix != 0 && entry.length && entry.prefix - (entry.key.ipv6 ? 40 : 0) + *entry.length > UINT16_MAX) { return "ip_fragment_size_limit"; }
    return {};
  }

  inline static std::span<const Byte> assembled(Entry &entry) {
    auto bytes = entry.storage->bytes().subspan(maximum_prefix - entry.prefix, entry.prefix + *entry.length);
    const auto length = bytes.size() - (entry.key.ipv6 ? 40 : 0);
    const auto offset = entry.key.ipv6 ? 4u : 2u;
    bytes[offset] = static_cast<Byte>(length >> 8);
    bytes[offset + 1] = static_cast<Byte>(length);
    if (!entry.key.ipv6) {
      bytes[6] = bytes[7] = bytes[10] = bytes[11] = 0;
      std::uint32_t sum = 0;
      for (std::size_t index = 0; index < entry.prefix; index += 2) { sum += NetworkPacket::word(bytes, index); }
      while (sum >> 16) { sum = (sum & UINT16_MAX) + (sum >> 16); }
      const auto checksum = static_cast<std::uint16_t>(~sum);
      bytes[10] = static_cast<Byte>(checksum >> 8);
      bytes[11] = static_cast<Byte>(checksum);
    }
    return bytes;
  }

  template <typename Report>
  inline static void failure(Entry &entry, std::string_view reason, Report report) {
    entry.storage.reset();
    auto event = entry.event;
    event.interface = {entry.key.name.data(), strnlen(entry.key.name.data(), entry.key.name.size())};
    report(event, reason);
  }

  Memory &memory_;
  std::array<std::optional<Entry>, maximum_datagrams> entries_;
};

}
}

// Interface: traffic/tcp_packet.cppm
export {
namespace telar::runtime::traffic {

struct TcpEndpoint {
  std::array<Byte, 16> address{};
  std::uint16_t port = 0;
  bool ipv6 = false;
  auto operator<=>(const TcpEndpoint &) const = default;

  inline std::string text() const {
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
  inline static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept {
    return NetworkPacket::word(bytes, offset);
  }

  inline static std::optional<TcpPacket> decode(const Event &event) noexcept {
    return decodeNetwork(NetworkPacket::decode(event));
  }

  inline static std::optional<TcpPacket> decodeNetwork(std::span<const Byte> bytes) noexcept {
    const auto ip = IpPayload::decode(bytes);
    return ip ? decodePayload(*ip) : std::nullopt;
  }

  inline static tbc::view<std::optional<TcpPacket>, tbc::lt::a> decodePayload(const IpPayload &ip) noexcept {
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
}

// Interface: traffic/tcp_flows.cppm
export {
namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory>
class TcpFlows {
  using Secure = ErasingAllocator<Memory>;
  using Bytes = Vector<Byte, Secure>;
  using Clock = std::chrono::steady_clock;
  struct Key {
    std::uint64_t session;
    std::uint32_t interface;
    std::array<char, Limits::interface_bytes> name{};
    TcpEndpoint first;
    TcpEndpoint second;
    bool operator==(const Key &) const = default;
  };
  struct Hash {
    inline std::size_t operator()(const Key &key) const noexcept {
      std::size_t hash = key.session;
      auto add = [&](unsigned value) { hash = (hash ^ value) * 1099511628211ull; };
      add(key.interface);
      for (const auto c : key.name) { add(static_cast<unsigned char>(c)); }
      for (const auto *endpoint : {&key.first, &key.second}) {
        for (const auto byte : endpoint->address) { add(byte); }
        add(endpoint->port);
        add(endpoint->ipv6);
      }
      return hash;
    }
  };
  struct Segment { std::uint32_t sequence; Bytes bytes; };
  struct Side {
    inline explicit Side(Secure &memory) : pending(AllocatorRef<Segment, Secure>{memory}) {}
    Vector<Segment, Secure> pending;
    std::uint32_t next = 0;
    std::uint32_t initial = 0;
    std::optional<std::uint32_t> fin;
    std::uint64_t offset = 0;
    std::optional<Clock::time_point> gap;
    bool started = false;
    bool closed = false;
  };
  struct Flow {
    inline explicit Flow(Secure &memory, std::uint64_t id, bool reverse, bool offline) : id(id), reverse(reverse), offline(offline), outbound(memory), inbound(memory) {}
    std::uint64_t id;
    bool reverse;
    bool offline;
    Side outbound;
    Side inbound;
    Clock::time_point touched = Clock::now();
    std::size_t buffered = 0;
  };
  using Entry = std::pair<const Key, Flow>;
  using Map = std::unordered_map<Key, Flow, Hash, std::equal_to<Key>, AllocatorRef<Entry, Secure>>;

public:
  inline explicit TcpFlows(Memory &memory) : memory_(memory), flows_(0, Hash{}, std::equal_to<Key>{}, AllocatorRef<Entry, Secure>{memory_}) {}

  template <typename Emit>
  inline void packet(const Event &event, Emit emit) {
    const auto parsed = TcpPacketDecoder::decode(event);
    if (parsed) { consumePacket(event, *parsed, emit); }
  }

  template <typename Emit>
  inline void payload(const Event &event, const IpPayload &ip, Emit emit) {
    const auto parsed = TcpPacketDecoder::decodePayload(ip);
    if (parsed) { consumePacket(event, *parsed, emit); }
  }

  template <typename Emit>
  inline void expire(Emit emit, bool stop = false) {
    const auto now = Clock::now();
    Event event;
    for (auto cursor = flows_.begin(); cursor != flows_.end();) {
      auto current = cursor++;
      const auto &flow = current->second;
      const bool gap = flow.outbound.gap || flow.inbound.gap;
      const bool expired_gap = (flow.outbound.gap && now - *flow.outbound.gap >= std::chrono::seconds{2}) || (flow.inbound.gap && now - *flow.inbound.gap >= std::chrono::seconds{2});
      if (stop || now - flow.touched >= std::chrono::seconds{60} || expired_gap) {
        close(current, event, stop ? "capture_stopped" : gap ? "tcp_gap_timeout" : "idle_timeout", emit, gap);
      }
    }
  }

private:
  template <typename Emit>
  inline void consumePacket(const Event &event, const TcpPacket &packet, Emit emit) {
    const bool reverse = packet.destination < packet.source;
    Key key{.session = event.session, .interface = event.interface_index, .first = reverse ? packet.destination : packet.source, .second = reverse ? packet.source : packet.destination};
    std::ranges::copy(event.interface, key.name.begin());
    auto found = flows_.find(key);
    if (found != flows_.end() && (packet.flags & syn) && !(packet.flags & ack)) {
      auto &side = reverse == found->second.reverse ? found->second.outbound : found->second.inbound;
      if (side.started && side.initial != packet.sequence + 1u) {
        close(found, event, "tuple_reused", emit, false);
        found = flows_.end();
      }
    }
    if (found == flows_.end()) {
      if (flows_.size() == maximum_flows) {
        auto oldest = std::min_element(flows_.begin(), flows_.end(), [](const auto &a, const auto &b) { return a.second.touched < b.second.touched; });
        close(oldest, event, "flow_limit", emit, true);
      }
      const bool initial_reverse = (packet.flags & syn) && (packet.flags & ack) ? !reverse : reverse;
      found = flows_.try_emplace(key, memory_, (std::uint64_t{1} << 63) | ++next_, initial_reverse, event.offline).first;
      publish(Kind::flow_open, *found, event, {}, emit);
      if (!(packet.flags & syn)) {
        publish(Kind::flow_gap, *found, event, {.reason = "capture_started_midstream"}, emit);
      }
    }
    auto &flow = found->second;
    auto &side = reverse == flow.reverse ? flow.outbound : flow.inbound;
    flow.touched = Clock::now();
    if (packet.truncated) {
      close(found, event, "truncated_packet", emit, true);
      return;
    }
    if (packet.flags & rst) {
      close(found, event, "reset", emit, false);
      return;
    }
    const auto sequence = packet.sequence + ((packet.flags & syn) ? 1u : 0u);
    if (!side.started) {
      side.started = true;
      side.initial = side.next = sequence;
    }
    if (packet.flags & fin) {
      side.fin = sequence + static_cast<std::uint32_t>(packet.bytes.size());
      if (distance(*side.fin, side.next) > 0 && !side.gap) { side.gap = Clock::now(); }
    }
    if (side.closed && !packet.bytes.empty() && distance(sequence + static_cast<std::uint32_t>(packet.bytes.size()), side.next - 1u) > 0) {
      close(found, event, "data_after_fin", emit, true);
      return;
    }
    if (!consume(*found, side, packet, event, emit)) {
      close(found, event, "reassembly_limit_or_overlap", emit, true);
      return;
    }
    if (side.fin && side.next == *side.fin && !side.closed) { ++side.next; side.closed = true; }
    if (flow.outbound.closed && flow.inbound.closed) { close(found, event, "fin", emit, false); }
  }

  inline static std::int32_t distance(std::uint32_t a, std::uint32_t b) noexcept { return std::bit_cast<std::int32_t>(a - b); }

  template <typename Emit>
  inline bool consume(Entry &entry, Side &side, const TcpPacket &packet, const Event &event, Emit emit) {
    auto &flow = entry.second;
    const auto direction = &side == &flow.outbound ? Direction::outbound : Direction::inbound;
    auto sequence = packet.sequence + ((packet.flags & syn) ? 1u : 0u);
    auto bytes = packet.bytes;
    const auto behind = distance(side.next, sequence);
    if (behind > 0) {
      const auto skip = std::min(bytes.size(), static_cast<std::size_t>(behind));
      bytes = bytes.subspan(skip);
      sequence += static_cast<std::uint32_t>(skip);
    }
    for (const auto &pending : side.pending) {
      if (bytes.empty()) { break; }
      if (pending.sequence == sequence && std::ranges::equal(pending.bytes, bytes)) { return true; }
      const auto delta = distance(sequence, pending.sequence);
      if ((delta >= 0 && std::size_t(delta) < pending.bytes.size()) || (delta < 0 && std::size_t(-std::int64_t(delta)) < bytes.size())) {
        const auto incoming = delta < 0 ? static_cast<std::size_t>(-std::int64_t(delta)) : 0;
        const auto queued = delta > 0 ? static_cast<std::size_t>(delta) : 0;
        const auto count = std::min(bytes.size() - incoming, pending.bytes.size() - queued);
        if (!std::ranges::equal(bytes.subspan(incoming, count), std::span<const Byte>{pending.bytes}.subspan(queued, count))) { return false; }
      }
    }
    if (!bytes.empty() && sequence == side.next) {
      publish(Kind::stream_data, entry, event, {.direction = direction, .offset = side.offset, .bytes = bytes}, emit);
      side.next += static_cast<std::uint32_t>(bytes.size());
      side.offset += bytes.size();
    } else if (!bytes.empty() && distance(sequence, side.next) > 0) {
      if (side.pending.size() == 32 || flow.buffered + bytes.size() > per_flow_bytes || buffered_ + bytes.size() > total_bytes) { return false; }
      side.pending.push_back({sequence, Bytes{bytes.begin(), bytes.end(), AllocatorRef<Byte, Secure>{memory_}}});
      flow.buffered += bytes.size();
      buffered_ += bytes.size();
      if (!side.gap) { side.gap = Clock::now(); }
    }
    for (std::size_t index = 0; index < side.pending.size();) {
      auto &pending = side.pending[index];
      if (distance(pending.sequence, side.next) > 0) { ++index; continue; }
      const auto skip = std::min(pending.bytes.size(), static_cast<std::size_t>(static_cast<std::uint32_t>(side.next - pending.sequence)));
      const auto ready = std::span<const Byte>{pending.bytes}.subspan(skip);
      if (!ready.empty()) {
        publish(Kind::stream_data, entry, event, {.direction = direction, .offset = side.offset, .bytes = ready}, emit);
        side.next += static_cast<std::uint32_t>(ready.size());
        side.offset += ready.size();
      }
      buffered_ -= pending.bytes.size();
      flow.buffered -= pending.bytes.size();
      side.pending.erase(side.pending.begin() + index);
      index = 0;
    }
    if (side.pending.empty() && (!side.fin || side.closed || *side.fin == side.next)) { side.gap.reset(); }
    return true;
  }

  template <typename Emit>
  inline static void publish(Kind kind, const Entry &entry, Event event, FlowEvent item, Emit emit) {
    const auto &[key, flow] = entry;
    const auto client = (flow.reverse ? key.second : key.first).text();
    const auto server = (flow.reverse ? key.first : key.second).text();
    item.id = flow.id;
    item.source = FlowSource::capture;
    item.client = client;
    item.server = server;
    SensitiveBuffer<Limits::frame_bytes> output;
    event.kind = kind;
    event.session = key.session;
    event.offline = flow.offline;
    event.interface_index = key.interface;
    event.interface = std::string_view{key.name.data(), strnlen(key.name.data(), key.name.size())};
    event.bytes = FlowCodec::encode(output.bytes(), item);
    emit(event);
  }

  template <typename Emit>
  inline void close(typename Map::iterator cursor, const Event &event, std::string_view reason, Emit emit, bool gap) {
    const auto &flow = cursor->second;
    if (flow.outbound.gap) { publish(Kind::flow_gap, *cursor, event, {.offset = flow.outbound.offset, .reason = reason}, emit); }
    if (flow.inbound.gap) { publish(Kind::flow_gap, *cursor, event, {.direction = Direction::inbound, .offset = flow.inbound.offset, .reason = reason}, emit); }
    if (gap && !flow.outbound.gap && !flow.inbound.gap) { publish(Kind::flow_gap, *cursor, event, {.reason = reason}, emit); }
    publish(Kind::flow_close, *cursor, event, {.reason = reason}, emit);
    buffered_ -= cursor->second.buffered;
    flows_.erase(cursor);
  }

  static constexpr Byte fin = 1, syn = 2, rst = 4, ack = 16;
  static constexpr std::size_t maximum_flows = 256;
  static constexpr std::size_t per_flow_bytes = 64 * 1024;
  static constexpr std::size_t total_bytes = 8 * 1024 * 1024;
  Secure memory_;
  Map flows_;
  std::size_t buffered_ = 0;
  std::uint64_t next_ = 0;
};

}
}

// Interface: traffic/capture_analysis.cppm
export {
namespace telar::runtime::traffic {

template <ConcurrentAllocator Memory>
class CaptureAnalysis {
public:
  inline explicit CaptureAnalysis(Memory &memory) : memory_(memory), fragments_(memory), tcp_(memory) {}

  template <typename Emit>
  inline void packet(const Event &event, Selection selection, Emit emit) {
    fragments_.packet(event, [&](std::span<const Byte> bytes) {
      const auto ip = IpPayload::decode(bytes);
      if (!ip) { return; }
      if (ip->protocol == IPPROTO_TCP && selects(selection, Selection::flows)) { tcp_.payload(event, *ip, emit); }
      if (!selects(selection, Selection::datagrams)) { return; }
      const auto datagram = DatagramCodec::parse(*ip);
      if (!datagram) { return; }
      SensitiveAllocation storage{memory_, datagram->bytes.size() + Limits::metadata_bytes};
      auto publication = event;
      publication.kind = Kind::datagram;
      publication.bytes = DatagramCodec::encode(storage.bytes(), *datagram);
      emit(publication);
    }, [&](const Event &source, std::string_view reason) { fragmentError(source, reason, emit); });
  }

  template <typename Emit>
  inline void expire(Emit emit, bool stop = false) {
    fragments_.expire([&](const Event &source, std::string_view reason) { fragmentError(source, reason, emit); }, stop);
    tcp_.expire(emit, stop);
  }

private:
  template <typename Emit>
  inline static void fragmentError(Event event, std::string_view reason, Emit emit) {
    event.kind = Kind::error;
    event.bytes = {reinterpret_cast<const Byte *>(reason.data()), reason.size()};
    emit(event);
  }

  Memory &memory_;
  IpFragments<Memory> fragments_;
  TcpFlows<Memory> tcp_;
};

}
}
