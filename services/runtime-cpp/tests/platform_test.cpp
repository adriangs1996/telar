#include "check.hpp"
#include "platform/child_descriptors.hpp"
#include "platform/command.hpp"
#include "platform/event_loop.hpp"
#include "platform/local_listener.hpp"
#include "platform/process_probe.hpp"
#include "transport/connection.hpp"
#include <chrono>
#include <csignal>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <termios.h>

using namespace telar;
using namespace telar::runtime;

static void testSpawn(SystemAllocator &memory) {
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf 'spawn-ok'"};
  Command command{memory, Launch{.cwd = "/tmp",
                                 .arguments = arguments}};
  PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
  pollfd ready{.fd = process.descriptor(),
               .events = POLLIN,
               .revents = 0};
  check(::poll(&ready, 1, 2000) == 1);
  std::array<char, 64> output{};
  const auto count = ::read(process.descriptor(), output.data(), output.size());
  check(count == 8);
  check(std::string_view{output.data(), static_cast<std::size_t>(count)} == "spawn-ok");

  bool rejected = false;
  const std::array<std::string_view, 1> missing{"/does/not/exist"};
  Command missing_command{memory, Launch{.cwd = "/tmp",
                                         .arguments = missing}};

  try {
    PtyProcess invalid{missing_command.specification(TerminalSize{80, 24, 0, 0})};
  } catch (const SystemError &error) {
    rejected = error.code() == ENOENT;
  }

  check(rejected);
}

static void testForegroundProcessGroup(SystemAllocator &memory) {
  const std::array<std::string_view, 1> arguments{"/bin/cat"};
  Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
  PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
  for (unsigned iteration = 0; iteration < 100; ++iteration) {
    check(process.foregroundProcessGroup() == ::tcgetpgrp(process.descriptor()));
    check(process.foregroundProcessGroup() == process.processId());
  }
}

