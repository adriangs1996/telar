#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.base.ds;
import telar.platform.listening;
import telar.platform.primitives;
import telar.testing;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::runtime;

  bool listens(std::uint16_t port) {
    ds::Array<std::uint16_t, 512> ports{};
    const auto found = ports.viewMut().first(userListeningPorts(::getuid(), ports.viewMut()));

    check(std::ranges::is_sorted(found) && std::ranges::adjacent_find(found) == found.end(), "ports come once each and ascending");
    return std::ranges::binary_search(found, port);
  }

  // A port this process listens on is one of its user's, until the socket closes.
  void aUsersListeningPortsAreItsProcesses() {
    sockaddr_in address{};
    socklen_t length = sizeof(address);
    FileDescriptor socket{::socket(AF_INET, SOCK_STREAM, 0)};

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(::bind(socket.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    check(::getsockname(socket.get(), reinterpret_cast<sockaddr*>(&address), &length) == 0);
    const auto port = ntohs(address.sin_port);

    check(!listens(port), "a bound socket that does not listen is no listening port");
    check(::listen(socket.get(), 1) == 0);
    check(listens(port));
    socket.reset();
    check(!listens(port));
  }

  const telar::testing::Case case_a_users_listening_ports_are_its_processes{"listening.a_users_listening_ports_are_its_processes", aUsersListeningPortsAreItsProcesses};

}
