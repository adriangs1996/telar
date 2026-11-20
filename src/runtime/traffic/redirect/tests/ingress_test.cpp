#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.platform.primitives;
import telar.runtime.traffic.redirect.ingress;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // Admits helpers of the test's own account, as the root policy admits root.
  struct SameUser {
    static bool allows(uid_t uid) noexcept {
      return uid == ::geteuid();
    }
  };

  struct CountingSink {
    std::atomic<unsigned> adopted = 0;

    bool adopt(redirect::Connection) noexcept {
      adopted.fetch_add(1);
      return true;
    }
  };

  using Endpoint = redirect::Ingress<CountingSink, SameUser>;

  struct EndpointDirectory {
    EndpointDirectory() {
      ds::Array<char, 64> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-ingress-test-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      path = directory.data();
    }

    ~EndpointDirectory() {
      std::filesystem::remove_all(path);
    }

    std::string path;
  };

  template <typename Predicate>
  void await(Predicate ready) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    while (!ready()) {
      check(std::chrono::steady_clock::now() < deadline);
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
  }

  FileDescriptor connectEndpoint(const std::string& path) {
    FileDescriptor channel{::socket(AF_UNIX, SOCK_STREAM, 0)};
    sockaddr_un address{};

    address.sun_family = AF_UNIX;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    check(channel && ::connect(channel.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    return channel;
  }

  // Sends `frame` with `descriptors` attached, as a helper hands sockets over.
  void sendFrame(int channel, std::span<const Byte> frame, std::span<const int> descriptors) {
    iovec vector{.iov_base = const_cast<Byte*>(frame.data()), .iov_len = frame.size()};
    ds::Array<char, CMSG_SPACE(sizeof(int) * redirect::Protocol::descriptor_count)> control{};
    msghdr message{};

    message.msg_iov = &vector;
    message.msg_iovlen = 1;
    message.msg_control = control.dataMut();
    message.msg_controllen = static_cast<socklen_t>(CMSG_SPACE(sizeof(int) * descriptors.size()));
    auto* header = CMSG_FIRSTHDR(&message);

    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = static_cast<socklen_t>(CMSG_LEN(sizeof(int) * descriptors.size()));
    std::memcpy(CMSG_DATA(header), descriptors.data(), sizeof(int) * descriptors.size());
    check(::sendmsg(channel, &message, 0) == static_cast<ssize_t>(frame.size()));
  }

  // Whether `socket` reads end of stream within the deadline, with no byte before it.
  bool ends(int socket) {
    pollfd ready{.fd = socket, .events = POLLIN, .revents = 0};
    Byte byte;

    return ::poll(&ready, 1, 5000) == 1 && ::recv(socket, &byte, 1, 0) == 0;
  }

  // A TCP connection to a local listener: the socket whose peer is the redirect target, the accepted
  // end, and the target.
  struct TcpPair {
    TcpPair() {
      FileDescriptor listener{::socket(AF_INET, SOCK_STREAM, 0)};
      sockaddr_in address{};
      socklen_t length = sizeof(address);

      address.sin_family = AF_INET;
      address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
      check(listener && ::bind(listener.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(listener.get(), 1) == 0);
      check(::getsockname(listener.get(), reinterpret_cast<sockaddr*>(&address), &length) == 0);
      origin.reset(::socket(AF_INET, SOCK_STREAM, 0));
      check(origin && ::connect(origin.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
      child.reset(::accept(listener.get(), nullptr, nullptr));
      check(static_cast<bool>(child));
      target = redirect::Target::parse("127.0.0.1:" + std::to_string(ntohs(address.sin_port)));
    }

    FileDescriptor child;
    FileDescriptor origin;
    redirect::Target target;
  };

  // A helper's frame that is not a connection this runtime can take is dropped with every socket it
  // carried, and the endpoint keeps serving the next helper.
  void testMalformedFrames() {
    EndpointDirectory directory;
    const auto path = directory.path + "/redirect";
    CountingSink sink;
    Endpoint ingress{path, sink};
    ds::Array<Byte, redirect::Protocol::frame_bytes> output;

    {
      // Real sockets for a real target, under a magic number from another protocol.
      const TcpPair carried;
      const auto valid = redirect::Protocol::encode(output.viewMut(), redirect::Kind::connection, carried.target);
      std::vector<Byte> wrong_magic{valid.begin(), valid.end()};
      const ds::Array descriptors{carried.child.get(), carried.origin.get()};
      auto channel = connectEndpoint(path);

      wrong_magic[0] ^= 0xff;
      sendFrame(channel.get(), wrong_magic, descriptors);
      check(ends(channel.get()));
    }

    {
      // A connection frame with one socket where two belong: the runtime must close the one it got.
      const TcpPair carried;
      const auto frame = redirect::Protocol::encode(output.viewMut(), redirect::Kind::connection, carried.target);
      ds::Array<int, 2> pair;

      check(::socketpair(AF_UNIX, SOCK_STREAM, 0, pair.dataMut()) == 0);
      FileDescriptor passed{pair[0]};
      FileDescriptor kept{pair[1]};
      const ds::Array descriptors{passed.get()};
      auto channel = connectEndpoint(path);

      sendFrame(channel.get(), frame, descriptors);
      passed.reset();
      check(ends(channel.get()) && ends(kept.get()));
    }

    check(sink.adopted.load() == 0);

    TcpPair accepted;
    auto channel = connectEndpoint(path);

    redirect::Protocol::send(channel.get(), redirect::Connection{.child = std::move(accepted.child), .origin = std::move(accepted.origin), .target = accepted.target});
    await([&] {
      return sink.adopted.load() == 1;
    });
  }

  // Greets the endpoint as a monitor and returns the channel once the runtime answers, or an empty
  // descriptor when it closes instead.
  FileDescriptor monitor(const std::string& path) {
    auto channel = connectEndpoint(path);
    ds::Array<Byte, redirect::Protocol::frame_bytes> output;
    const auto hello = redirect::Protocol::encode(output.viewMut(), redirect::Kind::monitor, {});

    check(::send(channel.get(), hello.data(), hello.size(), 0) == static_cast<ssize_t>(hello.size()));
    ds::Array<Byte, sizeof(std::uint32_t)> uid;
    pollfd ready{.fd = channel.get(), .events = POLLIN, .revents = 0};

    check(::poll(&ready, 1, 5000) == 1);
    if (::recv(channel.get(), uid.dataMut(), uid.size(), MSG_WAITALL) != static_cast<ssize_t>(uid.size())) {
      return FileDescriptor{};
    }

    return channel;
  }

  // One helper owns the endpoint: while it is active a second helper's greeting is refused, and the
  // first stays in charge.
  void testSingleMonitor() {
    EndpointDirectory directory;
    const auto path = directory.path + "/redirect";
    CountingSink sink;
    Endpoint ingress{path, sink};
    auto first = monitor(path);

    check(static_cast<bool>(first));
    const auto active = static_cast<Byte>(redirect::MonitorUpdate::active);

    check(::send(first.get(), &active, 1, 0) == 1);
    await([&] {
      return ingress.status() == redirect::MonitorState::active;
    });

    check(!monitor(path));
    check(ingress.status() == redirect::MonitorState::active);
  }

  const telar::testing::Case case_malformed_frames{"redirect_ingress.malformed_frames", testMalformedFrames};
  const telar::testing::Case case_single_monitor{"redirect_ingress.single_monitor", testSingleMonitor};

}