static void testUnreadOutputShutdown() {
  const auto child = ::fork();
  check(child >= 0);
  if (child == 0) {
    ::alarm(5);
    SystemAllocator memory;
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf 'unread-output'; exec /bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

    for (unsigned iteration = 0; iteration < 20; ++iteration) {
      PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
      pollfd ready{.fd = process.descriptor(), .events = POLLIN};
      if (::poll(&ready, 1, 2000) != 1) {
        _exit(1);
      }
    }

    _exit(0);
  }

  int status = 0;
  while (::waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  check(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void testFraming(SystemAllocator &memory) {
  int sockets[2];
  check(::socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
  FileDescriptor peer{sockets[1]};
  setNonblocking(sockets[0]);
  Connection connection{memory, FileDescriptor{sockets[0]}};
  const auto hello = HandshakeCodec::encode(ClientHello{});
  std::array<Byte, frame_prefix_size> prefix{};
  std::span<Byte> writer = prefix;
  u32::encode(hello.size(), writer);

  check(::write(peer.get(), prefix.data(), 2) == 2);
  check(connection.read());
  bool received = false;
  const auto dispatch = [&](std::span<const Byte> payload, DecodeStorage &) {
    received = true;
    check(HandshakeCodec::decode<ClientHello>(payload).schema == handshake::schema_id);
    connection.send(RequestCompleted{.request_id = 17});
  };
  check(!connection.dispatch(dispatch));
  check(!received);
  check(::write(peer.get(), prefix.data() + 2, 2) == 2);
  check(::write(peer.get(), hello.data(), hello.size()) == static_cast<ssize_t>(hello.size()));
  check(connection.read());
  connection.dispatch(dispatch);
  check(received);
  connection.write();
  std::array<Byte, 64> response{};
  const auto count = ::read(peer.get(), response.data(), response.size());
  check(count == static_cast<ssize_t>(frame_prefix_size + MessageSchema<RequestCompleted>::payload_size));
  std::array<Byte, 64> scratch;
  DecodeStorage storage{scratch};
  const auto accepted = Codec::decode<RequestCompleted>(std::span<const Byte>{response}.subspan(frame_prefix_size, MessageSchema<RequestCompleted>::payload_size), storage);
  check(accepted.request_id == 17);

  for (unsigned index = 0; index < 2; ++index) {
    check(::write(peer.get(), prefix.data(), prefix.size()) == static_cast<ssize_t>(prefix.size()));
    check(::write(peer.get(), hello.data(), hello.size()) == static_cast<ssize_t>(hello.size()));
  }
  check(connection.read());
  unsigned requests = 0;
  const auto pause_after_request = [&](std::span<const Byte> payload, DecodeStorage &) {
    check(std::ranges::equal(payload, hello));
    ++requests;
    connection.read_paused = true;
  };
  check(connection.dispatch(pause_after_request));
  check(requests == 1);
  check(connection.dispatch(pause_after_request));
  check(requests == 1);
  connection.read_paused = false;
  check(!connection.dispatch(pause_after_request));
  check(requests == 2);
}

static void testDescriptorHoles() {
  const auto child = ::fork();
  check(child >= 0);
  if (child == 0) {
    ::close(STDIN_FILENO);
    ::close(STDOUT_FILENO);
    ::close(STDERR_FILENO);
    try {
      SystemAllocator memory;
      testSpawn(memory);
      testForegroundProcessGroup(memory);
      _exit(0);
    } catch (...) {
      _exit(1);
    }
  }

  int status = 0;
  while (::waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  check(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

static void testInheritedDescriptors() {
  FileDescriptor source{::open("/dev/null", O_RDONLY)};
  check(static_cast<bool>(source));
  FileDescriptor high{::fcntl(source.get(), F_DUPFD, 4096)};
  check(static_cast<bool>(high));

  const auto child = ::fork();
  check(child >= 0);
  if (child == 0) {
    closeChildDescriptors(source.get(), getdtablesize());
    const bool closed = ::fcntl(high.get(), F_GETFD) < 0 && errno == EBADF;
    const bool retained = ::fcntl(source.get(), F_GETFD) >= 0;
    _exit(closed && retained ? 0 : 1);
  }

  int status = 0;
  while (::waitpid(child, &status, 0) < 0 && errno == EINTR) {
  }
  check(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  check(::fcntl(high.get(), F_GETFD) >= 0);
}

static void testSocketOwnership() {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-socket-test-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const auto path = std::string{directory.data()} + "/runtime.sock";

  {
    LocalListener listener{path};
    bool rejected = false;
    try {
      LocalListener duplicate{path};
    } catch (const SystemError &) {
      rejected = true;
    }
    check(rejected);
    struct stat state{};
    check(::lstat(path.c_str(), &state) == 0 && S_ISSOCK(state.st_mode));
    check((state.st_mode & 0777) == 0600);
    check(::unlink(path.c_str()) == 0);
    FileDescriptor replacement{::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600)};
    check(static_cast<bool>(replacement));
  }

  struct stat state{};
  check(::lstat(path.c_str(), &state) == 0 && S_ISREG(state.st_mode));
  bool rejected = false;
  try {
    LocalListener listener{path};
  } catch (const SystemError &) {
    rejected = true;
  }
  check(rejected);
  check(::unlink(path.c_str()) == 0);
  check(::unlink((path + ".lock").c_str()) == 0);
  check(::rmdir(directory.data()) == 0);
}

static void testDisconnectedSocketClients() {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-disconnected-socket-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const auto path = std::string{directory.data()} + "/runtime.sock";
  bool setup_failed = false;

  {
    LocalListener listener{path};
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path.c_str());

    constexpr unsigned attempts = 100;
    for (unsigned index = 0; index < attempts; ++index) {
      FileDescriptor abandoned{::socket(AF_UNIX, SOCK_STREAM, 0)};
      check(static_cast<bool>(abandoned));
      check(::connect(abandoned.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
      abandoned.reset();

      try {
        auto closed = listener.accept();
        if (closed) {
          char byte = 0;
          check(::recv(closed.get(), &byte, sizeof(byte), 0) == 0);
        }
      } catch (const SystemError &) {
        setup_failed = true;
      }

      FileDescriptor client{::socket(AF_UNIX, SOCK_STREAM, 0)};
      check(static_cast<bool>(client));
      check(::connect(client.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0);
      auto connected = listener.accept();
      check(static_cast<bool>(connected));
      check((::fcntl(connected.get(), F_GETFD) & FD_CLOEXEC) != 0);
      check((::fcntl(connected.get(), F_GETFL) & O_NONBLOCK) != 0);
#if defined(SO_NOSIGPIPE)
      int suppressed = 0;
      socklen_t length = sizeof(suppressed);
      check(::getsockopt(connected.get(), SOL_SOCKET, SO_NOSIGPIPE, &suppressed, &length) == 0);
      check(length == sizeof(suppressed) && suppressed == 1);
#endif
      constexpr char request = 'Q';
      constexpr char response = 'R';
      check(::write(client.get(), &request, sizeof(request)) == sizeof(request));
      char received = 0;
      check(::read(connected.get(), &received, sizeof(received)) == sizeof(received) && received == request);
      check(::write(connected.get(), &response, sizeof(response)) == sizeof(response));
      check(::read(client.get(), &received, sizeof(received)) == sizeof(received) && received == response);
    }
  }

  check(::unlink((path + ".lock").c_str()) == 0);
  check(::rmdir(directory.data()) == 0);
  check(!setup_failed);
}

static void testChildExitNotification() {
  SystemAllocator memory;
  struct sigaction previous{};
  check(::sigaction(SIGCHLD, nullptr, &previous) == 0);
  {
    NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
    poller.watchSignal(SIGCHLD);
    const auto child = ::fork();
    check(child >= 0);
    if (child == 0) {
      _exit(7);
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
    bool observed = false;
    while (!observed && std::chrono::steady_clock::now() < deadline) {
      for (const auto &event : poller.wait(std::chrono::milliseconds{100})) {
        observed |= event.kind == EventKind::signal && event.descriptor == SIGCHLD;
      }
    }

    check(observed);
    int status = 0;
    check(::waitpid(child, &status, 0) == child);
    check(WIFEXITED(status) && WEXITSTATUS(status) == 7);
  }
  check(::sigaction(SIGCHLD, &previous, nullptr) == 0);
}

void testPlatform() {
  testDisconnectedSocketClients();
  SystemAllocator memory;
  testSpawn(memory);
  testForegroundProcessGroup(memory);
  testUnreadOutputShutdown();
  testFraming(memory);
  testDescriptorHoles();
  testInheritedDescriptors();
  testSocketOwnership();
  testChildExitNotification();
  ProcessInspector inspector;
  ProcessProbe probe{inspector};
  ProcessProbe<ProcessInspector>::Request request;
  request.panes[0] = {1, 2, 3, ::getpid(), ::getpid()};
  request.count = 1;
  const auto observed = probe.observe(request);
  check(observed.count == 1 && observed.panes[0].identity == inspector.identity(::getpid()));
  check(observed.panes[0].name.view() == "runtime-tests");
  check(!observed.panes[0].cwd.view().empty() && observed.panes[0].cwd.view().front() == '/');
  request.panes[0].foreground = -1;
  check(probe.observe(request).count == 0);
}
