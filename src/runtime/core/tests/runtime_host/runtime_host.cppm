module;
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

export module telar.runtime.core.tests.runtime_host;

import std;
import telar.base.memory.allocators;
import telar.platform.process;
import telar.runtime.workers.background_executor;
import telar.runtime.host.event_loop;
import telar.runtime.core.delivery.client_delivery;
import telar.runtime.core.media_service;
import telar.runtime.core.runtime;
import telar.runtime.suggestions.engine;
import telar.testing;
import telar.base.ds;

using telar::testing::check;

namespace {

  // The child half: argv is `--runtime-host DIRECTORY GUARD [--session] [--resume] [--suggest ENGINE]`. The runtime listens on
  // DIRECTORY/runtime.sock and, with --session, keeps its session in DIRECTORY/session.ckpt. GUARD is
  // the read end of a pipe whose write end only the test holds: when the test ends, however it ends,
  // the pipe reads end of file and the runtime stops as on SIGTERM, so no runtime outlives its test,
  // even one a failed check aborted before the host's destructor could stop it.
  int runHost(int argc, char** argv) {
    using namespace telar;
    using namespace telar::runtime;

    if (argc < 4) {
      return 2;
    }

    const std::string directory{argv[2]};
    const int guard = std::atoi(argv[3]);
    bool session = false;
    bool resume = false;
    bool data = false;
    std::string_view engine;

    for (int index = 4; index < argc; ++index) {
      const std::string_view flag{argv[index]};

      session |= flag == "--session";
      resume |= flag == "--resume";
      data |= flag == "--data";
      if (flag == "--suggest" && index + 1 < argc) {
        engine = argv[++index];
      }
    }

    const auto socket = directory + "/runtime.sock";
    const auto session_path = session ? directory + "/session.ckpt" : std::string{};
    const auto data_home = data ? directory + "/data" : std::string{};

    ::fcntl(guard, F_SETFD, FD_CLOEXEC);
    std::thread{[guard] {
      ds::Array<char, 1> byte;

      while (::read(guard, byte.dataMut(), byte.size()) < 0 && errno == EINTR) {
      }

      ::kill(::getpid(), SIGTERM);
      // A runtime that does not stop still ends, so its panes' ptys close and CTest's pipes with them.
      std::this_thread::sleep_for(std::chrono::seconds{5});
      ::_exit(3);
    }}.detach();

    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    const ExecutablePath cli{"telar"};
    BackgroundService history{memory, ":memory:"};
    PathService paths{memory};
    EditorService editor{memory};
    // The suggestion engine, when the test gives one, is the shell script it names.
    const ds::Array<std::string_view, 2> engine_arguments{"/bin/sh", engine};
    SuggestionService suggestions{memory, SuggestionOptions{.arguments = engine.empty() ? std::span<const std::string_view>{} : std::span<const std::string_view>{engine_arguments}}};
    BackgroundPool background{memory, history, paths, editor, suggestions};
    NativeEventLoop<ConcurrentMemory> poller{memory};

    poller.watchSignal(SIGTERM);
    poller.watchSignal(SIGINT);
    poller.watchSignal(SIGCHLD);
    const RuntimeOptions options{
        .socket = socket,
        .cli_executable = cli.view(),
        .session = {.path = session_path, .resume_agents = resume},
        .data_home = data_home,
    };

    Runtime runtime{memory, poller, background, options};

    runtime.run();
    return 0;
  }

  const telar::testing::Mode runtime_host{"--runtime-host", runHost};

}

