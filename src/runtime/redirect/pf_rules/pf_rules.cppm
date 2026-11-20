export module telar.runtime.redirect.pf_rules;

import std;
import telar.tbc;
import telar.sys.posix;

import telar.runtime.redirect.direction;

import telar.runtime.redirect.ingress;

import telar.platform.primitives;
import telar.vocabulary;
import telar.sys.socket;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: redirect/flow_key.cppm
export {
  namespace telar::runtime::redirect {

    struct FlowKey {
      Target source;
      Target destination;

      [[nodiscard]] bool matches(const FlowKey& other) const noexcept;

      static bool same(const Target& left, const Target& right) noexcept;

      static ds::Option<FlowKey> syn(std::span<const Byte> frame);

    private:
      static std::uint16_t number(std::span<const Byte> bytes, std::size_t offset) noexcept;

      static Target endpoint(unsigned family, std::span<const Byte> bytes, std::uint16_t port);
    };

  }
}

// pf's NAT lookup, the routing socket and pf's rules exist on macOS only; a flow's key is
// shared with the Linux socket table.
#ifdef __APPLE__

// Interface: redirect/nat_lookup.cppm
export {
  namespace telar::runtime::redirect {

    class NatLookup {
      // Darwin pfioc_natlook, including four 32-bit pf_state_xport unions.
      struct Request {
        ds::Array<Byte, 16> source{};
        ds::Array<Byte, 16> destination{};
        ds::Array<Byte, 16> translated_source{};
        ds::Array<Byte, 16> translated_destination{};
        std::uint32_t source_port = 0;
        std::uint32_t destination_port = 0;
        std::uint32_t translated_source_port = 0;
        std::uint32_t translated_destination_port = 0;
        std::uint8_t family = 0;
        std::uint8_t protocol = IPPROTO_TCP;
        std::uint8_t variant = 0;
        std::uint8_t direction = 2; // PF_OUT: reverse lookup from accepted socket.
      };

      static_assert(sizeof(Request) == 84);
      static constexpr unsigned long lookup = sys::ioctlReadWrite<Request>('D', 23);

    public:
      NatLookup();

      [[nodiscard]] bool matches(int socket, const FlowKey& flow) const;

      static bool peerMatches(int socket, const FlowKey& flow);

    private:
      static void address(const sockaddr_storage& socket, std::span<Byte, 16> bytes, std::uint32_t& port);

      FileDescriptor device_;
    };

  }
}

// Interface: redirect/route_path.cppm
export {
  namespace telar::runtime::redirect {

    struct RoutePath {
      FixedText<IFNAMSIZ> interface;
      FixedText<INET6_ADDRSTRLEN> gateway;
      unsigned index = 0;

      static RoutePath lookup(const Target& target, unsigned scope = 0);

      static RoutePath decode(std::span<const Byte> bytes, const Target& target);

    private:
      static constexpr std::size_t maximum_message_bytes = 4096;
      static constexpr std::size_t address_alignment = sizeof(std::uint32_t);

      static std::size_t aligned(std::size_t size) noexcept;

      static void addressText(FixedText<INET6_ADDRSTRLEN>& target, int family, const void* address);
    };

  }
}

// Interface: redirect/pf_rules.cppm
export {
  namespace telar::runtime::redirect {

    struct Mapping {
      Target target;
      std::uint16_t listener_port = 0;
      bool incoming = false;

      // Established inbound packets can hit NAT state on the physical interface;
      // preserve the local IP so their translated destination remains deliverable.
      [[nodiscard]] std::string_view listenerAddress() const noexcept;
    };

    struct Bypass {
      FlowKey key;
      RoutePath route;
    };

    struct PfScope {
      uid_t uid;
      std::string_view label;
      std::string_view discovery_interface;
      std::span<const FlowKey> flows;
      ds::Option<unsigned> log_interface;
      std::span<const Bypass> bypasses;
      bool log_all = false;
      Direction direction = Direction::outbound;
      std::span<const FlowKey> incoming_flows;
    };

    template <Allocator Memory>
    class PfIdentity {
    public:
      explicit PfIdentity(Memory& memory, std::string_view endpoint);

      ds::String<Memory> anchor;
      ds::String<Memory> label;
    };

    extern template class PfIdentity<Memory>;
    extern template class PfIdentity<ConcurrentMemory>;

    template <Allocator Memory>
    tbc::val_a<ds::String<Memory>> pfRules(tbc::mut_a<Memory> memory, std::span<const Mapping> mappings, const PfScope& scope);
    extern template ds::String<Memory> pfRules<Memory>(Memory& memory, std::span<const Mapping> mappings, const PfScope& scope);
    extern template ds::String<ConcurrentMemory> pfRules<ConcurrentMemory>(ConcurrentMemory& memory, std::span<const Mapping> mappings, const PfScope& scope);

  }
}

#endif
