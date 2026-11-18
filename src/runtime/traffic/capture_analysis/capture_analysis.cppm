module;
#include "tbc/annotations.hpp"

export module telar.runtime.traffic.capture_analysis;

import std;
import telar.sys.posix;
import telar.sys.socket;
import telar.tbc;

import telar.runtime.traffic.control_protocol;

import telar.base.memory.allocators;
import telar.base.memory.sensitive;
import telar.vocabulary;
import telar.base.ds;

// Interface: traffic/network_packet.cppm
export {
  namespace telar::runtime::traffic {

    class NetworkPacket {
    public:
      static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept;

      static std::span<const Byte> decode(const Event& event) noexcept;
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

      static std::array<char, INET6_ADDRSTRLEN> addressText(const std::array<Byte, 16>& address, bool ipv6) noexcept;

      static ds::Option<IpPayload> decode(std::span<const Byte> bytes) noexcept;
    };

  }
}

// Interface: traffic/datagram.cppm
export {
  namespace telar::runtime::traffic {

    enum class DatagramTransport : Byte {
      udp,
      icmp,
      icmpv6,
    };

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

      bool echo() const noexcept;
    };

    class DatagramCodec {
    public:
      static std::string_view name(DatagramTransport transport) noexcept;

      static tbc::view<std::span<const Byte>, tbc::lt::a> encode(tbc::view<std::span<Byte>, tbc::lt::a> output, const DatagramEvent& event);

      static DatagramEvent decode(std::span<const Byte> input);

      static ds::Option<DatagramEvent> parse(const IpPayload& ip) noexcept;

    private:
      static void validate(const DatagramEvent& event);
    };

  }
}

// Interface: traffic/ip_fragments.cppm
export {
  namespace telar::runtime::traffic {

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
        bool operator==(const Key&) const = default;
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

      struct Range {
        std::size_t offset;
        std::size_t size;
        bool more;
      };

      struct Entry {
        Key key;
        Event event;
        Clock::time_point created;
        ds::Option<SensitiveAllocation<ConcurrentMemory>> storage;
        std::array<Range, 128> ranges;
        std::size_t count = 0;
        std::size_t received = 0;
        std::size_t prefix = 0;
        Byte next_header = 0;
        ds::Option<std::size_t> length;
      };

    public:
      static constexpr std::size_t maximum_datagrams = 32;
      static constexpr std::size_t maximum_payload = std::numeric_limits<std::uint16_t>::max();
      static constexpr std::size_t maximum_prefix = 256;
      static constexpr auto lifetime = std::chrono::seconds{60};

      explicit IpFragments(ConcurrentMemory& memory) noexcept;

      // Generic over the caller's callbacks, and called for every captured packet.
      template <typename Consume, typename Report>
      TBC_GENERIC void packet(const Event& event, Consume consume, Report report) {
        const auto network = NetworkPacket::decode(event);
        auto fragment = parse(network);
        if (!fragment) {
          consume(network);
          return;
        }

        auto& part = fragment.getMut();

        part.key.session = event.session;
        part.key.interface = event.interface_index;
        part.key.link_type = event.link_type;
        std::ranges::copy(event.interface.substr(0, part.key.name.size()), part.key.name.begin());
        if (!part.error.empty()) {
          report(event, part.error);
          return;
        }

        if (part.key.ipv6 && part.offset == 0 && !part.more) {
          Entry atomic;

          initialize(atomic, event, part.key);
          atomic.storage.emplace(memory_, maximum_prefix + maximum_payload);
          const auto error = append(atomic, part);
          if (!error.empty()) {
            report(event, error);
            return;
          }

          consume(assembled(atomic));
          return;
        }

        const auto now = Clock::now();
        ds::Option<Entry>* slot = nullptr;

        for (auto& entry : entries_) {
          if (entry && entry->key == part.key) {
            slot = &entry;
            break;
          }
        }

        if (slot && now - (*slot)->created >= lifetime) {
          if ((*slot)->storage) {
            failure(slot->getMut(), "ip_fragment_timeout", report);
          }

          slot->reset();
        }

        if (!slot) {
          const auto free = std::ranges::find_if(entries_, [](const auto& entry) {
            return !entry;
          });

          slot = free == entries_.end() ? &*std::min_element(entries_.begin(), entries_.end(), [](const auto& first, const auto& second) {
            return first->created < second->created;
          })
                                        : &*free;
          if (*slot && (*slot)->storage) {
            failure(slot->getMut(), "ip_fragment_capacity", report);
          }

          slot->reset();
        }

        if (!*slot) {
          Entry entry;

          initialize(entry, event, part.key);
          entry.storage.emplace(memory_, maximum_prefix + maximum_payload);
          slot->emplace(std::move(entry));
        }

        auto& entry = slot->getMut();
        if (!entry.storage) {
          return;
        }

        const auto error = append(entry, part);
        if (!error.empty()) {
          failure(entry, error, report);
          return;
        }

        if (entry.prefix != 0 && entry.length && entry.received == *entry.length) {
          auto completed = std::move(*slot);

          slot->reset();
          consume(assembled(completed.getMut()));
        }
      }

      template <typename Report>
      TBC_GENERIC void expire(Report report, bool stop = false, Clock::time_point now = Clock::now()) {
        for (auto& entry : entries_) {
          if (entry && (stop || now - entry->created >= lifetime)) {
            if (entry->storage) {
              failure(entry.getMut(), stop ? "ip_fragment_capture_stopped" : "ip_fragment_timeout", report);
            }

            entry.reset();
          }
        }
      }

    private:
      static ds::Option<Fragment> parse(std::span<const Byte> bytes) noexcept;

      static void initialize(Entry& entry, Event event, const Key& key) noexcept;

      // The reason a fragment is refused, a literal, or empty.
      static tbc::view<std::string_view, tbc::lt::static_storage> append(Entry& entry, const Fragment& part);

      static std::span<const Byte> assembled(Entry& entry);

      template <typename Report>
      TBC_GENERIC static void failure(Entry& entry, std::string_view reason, Report report) {
        entry.storage.reset();
        auto event = entry.event;

        event.interface = {entry.key.name.data(), strnlen(entry.key.name.data(), entry.key.name.size())};
        report(event, reason);
      }

      ConcurrentMemory& memory_;
      std::array<ds::Option<Entry>, maximum_datagrams> entries_;
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
      auto operator<=>(const TcpEndpoint&) const = default;

      std::string text() const;
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
      static std::uint16_t word(std::span<const Byte> bytes, std::size_t offset) noexcept;

      static ds::Option<TcpPacket> decode(const Event& event) noexcept;

      static ds::Option<TcpPacket> decodeNetwork(std::span<const Byte> bytes) noexcept;

      static tbc::view<ds::Option<TcpPacket>, tbc::lt::a> decodePayload(const IpPayload& ip) noexcept;
    };

  }
}

