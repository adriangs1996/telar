#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstring>
#include <pcap/pcap.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.traffic.control_backend;
import telar.runtime.traffic.control_protocol;
import telar.runtime.vocabulary.frames;
import telar.runtime.vocabulary.traffic;
import telar.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::traffic;
  using telar::Byte;

  // Waits for `socket` to become readable and reads what is there: an empty result is the service
  // closing the connection.
  std::vector<Byte> receiveSome(int socket, std::size_t limit) {
    pollfd descriptor{.fd = socket, .events = POLLIN, .revents = 0};

    check(::poll(&descriptor, 1, 5000) > 0);
    std::vector<Byte> bytes(limit);
    const auto count = ::recv(socket, bytes.data(), bytes.size(), 0);

    check(count >= 0);
    bytes.resize(static_cast<std::size_t>(count));
    return bytes;
  }

  void receiveAll(int socket, std::span<Byte> bytes) {
    while (!bytes.empty()) {
      const auto part = receiveSome(socket, bytes.size());

      check(!part.empty());
      std::ranges::copy(part, bytes.begin());
      bytes = bytes.subspan(part.size());
    }
  }

  std::vector<Byte> receiveFrame(int socket) {
    std::array<Byte, Protocol::prefix_bytes> prefix;

    receiveAll(socket, prefix);
    plugins::FrameReader reader{prefix};
    const auto length = reader.integer<std::uint32_t>();

    check(length <= Limits::frame_bytes);
    std::vector<Byte> frame(length);

    receiveAll(socket, frame);
    return frame;
  }

  // Reads until the service closes the connection, whatever it queued before; the service sends
  // statistics every second to a peer it keeps, so a peer still open after 5 s was kept.
  void closed(int socket) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    while (!receiveSome(socket, 65536).empty()) {
      check(std::chrono::steady_clock::now() < deadline);
    }
  }

  FileDescriptor greeted(const std::string& path, Role role, Selection selection = Selection::packets) {
    auto socket = connect(path);
    std::array<Byte, Protocol::greeting_bytes> greeting;

    sendAll(socket.get(), Protocol::greeting(greeting, role, {}, selection));
    check(Protocol::decode(receiveFrame(socket.get())).kind == Kind::ready);
    return socket;
  }

  void publish(int socket, const traffic::Event& event) {
    std::vector<Byte> output(Limits::frame_bytes);
    const auto body = Protocol::encode(output, event);

    sendAll(socket, Protocol::prefix(body.size()));
    sendAll(socket, body);
  }

  struct Socket {
    Socket() {
      std::strcpy(directory.data(), "/tmp/telar-traffic-service-XXXXXX");
      check(::mkdtemp(directory.data()) != nullptr);
      path = std::string{directory.data()} + "/traffic.sock";
    }

    ~Socket() {
      ::rmdir(directory.data());
    }

    std::array<char, 64> directory{};
    std::string path;
  };

  struct Allocation {
    SystemAllocator system;
    SynchronizedAllocator<SystemAllocator> synchronized{system};
    MemoryAdapter<SynchronizedAllocator<SystemAllocator>> adapter{synchronized};
    ConcurrentMemory& memory = adapter;
  };

  // Any process of the user can connect as an offline producer or a subscriber: each is held to its
  // role, so none can feed subscribers decrypted exchanges or oversized frames.
  void testPeerRoleViolations() {
    Allocation memory;
    Socket socket;
    Service service{memory.memory, socket.path};
    auto watcher = greeted(socket.path, Role::subscribe, Selection::all);

    {
      auto forger = greeted(socket.path, Role::offline_capture);
      const std::array<Byte, 4> forged{'f', 'a', 'k', 'e'};

      publish(forger.get(), traffic::Event{.kind = Kind::exchange, .session = 5, .interface = "forged", .bytes = forged});
      closed(forger.get());
    }

    for (;;) {
      const auto event = Protocol::decode(receiveFrame(watcher.get()));

      check(event.kind != Kind::exchange);
      if (event.kind == Kind::capture_stopped) {
        break;
      }
    }

    {
      auto oversized = greeted(socket.path, Role::offline_capture);

      sendAll(oversized.get(), Protocol::prefix(Limits::frame_bytes + 1));
      closed(oversized.get());
    }

    const std::array<Byte, 4> body{'s', 'u', 'b', 's'};
    std::vector<Byte> output(Limits::frame_bytes);
    const auto frame = Protocol::encode(output, traffic::Event{.link_type = DLT_RAW, .original_bytes = body.size(), .interface = "subscriber", .bytes = body});

    sendAll(watcher.get(), Protocol::prefix(frame.size()));
    sendAll(watcher.get(), frame);
    closed(watcher.get());
  }

  // Interception is off unless the configuration enables it: an intercept peer is refused, and the
  // proxy gets no HTTP control to hand exchanges to.
  void testInterceptionControlViolations() {
    Allocation memory;
    Socket socket;

    {
      Service enabled{memory.memory, socket.path, true};

      check(enabled.http() != nullptr);
      greeted(socket.path, Role::intercept);
    }

    Service disabled{memory.memory, socket.path, false};
    auto peer = connect(socket.path);
    std::array<Byte, Protocol::greeting_bytes> greeting;

    check(disabled.http() == nullptr);
    sendAll(peer.get(), Protocol::greeting(greeting, Role::intercept));
    check(receiveSome(peer.get(), 65536).empty());
  }

  const telar::testing::Case case_peer_role_violations{"traffic_service.peer_role_violations", testPeerRoleViolations};
  const telar::testing::Case case_interception_control_violations{"traffic_service.interception_control_violations", testInterceptionControlViolations};

}
