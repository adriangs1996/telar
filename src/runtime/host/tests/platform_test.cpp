#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <cerrno>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <csignal>
#endif
#if (defined(__linux__))
#include <fcntl.h>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__))
#include <unistd.h>
#endif
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#if (defined(__APPLE__))
#include <libproc.h>
#endif
#if (!(defined(__APPLE__)))
#include <linux/close_range.h>
#endif
#if (!(defined(__APPLE__)))
#include <sys/syscall.h>
#endif
#include <cassert>
#include <cerrno>
#include <csignal>
#include <cstddef>
#include <poll.h>
#include <pwd.h>
#include <spawn.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <termios.h>

import std;
import telar.base.memory.allocators;
import telar.git.checkout;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.host.event_loop;
import telar.runtime.host.local_listener;
import telar.runtime.host.process_probe;
import telar.platform.error;
import telar.platform.process;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testSpawn(SystemAllocator& memory) {
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf 'spawn-ok'"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};
    pollfd ready{.fd = process.descriptor(), .events = POLLIN, .revents = 0};

    check(::poll(&ready, 1, 2000) == 1);
    ds::Array<char, 64> output{};
    const auto count = ::read(process.descriptor(), output.dataMut(), output.size());

    check(count == 8);
    check(std::string_view{output.data(), static_cast<std::size_t>(count)} == "spawn-ok");

    bool rejected = false;
    const ds::Array<std::string_view, 1> missing{"/does/not/exist"};
    Command missing_command{memory, Launch{.cwd = "/tmp", .arguments = missing}};

    try {
      PtyProcess invalid{missing_command.specification(TerminalSize{80, 24, 0, 0})};
    } catch (const SystemError& error) {
      rejected = error.code() == ENOENT;
    }

    check(rejected);
  }

  void testForegroundProcessGroup(SystemAllocator& memory) {
    const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};
    PtyProcess process{command.specification(TerminalSize{80, 24, 0, 0})};

    for (unsigned iteration = 0; iteration < 100; ++iteration) {
      check(process.foregroundProcessGroup() == process.processId());
    }
  }

  void testUnreadOutputShutdown() {
    const auto child = ::fork();

    check(child >= 0);
    if (child == 0) {
      ::alarm(5);
      SystemAllocator memory;
      const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "printf 'unread-output'; exec /bin/cat"};
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

  void testDescriptorHoles() {
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

  void testInheritedDescriptors() {
    FileDescriptor source{::open("/dev/null", O_RDONLY)};

    check(static_cast<bool>(source));
    FileDescriptor high{::fcntl(source.get(), F_DUPFD, 4096)};

    check(static_cast<bool>(high));

    const auto child = ::fork();

    check(child >= 0);
    if (child == 0) {
      closeChildDescriptors({.retained = source.get(), .limit = getdtablesize()});
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

  // A child spawned with keepStandardStreams sees this process's stdout and stderr, the stdin a
  // redirect placed, and none of the other descriptors this process left open across exec.
  void testStandardStreamsOnly() {
    ds::Array<int, 2> pipe{};

    check(::pipe(pipe.dataMut()) == 0);

    FileDescriptor reader{pipe[0]};
    FileDescriptor writer{pipe[1]};

    const auto child = ::fork();

    check(child >= 0);
    if (child == 0) {
      try {
        if (::dup2(writer.get(), STDOUT_FILENO) < 0 || ::dup2(writer.get(), STDERR_FILENO) < 0 || ::dup2(writer.get(), 9) < 0) {
          _exit(1);
        }

        FileDescriptor input{::open("/dev/null", O_RDONLY | O_CLOEXEC)};
        if (!input) {
          _exit(1);
        }

        SpawnOptions spawn{0};

        spawn.redirect(input.get(), STDIN_FILENO);
        spawn.keepStandardStreams();

        const char* script = "{ true >&9; } 2>/dev/null && exit 2; read -r line && exit 3; echo out; echo err >&2";
        ds::Array<char*, 4> arguments{const_cast<char*>("/bin/sh"), const_cast<char*>("-c"), const_cast<char*>(script), nullptr};
        ds::Array<char*, 1> environment{nullptr};
        pid_t started = -1;
        int status = 0;

        checkSpawn(::posix_spawn(&started, arguments.front(), &spawn.actions, &spawn.attributes, arguments.data(), environment.data()));
        while (::waitpid(started, &status, 0) < 0 && errno == EINTR) {
        }

        _exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
      } catch (...) {
        _exit(1);
      }
    }

    writer.reset();

    std::string output;
    ds::Array<char, 64> buffer{};

    for (ssize_t count; (count = ::read(reader.get(), buffer.dataMut(), buffer.size())) != 0;) {
      if (count < 0 && errno == EINTR) {
        continue;
      }

      check(count > 0);
      output.append(buffer.data(), static_cast<std::size_t>(count));
    }

    int status = 0;

    while (::waitpid(child, &status, 0) < 0 && errno == EINTR) {
    }

    check(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    check(output == "out\nerr\n");
  }

  void testSocketOwnership() {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-socket-test-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const auto path = std::string{directory.data()} + "/runtime.sock";

    {
      LocalListener listener{path};
      bool rejected = false;

      try {
        LocalListener duplicate{path};
      } catch (const SystemError&) {
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
    } catch (const SystemError&) {
      rejected = true;
    }

    check(rejected);
    check(::unlink(path.c_str()) == 0);
    check(::unlink((path + ".lock").c_str()) == 0);
    check(::rmdir(directory.data()) == 0);
  }

  void testDisconnectedSocketClients() {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-disconnected-socket-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
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
        check(::connect(abandoned.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
        abandoned.reset();

        try {
          auto closed = listener.accept();
          if (closed) {
            char byte = 0;

            check(::recv(closed.get(), &byte, sizeof(byte), 0) == 0);
          }
        } catch (const SystemError&) {
          setup_failed = true;
        }

        FileDescriptor client{::socket(AF_UNIX, SOCK_STREAM, 0)};

        check(static_cast<bool>(client));
        check(::connect(client.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
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

  // A client that writes and closes before it is accepted, as a helper that sends a capture and
  // goes, is still admitted: what it sent is read, and a write to it fails without SIGPIPE.
  void testClosedClientIsRead() {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-closed-socket-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const auto path = std::string{directory.data()} + "/runtime.sock";

    {
      LocalListener listener{path};
      sockaddr_un address{};

      address.sun_family = AF_UNIX;
      std::strcpy(address.sun_path, path.c_str());
      FileDescriptor client{::socket(AF_UNIX, SOCK_STREAM, 0)};

      check(static_cast<bool>(client));
      check(::connect(client.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
      constexpr std::string_view sent = "capture";

      check(::write(client.get(), sent.data(), sent.size()) == static_cast<ssize_t>(sent.size()));
      client.reset();
      const auto connection = listener.accept();

      check(static_cast<bool>(connection), "a client that closed after it wrote is admitted");
      ds::Array<char, 16> received{};

      check(::recv(connection.get(), received.dataMut(), received.size(), 0) == static_cast<ssize_t>(sent.size()));
      check(std::string_view{received.data(), sent.size()} == sent, "what it sent is read");
      constexpr char reply = 'R';

      check(::send(connection.get(), &reply, sizeof(reply), 0) == -1 && errno == EPIPE, "a write to it fails with EPIPE, not SIGPIPE");
    }

    check(::unlink((path + ".lock").c_str()) == 0);
    check(::rmdir(directory.data()) == 0);
  }

  void testChildExitNotification() {
    SystemAllocator memory;
    struct sigaction previous{};

    check(::sigaction(SIGCHLD, nullptr, &previous) == 0);
    {
      NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};

      poller.watchSignal(SIGCHLD);
      ds::Array<Event, decltype(poller)::event_capacity> ready{};
      const auto child = ::fork();

      check(child >= 0);
      if (child == 0) {
        _exit(7);
      }

      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{2};
      bool observed = false;

      while (!observed && std::chrono::steady_clock::now() < deadline) {
        for (const auto& event : poller.wait(std::chrono::milliseconds{100}, ready.viewMut())) {
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

  void testCommandHelpers(SystemAllocator& memory) {
    ds::Array<char, PATH_MAX> found;

    check(findExecutable({.path = "/nonexistent-telar:/bin", .program = "sh"}, found.viewMut()) && std::string_view{found.dataMut()} == "/bin/sh");
    check(!findExecutable({.path = "/nonexistent-telar", .program = "sh"}, found.viewMut()));
    check(findExecutable({.path = "bin", .program = "sh", .cwd = "/"}, found.viewMut()));

    const auto self = ExecutablePath::sibling({"missing-telar-program", "runtime-host-tests"});

    check(self && self->view() == ExecutablePath{}.view());
    check(!ExecutablePath::sibling({"RUNTIME-HOST-TESTS"}));

    const ds::Array<std::string_view, 3> words{"/bin/sh", "-c", "cat; echo error >&2"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = words}, CommandPurpose::administration};
    CommandOutput<SystemAllocator> process{memory, 0};
    std::string output;
    std::string error;
    const ds::Array<std::string_view, 2> input{"in", "put"};
    const auto status = process.streamWithInput(
        command,
        std::chrono::steady_clock::now() + std::chrono::seconds{5},
        input,
        [&](std::span<const Byte> bytes) {
          output.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
          return true;
        },
        [&](std::span<const Byte> bytes) {
          error.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
        }
    );

    check(status == 0 && output == "input" && error == "error\n");
  }

  void testLoginShell(SystemAllocator& memory) {
    const char* saved = std::getenv("SHELL");
    const ds::Option<std::string> previous = saved != nullptr ? ds::Option<std::string>{saved} : ds::none;
    const auto* account = ::getpwuid(::getuid());
    const std::string_view fallback = account != nullptr && account->pw_shell[0] == '/' ? account->pw_shell : "/bin/sh";

    check(::setenv("SHELL", "/bin/sh", 1) == 0);
    check(loginShell().view() == "/bin/sh");

    Command shell{memory, Launch{.cwd = "/tmp"}, CommandPurpose::administration};

    check(shell.arguments().size() == 1 && std::string_view{shell.arguments().front()} == "/bin/sh");

    // A relative or empty SHELL names no login shell.
    check(::setenv("SHELL", "sh", 1) == 0);
    check(loginShell().view() == fallback);
    check(::setenv("SHELL", "", 1) == 0);
    check(loginShell().view() == fallback);

    check((previous ? ::setenv("SHELL", previous->c_str(), 1) : ::unsetenv("SHELL")) == 0);
  }

  void testHardenedGit(SystemAllocator& system) {
    using Git = HardenedGit<Memory>;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;

    check(Git::honorsLazyFetchControl("git version 2.45.0\n") && Git::honorsLazyFetchControl("git version 3.0") && Git::honorsLazyFetchControl("git version 2.50.1 (Apple Git-155)"));
    check(!Git::honorsLazyFetchControl("git version 2.44.9") && !Git::honorsLazyFetchControl("git version 2") && !Git::honorsLazyFetchControl("version 2.45"));
    const ds::Array<EnvironmentEntry, 3> inherited{{{"GIT_DIR", "/elsewhere"}, {"GIT_TERMINAL_PROMPT", "1"}, {"PATH", "/usr/bin:/bin"}}};
    const ds::Array<std::string_view, 1> words{"/bin/sh"};
    Command command{memory, Launch{.cwd = "/tmp", .arguments = words, .environment_mode = EnvironmentMode::replace, .environment = inherited}, CommandPurpose::configured_helper};

    Git::configure(command);
    check(!command.environment("GIT_DIR") && command.environment("GIT_TERMINAL_PROMPT") == "0" && command.environment("GIT_NO_LAZY_FETCH") == "1");
    check(command.environment("GIT_OPTIONAL_LOCKS") == "0" && command.environment("LC_ALL") == "C" && command.environment("PATH") == "/usr/bin:/bin");
  }

  void testPlatform() {
    SystemAllocator memory;

    testCommandHelpers(memory);
    testLoginShell(memory);
    testHardenedGit(memory);
    testSpawn(memory);
    testForegroundProcessGroup(memory);
    ProcessInspector inspector;
    ProcessProbe probe{inspector};
    ProcessProbe<ProcessInspector>::Request request;

    request.panes.atMut(0) = {1, 2, 3, ::getpid(), ::getpid()};
    request.count = 1;
    const auto observed = probe.observe(request);

    check(observed.count == 1 && observed.panes[0].identity == inspector.identity(::getpid()));
    // The kernel keeps only the first 15 (Linux) or 16 (macOS) bytes of the executable's name.
    const auto name = observed.panes[0].name.view();

    check(name.size() >= 15 && std::string_view{"runtime-host-tests"}.starts_with(name));
    check(!observed.panes[0].cwd.view().empty() && observed.panes[0].cwd.view().front() == '/');
    request.panes.atMut(0).foreground = -1;
    check(probe.observe(request).count == 0);
  }

  // A private directory for a runtime endpoint, removed with what is left in it.
  struct EndpointDirectory {
    EndpointDirectory() {
      ds::Array<char, 64> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-endpoint-test-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      path = directory.data();
    }

    ~EndpointDirectory() {
      std::filesystem::remove_all(path);
    }

    std::string path;
  };

  sockaddr_un endpointAddress(const std::string& path) {
    sockaddr_un address{};

    address.sun_family = AF_UNIX;
    check(path.size() < sizeof(address.sun_path));
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    return address;
  }

  bool reachable(const sockaddr_un& address) {
    FileDescriptor client{::socket(AF_UNIX, SOCK_STREAM, 0)};

    return client && ::connect(client.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0;
  }

  // A runtime that crashed leaves its socket behind, and the next one replaces it. A socket something
  // still listens on is left in place, and the new runtime refuses to start.
  void testListenerStaleSocket() {
    EndpointDirectory directory;
    const auto path = directory.path + "/runtime.sock";
    const auto address = endpointAddress(path);

    {
      FileDescriptor orphan{::socket(AF_UNIX, SOCK_STREAM, 0)};

      check(::bind(orphan.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0);
    }

    struct stat state{};

    check(::lstat(path.c_str(), &state) == 0 && S_ISSOCK(state.st_mode) && !reachable(address));
    {
      LocalListener listener{path};

      check(reachable(address));
    }

    FileDescriptor live{::socket(AF_UNIX, SOCK_STREAM, 0)};

    check(::bind(live.get(), reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0 && ::listen(live.get(), 4) == 0);
    bool in_use = false;

    try {
      LocalListener listener{path};
    } catch (const SystemError& error) {
      in_use = error.code() == EADDRINUSE;
    }

    check(in_use && reachable(address));
  }

  // The lock decides which runtime owns the endpoint: a lock others can read, one with a second
  // name, or a symlink is refused, and no socket is created.
  void testListenerUnsafeLock() {
    EndpointDirectory directory;
    const auto path = directory.path + "/runtime.sock";
    const auto lock = path + ".lock";
    const auto other = directory.path + "/other";

    auto refused = [&] {
      bool rejected = false;

      try {
        LocalListener listener{path};
      } catch (const SystemError&) {
        rejected = true;
      }

      struct stat state{};

      return rejected && ::lstat(path.c_str(), &state) != 0;
    };

    auto create = [](const std::string& file, mode_t mode) {
      FileDescriptor descriptor{::open(file.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600)};

      check(static_cast<bool>(descriptor) && ::fchmod(descriptor.get(), mode) == 0);
    };

    create(lock, 0644);
    check(refused());
    check(::unlink(lock.c_str()) == 0);

    create(other, 0600);
    check(::link(other.c_str(), lock.c_str()) == 0);
    check(refused());
    check(::unlink(lock.c_str()) == 0);

    check(::symlink(other.c_str(), lock.c_str()) == 0);
    check(refused());
    check(::unlink(lock.c_str()) == 0);

    LocalListener listener{path};
  }

  const telar::testing::Case case_platform{"platform.platform", testPlatform};
  const telar::testing::Case case_disconnected_socket_clients{"platform.disconnected_socket_clients", testDisconnectedSocketClients};
  const telar::testing::Case case_closed_client_is_read{"platform.closed_client_is_read", testClosedClientIsRead};
  const telar::testing::Case case_unread_output_shutdown{"platform.unread_output_shutdown", testUnreadOutputShutdown};
  const telar::testing::Case case_descriptor_holes{"platform.descriptor_holes", testDescriptorHoles};
  const telar::testing::Case case_inherited_descriptors{"platform.inherited_descriptors", testInheritedDescriptors};
  const telar::testing::Case case_standard_streams_only{"platform.standard_streams_only", testStandardStreamsOnly};
  const telar::testing::Case case_socket_ownership{"platform.socket_ownership", testSocketOwnership};
  const telar::testing::Case case_child_exit_notification{"platform.child_exit_notification", testChildExitNotification};
  const telar::testing::Case case_listener_stale_socket{"platform.listener_stale_socket", testListenerStaleSocket};
  const telar::testing::Case case_listener_unsafe_lock{"platform.listener_unsafe_lock", testListenerUnsafeLock};

}