// Interface: traffic/tcp_flows.cppm
export {
  namespace telar::runtime::traffic {

    class TcpFlows {
      using Secure = ErasingAllocator<ConcurrentMemory>;
      using Bytes = Vector<Byte, Secure>;
      using Clock = std::chrono::steady_clock;

      struct Key {
        std::uint64_t session;
        std::uint32_t interface;
        std::array<char, Limits::interface_bytes> name{};
        TcpEndpoint first;
        TcpEndpoint second;
        bool operator==(const Key&) const = default;
      };

      struct Hash {
        std::size_t operator()(const Key& key) const noexcept;
      };

      struct Segment {
        std::uint32_t sequence;
        Bytes bytes;
      };

      struct Side {
        explicit Side(Secure& memory);

        Vector<Segment, Secure> pending;
        std::uint32_t next = 0;
        std::uint32_t initial = 0;
        ds::Option<std::uint32_t> fin;
        std::uint64_t offset = 0;
        ds::Option<Clock::time_point> gap;
        bool started = false;
        bool closed = false;
      };

      struct Flow {
        explicit Flow(Secure& memory, std::uint64_t id, bool reverse, bool offline);

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
      explicit TcpFlows(ConcurrentMemory& memory);

      // Generic over the caller's callbacks, and called for every captured packet.
      template <typename Emit>
      TBC_GENERIC void packet(const Event& event, Emit emit) {
        const auto parsed = TcpPacketDecoder::decode(event);
        if (parsed) {
          consumePacket(event, *parsed, emit);
        }
      }

      template <typename Emit>
      TBC_GENERIC void payload(const Event& event, const IpPayload& ip, Emit emit) {
        const auto parsed = TcpPacketDecoder::decodePayload(ip);
        if (parsed) {
          consumePacket(event, *parsed, emit);
        }
      }

      template <typename Emit>
      TBC_GENERIC void expire(Emit emit, bool stop = false) {
        const auto now = Clock::now();
        Event event;

        for (auto cursor = flows_.begin(); cursor != flows_.end();) {
          auto current = cursor++;
          const auto& flow = current->second;
          const bool gap = flow.outbound.gap || flow.inbound.gap;
          const bool expired_gap = (flow.outbound.gap && now - *flow.outbound.gap >= std::chrono::seconds{2}) || (flow.inbound.gap && now - *flow.inbound.gap >= std::chrono::seconds{2});
          if (stop || now - flow.touched >= std::chrono::seconds{60} || expired_gap) {
            close(current, event, stop ? "capture_stopped" : gap ? "tcp_gap_timeout"
                                                                 : "idle_timeout",
                emit,
                gap);
          }
        }
      }

    private:
      template <typename Emit>
      TBC_GENERIC void consumePacket(const Event& event, const TcpPacket& packet, Emit emit) {
        const bool reverse = packet.destination < packet.source;
        Key key{.session = event.session, .interface = event.interface_index, .first = reverse ? packet.destination : packet.source, .second = reverse ? packet.source : packet.destination};

        std::ranges::copy(event.interface, key.name.begin());
        auto found = flows_.find(key);
        if (found != flows_.end() && (packet.flags & syn) && !(packet.flags & ack)) {
          auto& side = reverse == found->second.reverse ? found->second.outbound : found->second.inbound;
          if (side.started && side.initial != packet.sequence + 1u) {
            close(found, event, "tuple_reused", emit, false);
            found = flows_.end();
          }
        }

        if (found == flows_.end()) {
          if (flows_.size() == maximum_flows) {
            auto oldest = std::min_element(flows_.begin(), flows_.end(), [](const auto& a, const auto& b) {
              return a.second.touched < b.second.touched;
            });

            close(oldest, event, "flow_limit", emit, true);
          }

          const bool initial_reverse = (packet.flags & syn) && (packet.flags & ack) ? !reverse : reverse;

          found = flows_.try_emplace(key, memory_, (std::uint64_t{1} << 63) | ++next_, initial_reverse, event.offline).first;
          publish(Kind::flow_open, *found, event, {}, emit);
          if (!(packet.flags & syn)) {
            publish(Kind::flow_gap, *found, event, {.reason = "capture_started_midstream"}, emit);
          }
        }

        auto& flow = found->second;
        const auto direction = reverse == flow.reverse ? Direction::outbound : Direction::inbound;
        auto& side = direction == Direction::outbound ? flow.outbound : flow.inbound;

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
          if (distance(*side.fin, side.next) > 0 && !side.gap) {
            side.gap = Clock::now();
          }
        }

        if (side.closed && !packet.bytes.empty() && distance(sequence + static_cast<std::uint32_t>(packet.bytes.size()), side.next - 1u) > 0) {
          close(found, event, "data_after_fin", emit, true);
          return;
        }

        if (!consume(*found, direction, buffered_, memory_, packet, event, emit)) {
          close(found, event, "reassembly_limit_or_overlap", emit, true);
          return;
        }

        auto& consumed = found->second;
        auto& settled = direction == Direction::outbound ? consumed.outbound : consumed.inbound;
        if (settled.fin && settled.next == *settled.fin && !settled.closed) {
          ++settled.next;
          settled.closed = true;
        }

        if (consumed.outbound.closed && consumed.inbound.closed) {
          close(found, event, "fin", emit, false);
        }
      }

      static std::int32_t distance(std::uint32_t a, std::uint32_t b) noexcept;

      // Reassembles one direction of a flow; the bytes buffered over every flow and the allocator are lent
      // apart from it.
      template <typename Emit>
      TBC_GENERIC inline static bool consume(tbc::view<Entry&, tbc::lt::a> entry, Direction direction, std::size_t& total_buffered, tbc::view<Secure&, tbc::lt::a> memory, const TcpPacket& packet, const Event& event, Emit emit) {
        auto& flow = entry.second;
        auto& side = direction == Direction::outbound ? flow.outbound : flow.inbound;
        auto sequence = packet.sequence + ((packet.flags & syn) ? 1u : 0u);
        auto bytes = packet.bytes;
        const auto behind = distance(side.next, sequence);
        if (behind > 0) {
          const auto skip = std::min(bytes.size(), static_cast<std::size_t>(behind));

          bytes = bytes.subspan(skip);
          sequence += static_cast<std::uint32_t>(skip);
        }

        for (const auto& pending : side.pending) {
          if (bytes.empty()) {
            break;
          }

          if (pending.sequence == sequence && std::ranges::equal(pending.bytes, bytes)) {
            return true;
          }

          const auto delta = distance(sequence, pending.sequence);
          if ((delta >= 0 && std::size_t(delta) < pending.bytes.size()) || (delta < 0 && std::size_t(-std::int64_t(delta)) < bytes.size())) {
            const auto incoming = delta < 0 ? static_cast<std::size_t>(-std::int64_t(delta)) : 0;
            const auto queued = delta > 0 ? static_cast<std::size_t>(delta) : 0;
            const auto count = std::min(bytes.size() - incoming, pending.bytes.size() - queued);
            if (!std::ranges::equal(bytes.subspan(incoming, count), std::span<const Byte>{pending.bytes}.subspan(queued, count))) {
              return false;
            }
          }
        }

        if (!bytes.empty() && sequence == side.next) {
          publish(Kind::stream_data, entry, event, {.direction = direction, .offset = side.offset, .bytes = bytes}, emit);
          side.next += static_cast<std::uint32_t>(bytes.size());
          side.offset += bytes.size();
        } else if (!bytes.empty() && distance(sequence, side.next) > 0) {
          if (side.pending.size() == 32 || flow.buffered + bytes.size() > per_flow_bytes || total_buffered + bytes.size() > total_bytes) {
            return false;
          }

          side.pending.push_back({sequence, Bytes{bytes.begin(), bytes.end(), AllocatorRef<Byte, Secure>{memory}}});
          flow.buffered += bytes.size();
          total_buffered += bytes.size();
          if (!side.gap) {
            side.gap = Clock::now();
          }
        }

        for (std::size_t index = 0; index < side.pending.size();) {
          auto& pending = side.pending[index];
          if (distance(pending.sequence, side.next) > 0) {
            ++index;
            continue;
          }

          const auto skip = std::min(pending.bytes.size(), static_cast<std::size_t>(static_cast<std::uint32_t>(side.next - pending.sequence)));
          const auto ready = std::span<const Byte>{pending.bytes}.subspan(skip);
          if (!ready.empty()) {
            publish(Kind::stream_data, entry, event, {.direction = direction, .offset = side.offset, .bytes = ready}, emit);
            side.next += static_cast<std::uint32_t>(ready.size());
            side.offset += ready.size();
          }

          total_buffered -= pending.bytes.size();
          flow.buffered -= pending.bytes.size();
          side.pending.erase(side.pending.begin() + index);
          index = 0;
        }

        if (side.pending.empty() && (!side.fin || side.closed || *side.fin == side.next)) {
          side.gap.reset();
        }

        return true;
      }

      template <typename Emit>
      TBC_GENERIC static void publish(Kind kind, const Entry& entry, Event event, FlowEvent item, Emit emit) {
        const auto& [key, flow] = entry;
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
      TBC_GENERIC void close(typename Map::iterator cursor, const Event& event, std::string_view reason, Emit emit, bool gap) {
        const auto& flow = cursor->second;
        if (flow.outbound.gap) {
          publish(Kind::flow_gap, *cursor, event, {.offset = flow.outbound.offset, .reason = reason}, emit);
        }

        if (flow.inbound.gap) {
          publish(Kind::flow_gap, *cursor, event, {.direction = Direction::inbound, .offset = flow.inbound.offset, .reason = reason}, emit);
        }

        if (gap && !flow.outbound.gap && !flow.inbound.gap) {
          publish(Kind::flow_gap, *cursor, event, {.reason = reason}, emit);
        }

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

    class CaptureAnalysis {
    public:
      explicit CaptureAnalysis(ConcurrentMemory& memory);

      // Generic over the caller's callbacks, and called for every captured packet.
      template <typename Emit>
      TBC_GENERIC void packet(const Event& event, Selection selection, Emit emit) {
        fragments_.packet(event, [&](std::span<const Byte> bytes) {
          const auto ip = IpPayload::decode(bytes);
          if (!ip) {
            return;
          }

          if (ip->protocol == IPPROTO_TCP && selects(selection, Selection::flows)) {
            tcp_.payload(event, *ip, emit);
          }

          if (!selects(selection, Selection::datagrams)) {
            return;
          }

          const auto datagram = DatagramCodec::parse(*ip);
          if (!datagram) {
            return;
          }

          SensitiveAllocation storage{memory_, datagram->bytes.size() + Limits::metadata_bytes};
          auto publication = event;

          publication.kind = Kind::datagram;
          publication.bytes = DatagramCodec::encode(storage.bytesMut(), *datagram);
          emit(publication);
        },
            [&](const Event& source, std::string_view reason) {
              fragmentError(source, reason, emit);
            });
      }

      template <typename Emit>
      TBC_GENERIC void expire(Emit emit, bool stop = false) {
        fragments_.expire([&](const Event& source, std::string_view reason) {
          fragmentError(source, reason, emit);
        },
            stop);
        tcp_.expire(emit, stop);
      }

    private:
      template <typename Emit>
      TBC_GENERIC static void fragmentError(Event event, std::string_view reason, Emit emit) {
        event.kind = Kind::error;
        event.bytes = {reinterpret_cast<const Byte*>(reason.data()), reason.size()};
        emit(event);
      }

      ConcurrentMemory& memory_;
      IpFragments fragments_;
      TcpFlows tcp_;
    };

  }
}
