#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

import std;
import telar.testing;
import telar.runtime.redirect.direction;
import telar.runtime.redirect.ingress;
import telar.runtime.redirect.pf_rules;
import telar.runtime.redirect.socket_owners;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  template <typename Operation>
  bool refuses(Operation&& operation) {
    try {
      operation();
    } catch (const std::invalid_argument&) {
      return true;
    }

    return false;
  }

  // The root helper reads `--process` from its argv: a token that names no real PID, or pins it to
  // a creation time that cannot exist, is refused instead of selecting some other process.
  void testProcessTokenParse() {
    for (const auto token : {"0", "2147483648", "x", "12@", "12@5", "12@0.1", "12@1.1000000", "12@1.-1"}) {
      check(refuses([&] {
        static_cast<void>(redirect::ProcessToken::parse(token));
      }),
          token);
    }

    const auto unpinned = redirect::ProcessToken::parse("12");

    check(unpinned.pid == 12 && unpinned.started_seconds == 0);

    const auto pinned = redirect::ProcessToken::parse("12@1.000001");

    check(pinned.pid == 12 && pinned.started_seconds == 1 && pinned.started_microseconds == 1);
  }

  struct Extension {
    Byte kind;
    std::size_t bytes;
  };

  // A utun frame carrying an IPv6 SYN from [::1]:55001 to [::1]:443 behind `extensions`.
  std::vector<Byte> ipv6Syn(std::span<const Extension> extensions) {
    std::vector<Byte> chain;

    for (std::size_t index = 0; index < extensions.size(); ++index) {
      const auto& extension = extensions[index];
      const auto offset = chain.size();

      chain.resize(offset + extension.bytes);
      chain[offset] = index + 1 == extensions.size() ? Byte{IPPROTO_TCP} : extensions[index + 1].kind;
      chain[offset + 1] = static_cast<Byte>(extension.kind == IPPROTO_AH ? extension.bytes / 4 - 2 : extension.bytes / 8 - 1);
    }

    const auto encoded = htonl(AF_INET6);
    std::vector<Byte> frame(sizeof(encoded) + 40);

    std::memcpy(frame.data(), &encoded, sizeof(encoded));
    frame.insert(frame.end(), chain.begin(), chain.end());
    frame.resize(frame.size() + 20);
    auto* ip = frame.data() + sizeof(encoded);
    const auto payload = chain.size() + 20;

    ip[0] = 0x60;
    ip[4] = static_cast<Byte>(payload >> 8);
    ip[5] = static_cast<Byte>(payload);
    ip[6] = extensions.empty() ? Byte{IPPROTO_TCP} : extensions.front().kind;
    ip[23] = 1;
    ip[39] = 1;
    auto* tcp = ip + 40 + chain.size();

    tcp[0] = 0xd6;
    tcp[1] = 0xd9;
    tcp[2] = 0x01;
    tcp[3] = 0xbb;
    tcp[12] = 0x50;
    tcp[13] = 0x02;
    return frame;
  }

  // Inbound discovery reads SYNs from remote peers: one behind IPv6 extension headers still names its
  // flow, while an unbounded chain or a header that runs past the packet names none.
  void testSynExtensionHeaders() {
    const std::array chain{
        Extension{IPPROTO_HOPOPTS, 8},
        Extension{IPPROTO_ROUTING, 24},
        Extension{IPPROTO_DSTOPTS, 16},
        Extension{IPPROTO_AH, 24},
    };
    const auto key = redirect::FlowKey::syn(ipv6Syn(chain));

    check(key && key->source.port == 55001 && key->destination.port == 443 && key->destination.host.view() == "::1");

    const std::vector<Extension> long_chain(9, Extension{IPPROTO_DSTOPTS, 8});

    check(!redirect::FlowKey::syn(ipv6Syn(long_chain)));

    auto overrun = ipv6Syn(std::array{Extension{IPPROTO_DSTOPTS, 8}});

    overrun[4 + 40 + 1] = 255;
    check(!redirect::FlowKey::syn(overrun));
  }

  // The runtime writes a direction into the root helper's argv and the helper reads it back: every
  // direction survives the trip, and a name neither writes is refused.
  void testDirectionNames() {
    for (const auto direction : {redirect::Direction::outbound, redirect::Direction::inbound, redirect::Direction::both}) {
      check(redirect::parseDirection(redirect::directionName(direction)) == direction);
    }

    check(refuses([] {
      static_cast<void>(redirect::parseDirection("sideways"));
    }));
  }

  // Redirecting incoming traffic needs a destination this machine serves: with only remote targets
  // it is refused before any rule is planned.
  void testLocalAddressSelection() {
    const std::array targets{redirect::Target::parse("192.0.2.1:443")};

    check(refuses([&] {
      static_cast<void>(redirect::LocalAddresses::selection(targets, redirect::Direction::both));
    }));
  }

  const telar::testing::Case case_process_token_parse{"redirect.process_token_parse", testProcessTokenParse};
  const telar::testing::Case case_syn_extension_headers{"redirect.syn_extension_headers", testSynExtensionHeaders};
  const telar::testing::Case case_direction_names{"redirect.direction_names", testDirectionNames};
  const telar::testing::Case case_local_address_selection{"redirect.local_address_selection", testLocalAddressSelection};

}
