export module telar.runtime.traffic.capture_analysis;

import std;
import telar.sys.posix;
import telar.sys.socket;
import telar.tbc;

import telar.runtime.traffic.control_protocol;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;
import telar.vocabulary;
import telar.base.ds;
import telar.wire.vocabulary;

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
      // An IPv6 address, which an IPv4 one fills the start of.
      static constexpr std::size_t address_bytes = 16;

      ds::Array<Byte, address_bytes> source{};
      ds::Array<Byte, address_bytes> destination{};
      tbc::val_a<std::span<const Byte>> bytes;
      std::size_t original_bytes = 0;
      Byte protocol = 0;
      bool ipv6 = false;
      bool truncated = false;

      static ds::Array<char, INET6_ADDRSTRLEN> addressText(const ds::Array<Byte, address_bytes>& address, bool ipv6) noexcept;

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
      ds::Array<Byte, IpPayload::address_bytes> source_address{};
      ds::Array<Byte, IpPayload::address_bytes> destination_address{};
      std::uint16_t source_port = 0;
      std::uint16_t destination_port = 0;
      Byte icmp_type = 0;
      Byte icmp_code = 0;
      std::uint32_t original_bytes = 0;
      bool truncated = false;
      std::span<const Byte> bytes;

      [[nodiscard]] bool echo() const noexcept;
    };

    class DatagramCodec {
    public:
      static std::string_view name(DatagramTransport transport) noexcept;

      static tbc::val_a<std::span<const Byte>> encode(tbc::val_a<std::span<Byte>> output, const DatagramEvent& event);

      static DatagramEvent decode(std::span<const Byte> input);

      static ds::Option<DatagramEvent> parse(const IpPayload& payload) noexcept;

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

      static constexpr std::size_t maximum_ranges = 128;

      struct Key {
        std::uint64_t session = 0;
        std::uint32_t interface = 0;
        std::uint32_t link_type = 0;
        ds::Array<char, Limits::interface_bytes> name{};
        ds::Array<Byte, 2 * IpPayload::address_bytes> addresses{};
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

      struct Entry { // NOLINT(cppcoreguidelines-pro-type-member-init): only the first count ranges are read, and zeroing all of them would add work to every fragment
        Key key;
        Event event;
        Clock::time_point created;
        ds::Option<SensitiveAllocation<ConcurrentMemory>> storage;
        ds::Array<Range, maximum_ranges> ranges;
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
      [[tbc::generic]] void packet(const Event& event, Consume consume, Report report) {
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
        std::ranges::copy(event.interface.substr(0, part.key.name.size()), part.key.name.viewMut().begin());
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

        const auto slot_index = acquireSlot(part.key, Clock::now(), report);
        auto& slot = entries_.atMut(slot_index);
        if (!slot) {
          Entry entry;

          initialize(entry, event, part.key);
          entry.storage.emplace(memory_, maximum_prefix + maximum_payload);
          slot.emplace(std::move(entry));
        }

        auto& entry = slot.getMut();
        if (!entry.storage) {
          return;
        }

        const auto error = append(entry, part);
        if (!error.empty()) {
          failure(entry, error, report);
          return;
        }

        if (entry.prefix != 0 && entry.length && entry.received == *entry.length) {
          auto completed = std::move(slot);

          slot.reset();
          consume(assembled(completed.getMut()));
        }
      }

      template <typename Report>
      [[tbc::generic]] void expire(Report report, bool stop = false, Clock::time_point now = Clock::now()) {
        for (auto& entry : entries_.viewMut()) {
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
      static tbc::val_static<std::string_view> append(Entry& entry, const Fragment& part);

      // Copies a fragment into the entry's storage, and the header of the first one before it.
      static void store(Entry& entry, const Fragment& part);

      static std::span<const Byte> assembled(Entry& entry);

      template <typename Report>
      [[tbc::generic]] std::size_t acquireSlot(const Key& key, Clock::time_point now, Report& report) {
        auto entries = entries_.viewMut();

        for (std::size_t index = 0; index < entries.size(); ++index) {
          if (!entries[index] || entries[index]->key != key) {
            continue;
          }

          if (now - entries[index]->created >= lifetime) {
            if (entries[index]->storage) {
              failure(entries[index].getMut(), "ip_fragment_timeout", report);
            }

            entries[index].reset();
          }

          return index;
        }

        std::size_t oldest = 0;

        for (std::size_t index = 0; index < entries.size(); ++index) {
          if (!entries[index]) {
            return index;
          }

          if (entries[index]->created < entries[oldest]->created) {
            oldest = index;
          }
        }

        if (entries[oldest] && entries[oldest]->storage) {
          failure(entries[oldest].getMut(), "ip_fragment_capacity", report);
        }

        entries[oldest].reset();
        return oldest;
      }

      template <typename Report>
      [[tbc::generic]] static void failure(Entry& entry, std::string_view reason, Report report) {
        entry.storage.reset();
        auto event = entry.event;

        event.interface = {entry.key.name.data(), strnlen(entry.key.name.data(), entry.key.name.size())};
        report(event, reason);
      }

      ConcurrentMemory& memory_;
      ds::Array<ds::Option<Entry>, maximum_datagrams> entries_;
    };

  }
}

// Interface: traffic/tcp_packet.cppm
export {
  namespace telar::runtime::traffic {

    struct TcpEndpoint {
      ds::Array<Byte, IpPayload::address_bytes> address{};
      std::uint16_t port = 0;
      bool ipv6 = false;
      auto operator<=>(const TcpEndpoint&) const = default;

      // An address and its port, as `[address]:port` for IPv6.
      static constexpr std::size_t text_bytes = INET6_ADDRSTRLEN + 8;

      [[nodiscard]] FixedText<text_bytes> text() const;
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

      static tbc::val_a<ds::Option<TcpPacket>> decodePayload(const IpPayload& payload) noexcept;
    };

  }
}

// Interface: traffic/tcp_flows.cppm
export {
  namespace telar::runtime::traffic {

    class TcpFlows {
      using Secure = ErasingAllocator<ConcurrentMemory>;
      using Bytes = ds::Vec<Byte, Secure>;
      using Clock = std::chrono::steady_clock;

      struct Key {
        std::uint64_t session;
        std::uint32_t interface;
        ds::Array<char, Limits::interface_bytes> name{};
        TcpEndpoint first;
        TcpEndpoint second;
        bool operator==(const Key&) const = default;
      };

      struct Hash {
        std::uint64_t operator()(const Key& key) const noexcept;
      };

      struct Segment {
        std::uint32_t sequence;
        Bytes bytes;
      };

      struct Side {
        explicit Side(Secure& memory);

        ds::Vec<Segment, Secure> pending;
        std::uint32_t next = 0;
        std::uint32_t initial = 0;
        ds::Option<std::uint32_t> fin;
        std::uint64_t offset = 0;
        ds::Option<Clock::time_point> gap;
        bool started = false;
        bool closed = false;
      };

      struct Flow {
        explicit Flow(Secure& memory, std::uint64_t flow_id, bool reversed, bool replayed);

        std::uint64_t id;
        bool reverse;
        bool offline;
        Side outbound;
        Side inbound;
        Clock::time_point touched = Clock::now();
        std::size_t buffered = 0;
      };

      using Map = ds::Map<Key, Flow, Secure, Hash>;

    public:
      explicit TcpFlows(ConcurrentMemory& memory);
      // Each flow's buffers allocate from the table's own allocator, so the table stays put.
      TcpFlows(const TcpFlows&) = delete;
      TcpFlows& operator=(const TcpFlows&) = delete;
      TcpFlows(TcpFlows&&) = delete;
      TcpFlows& operator=(TcpFlows&&) = delete;
      ~TcpFlows() = default;

      // Generic over the caller's callbacks, and called for every captured packet.
      template <typename Emit>
      [[tbc::generic]] void packet(const Event& event, Emit emit) {
        const auto parsed = TcpPacketDecoder::decode(event);
        if (parsed) {
          consumePacket(event, *parsed, emit);
        }
      }

      template <typename Emit>
      [[tbc::generic]] void payload(const Event& event, const IpPayload& ip_payload, Emit emit) {
        const auto parsed = TcpPacketDecoder::decodePayload(ip_payload);
        if (parsed) {
          consumePacket(event, *parsed, emit);
        }
      }

      template <typename Emit>
      [[tbc::generic]] void expire(Emit emit, bool stop = false) {
        const auto now = Clock::now();
        Event event;

        flows_.retain([&](const Key& key, const Flow& flow) {
          const bool gap = flow.outbound.gap || flow.inbound.gap;
          const bool expired_gap = (flow.outbound.gap && now - *flow.outbound.gap >= gap_timeout) || (flow.inbound.gap && now - *flow.inbound.gap >= gap_timeout);
          if (!stop && now - flow.touched < idle_timeout && !expired_gap) {
            return true;
          }

          std::string_view reason = gap ? "tcp_gap_timeout" : "idle_timeout";

          if (stop) {
            reason = "capture_stopped";
          }

          announceClose(key, flow, event, {.reason = reason, .gap = gap}, emit);
          buffered_ -= flow.buffered;
          return false;
        });
      }

    private:
      // What a packet brings to one direction of a flow: the flow's key, the packet and the event that
      // carried it.
      struct Arrival {
        const Key& key;
        const TcpPacket& packet;
        const Event& event;
        Direction direction;
      };

      // A flow event to publish and its kind.
      struct Notice {
        Kind kind{};
        FlowEvent item;
      };

      // Why a flow ends, and whether bytes of it went missing.
      struct Ending {
        std::string_view reason;
        bool gap = false;
      };

      // How a segment meets the ones a side holds: a copy of one, bytes that differ from one, or neither.
      enum class Overlap : std::uint8_t {
        none,
        duplicate,
        conflict,
      };

      template <typename Emit>
      [[tbc::generic]] void consumePacket(const Event& event, const TcpPacket& packet, Emit emit) {
        const bool reverse = packet.destination < packet.source;
        Key key{.session = event.session, .interface = event.interface_index, .first = reverse ? packet.destination : packet.source, .second = reverse ? packet.source : packet.destination};

        std::ranges::copy(event.interface, key.name.viewMut().begin());
        auto* found = flows_.findMut(key);
        if (found != nullptr && reused(*found, packet, reverse)) {
          close(key, event, "tuple_reused", emit, false);
          found = nullptr;
        }

        if (found == nullptr) {
          if (flows_.size() == maximum_flows) {
            evictOldest(event, emit);
          }

          const bool initial_reverse = (packet.flags & syn) != 0 && (packet.flags & ack) != 0 ? !reverse : reverse;

          static_cast<void>(flows_.insert(key, Flow{memory_, capture_flow_bit | ++next_, initial_reverse, event.offline}));
          found = flows_.findMut(key);
          if (found == nullptr) {
            return;
          }

          publish(key, *found, event, {.kind = Kind::flow_open}, emit);
          if ((packet.flags & syn) == 0) {
            publish(key, *found, event, {.kind = Kind::flow_gap, .item = {.reason = "capture_started_midstream"}}, emit);
          }
        }

        auto& flow = *found;
        const auto direction = reverse == flow.reverse ? Direction::outbound : Direction::inbound;
        auto& side = direction == Direction::outbound ? flow.outbound : flow.inbound;

        flow.touched = Clock::now();
        if (packet.truncated) {
          close(key, event, "truncated_packet", emit, true);
          return;
        }

        if ((packet.flags & rst) != 0) {
          close(key, event, "reset", emit, false);
          return;
        }

        const auto sequence = packet.sequence + ((packet.flags & syn) != 0 ? 1U : 0U);

        track(side, packet, sequence);
        if (side.closed && !packet.bytes.empty() && distance(sequence + static_cast<std::uint32_t>(packet.bytes.size()), side.next - 1U) > 0) {
          close(key, event, "data_after_fin", emit, true);
          return;
        }

        if (!consume({.key = key, .packet = packet, .event = event, .direction = direction}, flow, buffered_, memory_, emit)) {
          close(key, event, "reassembly_limit_or_overlap", emit, true);
          return;
        }

        auto& consumed = flow;
        if (settle(consumed, direction)) {
          close(key, event, "fin", emit, false);
        }
      }

      // Starts a side at the first sequence it sees, and marks where a FIN ends it: a FIN past the
      // bytes the side has seen leaves a gap until they come.
      [[tbc::hot_path]] inline static void track(Side& side, const TcpPacket& packet, std::uint32_t sequence) noexcept {
        if (!side.started) {
          side.started = true;
          side.initial = side.next = sequence;
        }

        if ((packet.flags & fin) != 0) {
          side.fin = sequence + static_cast<std::uint32_t>(packet.bytes.size());
          if (distance(*side.fin, side.next) > 0 && !side.gap) {
            side.gap = Clock::now();
          }
        }
      }

      // Whether a SYN without ACK opens the flow's tuple anew, at a sequence other than the one it
      // started at.
      [[tbc::hot_path]] inline static bool reused(const Flow& flow, const TcpPacket& packet, bool reverse) noexcept {
        if ((packet.flags & syn) == 0 || (packet.flags & ack) != 0) {
          return false;
        }

        const auto& side = reverse == flow.reverse ? flow.outbound : flow.inbound;

        return side.started && side.initial != packet.sequence + 1U;
      }

      // Ends the flow touched longest ago, for a new one to take its place.
      template <typename Emit>
      [[tbc::generic]] void evictOldest(const Event& event, Emit emit) {
        const Key* oldest = nullptr;
        const Flow* oldest_flow = nullptr;

        for (const auto& entry : flows_) {
          if (oldest_flow == nullptr || entry.value.touched < oldest_flow->touched) {
            oldest = &entry.key;
            oldest_flow = &entry.value;
          }
        }

        if (oldest == nullptr) {
          return;
        }

        // The key is copied before the entry it lies in goes.
        const Key evicted = *oldest;

        close(evicted, event, "flow_limit", emit, true);
      }

      // Closes the direction once its bytes reach its FIN; true when both directions are closed.
      [[tbc::hot_path]] inline static bool settle(Flow& flow, Direction direction) noexcept {
        auto& side = direction == Direction::outbound ? flow.outbound : flow.inbound;
        if (side.fin && side.next == *side.fin && !side.closed) {
          ++side.next;
          side.closed = true;
        }

        return flow.outbound.closed && flow.inbound.closed;
      }

      static std::int32_t distance(std::uint32_t a, std::uint32_t b) noexcept;

      // Reassembles one direction of a flow; the bytes buffered over every flow and the allocator are lent
      // apart from it.
      template <typename Emit>
      [[tbc::generic]] inline static bool consume(const Arrival& arrival, tbc::mut_a<Flow> flow, std::size_t& total_buffered, tbc::mut_a<Secure> memory, Emit emit) {
        const auto& packet = arrival.packet;
        auto& side = arrival.direction == Direction::outbound ? flow.outbound : flow.inbound;
        auto sequence = packet.sequence + ((packet.flags & syn) != 0 ? 1U : 0U);
        auto bytes = packet.bytes;
        const auto behind = distance(side.next, sequence);
        if (behind > 0) {
          const auto skip = std::min(bytes.size(), static_cast<std::size_t>(behind));

          bytes = bytes.subspan(skip);
          sequence += static_cast<std::uint32_t>(skip);
        }

        const auto overlap = compare(side, sequence, bytes);
        if (overlap != Overlap::none) {
          return overlap == Overlap::duplicate;
        }

        if (!bytes.empty() && sequence == side.next) {
          publish(arrival.key, flow, arrival.event, {.kind = Kind::stream_data, .item = {.direction = arrival.direction, .offset = side.offset, .bytes = bytes}}, emit);
          side.next += static_cast<std::uint32_t>(bytes.size());
          side.offset += bytes.size();
        } else if (!bytes.empty() && distance(sequence, side.next) > 0) {
          if (side.pending.size() == maximum_pending_segments || flow.buffered + bytes.size() > per_flow_bytes || total_buffered + bytes.size() > total_bytes) {
            return false;
          }

          side.pending.push({.sequence = sequence, .bytes = Bytes{memory, bytes}});
          flow.buffered += bytes.size();
          total_buffered += bytes.size();
          if (!side.gap) {
            side.gap = Clock::now();
          }
        }

        for (std::size_t index = 0; index < side.pending.size();) {
          const auto& pending = side.pending[index];
          if (distance(pending.sequence, side.next) > 0) {
            ++index;
            continue;
          }

          const auto skip = std::min(pending.bytes.size(), static_cast<std::size_t>((side.next - pending.sequence)));
          const auto ready = std::span<const Byte>{pending.bytes}.subspan(skip);
          if (!ready.empty()) {
            publish(arrival.key, flow, arrival.event, {.kind = Kind::stream_data, .item = {.direction = arrival.direction, .offset = side.offset, .bytes = ready}}, emit);
            side.next += static_cast<std::uint32_t>(ready.size());
            side.offset += ready.size();
          }

          total_buffered -= pending.bytes.size();
          flow.buffered -= pending.bytes.size();
          static_cast<void>(side.pending.remove(index));
          index = 0;
        }

        if (side.pending.empty() && (!side.fin || side.closed || *side.fin == side.next)) {
          side.gap.reset();
        }

        return true;
      }

      [[tbc::hot_path]] inline static Overlap compare(const Side& side, std::uint32_t sequence, std::span<const Byte> bytes) noexcept {
        if (bytes.empty()) {
          return Overlap::none;
        }

        for (const auto& pending : side.pending) {
          if (pending.sequence == sequence && std::ranges::equal(pending.bytes, bytes)) {
            return Overlap::duplicate;
          }

          const auto delta = distance(sequence, pending.sequence);
          if ((delta >= 0 && static_cast<std::size_t>(delta) < pending.bytes.size()) || (delta < 0 && static_cast<std::size_t>(-static_cast<std::int64_t>(delta)) < bytes.size())) {
            const auto incoming = delta < 0 ? static_cast<std::size_t>(-static_cast<std::int64_t>(delta)) : 0;
            const auto queued = delta > 0 ? static_cast<std::size_t>(delta) : 0;
            const auto count = std::min(bytes.size() - incoming, pending.bytes.size() - queued);
            if (!std::ranges::equal(bytes.subspan(incoming, count), std::span<const Byte>{pending.bytes}.subspan(queued, count))) {
              return Overlap::conflict;
            }
          }
        }

        return Overlap::none;
      }

      template <typename Emit>
      [[tbc::generic]] static void publish(const Key& key, const Flow& flow, Event event, Notice notice, Emit emit) {
        const auto client = (flow.reverse ? key.second : key.first).text();
        const auto server = (flow.reverse ? key.first : key.second).text();
        auto& item = notice.item;

        item.id = flow.id;
        item.source = FlowSource::capture;
        item.client = client.view();
        item.server = server.view();
        SensitiveBuffer<Limits::frame_bytes> output;

        event.kind = notice.kind;
        event.session = key.session;
        event.offline = flow.offline;
        event.interface_index = key.interface;
        event.interface = std::string_view{key.name.data(), strnlen(key.name.data(), key.name.size())};
        event.bytes = FlowCodec::encode(output.bytes(), item);
        emit(event);
      }

      // Publishes the end of a flow; the caller drops the flow and the bytes it buffered.
      template <typename Emit>
      [[tbc::generic]] static void announceClose(const Key& key, const Flow& flow, const Event& event, Ending ending, Emit emit) {
        if (flow.outbound.gap) {
          publish(key, flow, event, {.kind = Kind::flow_gap, .item = {.offset = flow.outbound.offset, .reason = ending.reason}}, emit);
        }

        if (flow.inbound.gap) {
          publish(key, flow, event, {.kind = Kind::flow_gap, .item = {.direction = Direction::inbound, .offset = flow.inbound.offset, .reason = ending.reason}}, emit);
        }

        if (ending.gap && !flow.outbound.gap && !flow.inbound.gap) {
          publish(key, flow, event, {.kind = Kind::flow_gap, .item = {.reason = ending.reason}}, emit);
        }

        publish(key, flow, event, {.kind = Kind::flow_close, .item = {.reason = ending.reason}}, emit);
      }

      // Ends the flow of a key this Map holds.
      template <typename Emit>
      [[tbc::generic]] void close(const Key& key, const Event& event, std::string_view reason, Emit emit, bool gap) {
        const auto& flow = *flows_.find(key);

        announceClose(key, flow, event, {.reason = reason, .gap = gap}, emit);
        buffered_ -= flow.buffered;
        static_cast<void>(flows_.remove(key));
      }

      static constexpr Byte fin = 1, syn = 2, rst = 4, ack = 16;
      static constexpr std::size_t maximum_flows = 256;
      static constexpr std::size_t maximum_pending_segments = 32;
      static constexpr std::size_t per_flow_bytes = std::size_t{64} * 1024;
      static constexpr std::size_t total_bytes = std::size_t{8} * 1024 * 1024;
      static constexpr std::uint64_t capture_flow_bit = std::uint64_t{1} << 63U;
      static constexpr auto gap_timeout = std::chrono::seconds{2};
      static constexpr auto idle_timeout = std::chrono::seconds{60};
      Secure memory_;
      tbc::val_self<Map> flows_;
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
      [[tbc::generic]] void packet(const Event& event, Selection selection, Emit emit) {
        fragments_.packet(event, [&](std::span<const Byte> bytes) {
          const auto ip_payload = IpPayload::decode(bytes);
          if (!ip_payload) {
            return;
          }

          if (ip_payload->protocol == IPPROTO_TCP && selects(selection, Selection::flows)) {
            tcp_.payload(event, *ip_payload, emit);
          }

          if (!selects(selection, Selection::datagrams)) {
            return;
          }

          const auto datagram = DatagramCodec::parse(*ip_payload);
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
      [[tbc::generic]] void expire(Emit emit, bool stop = false) {
        fragments_.expire([&](const Event& source, std::string_view reason) {
          fragmentError(source, reason, emit);
        },
            stop);
        tcp_.expire(emit, stop);
      }

    private:
      template <typename Emit>
      [[tbc::generic]] static void fragmentError(Event event, std::string_view reason, Emit emit) {
        event.kind = Kind::error;
        event.bytes = byteView(reason);
        emit(event);
      }

      ConcurrentMemory& memory_;
      IpFragments fragments_;
      TcpFlows tcp_;
    };

  }
}
