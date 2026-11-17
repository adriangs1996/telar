#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.client;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // The client's socket is never inherited by a program the process runs, and it is closed once,
  // by whichever client owns it last.
  void testClientSocket() {
    std::array<char, 64> temporary{};

    std::strcpy(temporary.data(), "/tmp/telar-client-test-XXXXXX");
    check(::mkdtemp(temporary.data()) != nullptr);
    const std::string root = temporary.data();
    const auto path = root + "/runtime.sock";
    const int listener = ::socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};

    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path.c_str());
    check(listener >= 0 && ::bind(listener, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(listener, 4) == 0);

    int descriptor = -1;

    {
      auto client = Client::init(path.c_str());

      descriptor = client.descriptor();
      check(descriptor >= 0 && (::fcntl(descriptor, F_GETFD) & FD_CLOEXEC) != 0);
      Client moved{std::move(client)};

      check(client.descriptor() == -1 && moved.descriptor() == descriptor);
      Client assigned = Client::init(path.c_str());
      const auto replaced = assigned.descriptor();

      assigned = std::move(moved);
      check(assigned.descriptor() == descriptor && ::fcntl(replaced, F_GETFD) == -1 && errno == EBADF);
    }

    check(::fcntl(descriptor, F_GETFD) == -1 && errno == EBADF);

    ::close(listener);
    std::filesystem::remove_all(root);
  }

  const telar::testing::Case case_client_socket{"client.socket_lifetime", testClientSocket};

}