export {
  // A real runtime, in a child the test binary starts in its own mode, on a socket in a private
  // directory. The test reaches it only as a client does: through the socket.
  struct RuntimeHostOptions {
    // Keeps the session in the directory, so a restarted runtime restores it.
    bool session = false;
    // A restored session resumes the agents its panes ran.
    bool resume_agents = false;
    // A shell script that speaks the suggestion engine's protocol; none leaves suggestions unavailable.
    std::string suggestion_engine;
    // Gives the runtime a data directory of its own, `data` under the host's, as a server has.
    bool data_home = false;
  };

  class RuntimeHost {
  public:
    RuntimeHost()
        : RuntimeHost(RuntimeHostOptions{}) {}

    explicit RuntimeHost(RuntimeHostOptions options)
        : options_(options) {
      telar::ds::Array<char, 32> directory{};

      std::strcpy(directory.dataMut(), "/tmp/telar-host-XXXXXX");
      check(::mkdtemp(directory.dataMut()) != nullptr);
      directory_ = directory.data();
      socket_ = directory_ + "/runtime.sock";
      start();
    }

    ~RuntimeHost() {
      if (child_ > 0) {
        stop();
      }

      std::error_code ignored;

      std::filesystem::remove_all(directory_, ignored);
    }

    RuntimeHost(const RuntimeHost&) = delete;
    RuntimeHost& operator=(const RuntimeHost&) = delete;

    const char* socket() const noexcept {
      return socket_.c_str();
    }

    const std::string& directory() const noexcept {
      return directory_;
    }

    // Starts the runtime and returns once its socket accepts a connection.
    void start() {
      check(child_ <= 0);
      int guard[2];

      check(::pipe(guard) == 0);
      ::fcntl(guard[1], F_SETFD, FD_CLOEXEC);
      const telar::runtime::ExecutablePath executable;
      const auto descriptor = std::to_string(guard[0]);
      std::vector<const char*> arguments{executable.cStr(), "--runtime-host", directory_.c_str(), descriptor.c_str()};

      if (options_.session) {
        arguments.push_back("--session");
      }

      if (options_.data_home) {
        arguments.push_back("--data");
      }

      if (options_.resume_agents) {
        arguments.push_back("--resume");
      }

      if (!options_.suggestion_engine.empty()) {
        arguments.push_back("--suggest");
        arguments.push_back(options_.suggestion_engine.c_str());
      }

      arguments.push_back(nullptr);

      child_ = ::fork();
      check(child_ >= 0);
      if (child_ == 0) {
        ::execv(arguments[0], const_cast<char* const*>(arguments.data()));
        ::_exit(127);
      }

      ::close(guard[0]);
      guard_ = guard[1];
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

      while (!connectable()) {
        int status = 0;

        check(::waitpid(child_, &status, WNOHANG) == 0, "the runtime host exited before it listened");
        check(std::chrono::steady_clock::now() < deadline, "the runtime host did not listen");
        ::poll(nullptr, 0, 10);
      }
    }

    // Sends SIGTERM, as a service manager stops the runtime, and returns its wait status.
    int stop() {
      return finish(SIGTERM);
    }

    // The wait status of a runtime that stopped by itself, as after RuntimeStop.
    int wait() {
      return finish(0);
    }

  private:
    int finish(int signal) {
      check(child_ > 0);
      if (signal != 0) {
        ::kill(child_, signal);
      }

      int status = 0;
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

      for (;;) {
        const auto reaped = ::waitpid(child_, &status, WNOHANG);
        if (reaped == child_) {
          break;
        }

        if (std::chrono::steady_clock::now() >= deadline) {
          ::kill(child_, SIGKILL);
          ::waitpid(child_, &status, 0);
          child_ = -1;
          ::close(guard_);
          check(false, "the runtime host did not stop");
        }

        ::poll(nullptr, 0, 10);
      }

      child_ = -1;
      ::close(guard_);
      return status;
    }

    bool connectable() const {
      const int descriptor = ::socket(AF_UNIX, SOCK_STREAM, 0);
      sockaddr_un address{};

      address.sun_family = AF_UNIX;
      std::strncpy(address.sun_path, socket_.c_str(), sizeof(address.sun_path) - 1);
      const bool connected = ::connect(descriptor, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) == 0;

      ::close(descriptor);
      return connected;
    }

    RuntimeHostOptions options_;
    std::string directory_;
    std::string socket_;
    pid_t child_ = -1;
    int guard_ = -1;
  };
}
