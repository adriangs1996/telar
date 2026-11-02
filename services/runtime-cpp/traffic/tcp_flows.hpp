#pragma once

#include "tcp_packet.hpp"
#include "flow.hpp"
#include "../memory/allocator.hpp"
#include "../memory/erasing_allocator.hpp"
#include "../memory/sensitive_buffer.hpp"
#include <unordered_map>
#include <bit>

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
    std::size_t operator()(const Key &key) const noexcept {
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
    explicit Side(Secure &memory) : pending(AllocatorRef<Segment, Secure>{memory}) {}
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
    explicit Flow(Secure &memory, std::uint64_t id, bool reverse, bool offline) : id(id), reverse(reverse), offline(offline), outbound(memory), inbound(memory) {}
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
  explicit TcpFlows(Memory &memory) : memory_(memory), flows_(0, Hash{}, std::equal_to<Key>{}, AllocatorRef<Entry, Secure>{memory_}) {}

  template <typename Emit>
  void packet(const Event &event, Emit emit) {
    const auto parsed = TcpPacketDecoder::decode(event);
    if (parsed) { consumePacket(event, *parsed, emit); }
  }

  template <typename Emit>
  void payload(const Event &event, const IpPayload &ip, Emit emit) {
    const auto parsed = TcpPacketDecoder::decodePayload(ip);
    if (parsed) { consumePacket(event, *parsed, emit); }
  }

  template <typename Emit>
  void expire(Emit emit, bool stop = false) {
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
  void consumePacket(const Event &event, const TcpPacket &packet, Emit emit) {
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

  static std::int32_t distance(std::uint32_t a, std::uint32_t b) noexcept { return std::bit_cast<std::int32_t>(a - b); }

  template <typename Emit>
  bool consume(Entry &entry, Side &side, const TcpPacket &packet, const Event &event, Emit emit) {
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
  static void publish(Kind kind, const Entry &entry, Event event, FlowEvent item, Emit emit) {
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
  void close(typename Map::iterator cursor, const Event &event, std::string_view reason, Emit emit, bool gap) {
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
