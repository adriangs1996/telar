#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.platform.error;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.vocabulary.traffic;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Directory {
    Directory() {
      std::strcpy(path.dataMut(), "/tmp/telar-traffic-endpoint-XXXXXX");
      check(::mkdtemp(path.dataMut()) != nullptr);
    }

    ~Directory() {
      ::rmdir(path.data());
    }

    std::string file(std::string_view name) const {
      return std::string{path.data()} + "/" + std::string{name};
    }

    ds::Array<char, 64> path{};
  };

  // A socket bound at `path` with `mode`, listening unless the caller closes it.
  FileDescriptor listening(const std::string& path, mode_t mode) {
    FileDescriptor socket{::socket(AF_UNIX, SOCK_STREAM, 0)};
    sockaddr_un address{};

    check(static_cast<bool>(socket));
    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path.c_str());
    check(::bind(socket.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    check(::chmod(path.c_str(), mode) == 0);
    check(::listen(socket.get(), 4) == 0);
    return socket;
  }

  template <typename Exception, typename Operation>
  ds::Option<Exception> failure(Operation&& operation) {
    try {
      operation();
    } catch (const Exception& error) {
      return error;
    }

    return ds::none;
  }

  // The root redirect helper and the CLI connect through this to the runtime: an endpoint another
  // local user could have created or opened is refused before a byte is sent.
  void testConnectRefusesUnsafeEndpoints() {
    Directory directory;

    check(failure<std::invalid_argument>([] {
      traffic::connect("relative/traffic.sock");
    }).hasValue());

    check(failure<std::invalid_argument>([&] {
      traffic::connect(directory.file(std::string{"traffic\0.sock", 13}));
    }).hasValue());

    const auto regular = directory.file("regular");

    check(static_cast<bool>(FileDescriptor{::open(regular.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600)}));
    const auto file = failure<SystemError>([&] {
      traffic::connect(regular);
    });

    check(file && file->code() == EACCES);

    const auto shared = directory.file("shared.sock");
    const auto open = listening(shared, 0666);
    const auto exposed = failure<SystemError>([&] {
      traffic::connect(shared);
    });

    check(exposed && exposed->code() == EACCES);

    const auto stale = directory.file("stale.sock");

    listening(stale, 0600).reset();
    check(failure<SystemError>([&] {
      traffic::connect(stale);
    }).hasValue());

    const auto owned = directory.file("owned.sock");
    const auto listener = listening(owned, 0600);
    const auto connected = traffic::connect(owned);

    check(static_cast<bool>(connected));
    for (const auto& path : {regular, shared, stale, owned}) {
      check(::unlink(path.c_str()) == 0);
    }
  }

  // When the runtime closes the channel, a send fails with an error instead of a SIGPIPE that would
  // kill the CLI server or the root redirect helper.
  void testSendAllToClosedPeer() {
    check(::signal(SIGPIPE, SIG_DFL) != SIG_ERR);
    Directory directory;
    const auto path = directory.file("traffic.sock");
    const auto listener = listening(path, 0600);
    const auto connected = traffic::connect(path);

    FileDescriptor{::accept(listener.get(), nullptr, nullptr)}.reset();
    const std::vector<std::uint8_t> frame(1024 * 1024, 0x5a);

    check(failure<SystemError>([&] {
      traffic::sendAll(connected.get(), frame);
    }).hasValue());

    check(::unlink(path.c_str()) == 0);
  }

  const telar::testing::Case case_connect_refuses_unsafe_endpoints{"traffic_endpoint.connect_refuses_unsafe_endpoints", testConnectRefusesUnsafeEndpoints};
  const telar::testing::Case case_send_all_to_closed_peer{"traffic_endpoint.send_all_to_closed_peer", testSendAllToClosedPeer};

}
