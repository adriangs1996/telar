#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cstring>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.redirect.direction;
import telar.runtime.redirect.ingress;
import telar.runtime.redirect.pf_rules;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace redir = telar::runtime::redirect;

  // The rules are loaded as root: a scope that would point a listener at itself, carry a flow no
  // mapping covers, or route a bypass through a gateway pf cannot read is refused before any rule
  // text exists.
  void testScopeGuards() {
    telar::testing::TestMemory adapter;
    Memory& memory = adapter;
    redir::PfIdentity identity{memory, "/tmp/fixture.sock.redirect"};
    const ds::Array<redir::Mapping, 1> mappings{{{redir::Target::parse("192.0.2.1:443"), 53001, true}}};
    const ds::Array covered{redir::FlowKey{.source = redir::Target::parse("192.0.2.2:55001"), .destination = mappings[0].target}};
    const ds::Array outside{redir::FlowKey{.source = redir::Target::parse("192.0.2.2:55001"), .destination = redir::Target::parse("192.0.2.9:443")}};
    const redir::PfScope base{.uid = 501, .label = identity.label, .discovery_interface = "utun0", .flows = covered, .direction = redir::Direction::both, .incoming_flows = covered};

    auto refused = [&](std::span<const redir::Mapping> scoped, const redir::PfScope& scope) {
      try {
        static_cast<void>(redir::pfRules(memory, scoped, scope));
      } catch (const std::invalid_argument&) {
        return true;
      }

      return false;
    };

    check(!refused(mappings, base));

    const ds::Array<redir::Mapping, 1> loopback{{{redir::Target::parse("127.0.0.1:53001"), 53001, true}}};

    check(refused(loopback, {.uid = 501, .label = identity.label, .discovery_interface = "utun0", .direction = redir::Direction::both}));

    auto outbound = base;

    outbound.flows = outside;
    check(refused(mappings, outbound));

    // An incoming flow must reach a destination redirected for incoming traffic, not merely one
    // that outgoing traffic is redirected for.
    const ds::Array<redir::Mapping, 2> mixed{{mappings[0], {redir::Target::parse("192.0.2.5:443"), 53002, false}}};
    const ds::Array outgoing_only{redir::FlowKey{.source = redir::Target::parse("192.0.2.2:55001"), .destination = mixed[1].target}};
    auto incoming = base;

    incoming.incoming_flows = outgoing_only;
    check(refused(mixed, incoming));

    redir::Bypass bypass{.key = covered[0]};

    bypass.route.interface.assign("en0");
    bypass.route.gateway.assign("192.0.2.254");
    auto routed = base;

    routed.bypasses = std::span{&bypass, 1};
    check(!refused(mappings, routed));

    bypass.route.gateway.assign("gateway.local");
    check(refused(mappings, routed));
  }

  // A routing reply as the kernel writes it for a route through a gateway: the header, then the
  // destination and the gateway.
  template <typename Address>
  std::vector<Byte> routeReply(const Address& destination, const Address& gateway) {
    rt_msghdr header{};
    const auto length = sizeof(header) + 2 * sizeof(Address);

    header.rtm_msglen = static_cast<std::uint16_t>(length);
    header.rtm_version = RTM_VERSION;
    header.rtm_type = RTM_GET;
    header.rtm_flags = RTF_UP | RTF_GATEWAY;
    header.rtm_index = static_cast<std::uint16_t>(::if_nametoindex("lo0"));
    header.rtm_addrs = RTA_DST | RTA_GATEWAY;
    std::vector<Byte> bytes(length);

    std::memcpy(bytes.data(), &header, sizeof(header));
    std::memcpy(bytes.data() + sizeof(header), &destination, sizeof(Address));
    std::memcpy(bytes.data() + sizeof(header) + sizeof(Address), &gateway, sizeof(Address));
    return bytes;
  }

  // A bypass routes a flow through the gateway its route names: the gateway is read from the reply,
  // and an IPv6 link-local one loses the interface scope Darwin embeds in it, which pf would not
  // read as an address.
  void testRouteReplyDecode() {
    sockaddr_in destination{.sin_len = sizeof(sockaddr_in), .sin_family = AF_INET};
    sockaddr_in gateway{.sin_len = sizeof(sockaddr_in), .sin_family = AF_INET};

    check(::inet_pton(AF_INET, "192.0.2.1", &destination.sin_addr) == 1 && ::inet_pton(AF_INET, "192.0.2.254", &gateway.sin_addr) == 1);
    const auto ipv4 = redir::RoutePath::decode(routeReply(destination, gateway), redir::Target::parse("192.0.2.1:443"));

    check(ipv4.gateway.view() == "192.0.2.254" && ipv4.interface.view() == "lo0");

    sockaddr_in6 destination6{.sin6_len = sizeof(sockaddr_in6), .sin6_family = AF_INET6};
    sockaddr_in6 gateway6{.sin6_len = sizeof(sockaddr_in6), .sin6_family = AF_INET6};

    check(::inet_pton(AF_INET6, "2001:db8::1", &destination6.sin6_addr) == 1 && ::inet_pton(AF_INET6, "fe80:4::1", &gateway6.sin6_addr) == 1);
    const auto ipv6 = redir::RoutePath::decode(routeReply(destination6, gateway6), redir::Target::parse("[2001:db8::1]:443"));

    check(ipv6.gateway.view() == "fe80::1");
  }

  const telar::testing::Case case_scope_guards{"pf_rules.scope_guards", testScopeGuards};
  const telar::testing::Case case_route_reply_decode{"pf_rules.route_reply_decode", testRouteReplyDecode};

}
