#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.platform.process;
import telar.runtime.terminal.command_capture.tracker;
import telar.runtime.terminal.shell_completion;
import telar.runtime.terminal.shell_completion.tests.ssh_host;
import telar.runtime.terminal.shell_integration;
import telar.runtime.terminal.shell_integration.token;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

// The whole way a pane `ssh` reached completes on its host: telar's ssh shares the session's
// connection through a socket in the runtime's private directory and names it in the nonce the
// pane's shell signs; the remote shell's answer makes it the pane's; completion goes through it
// while the session lives, and finds nothing once it ended.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::runtime::testing::Host;
  using telar::runtime::testing::hostPath;

  using Clock = std::chrono::steady_clock;

  struct Completions {
    void complete(CommandCompletion) {}
  };

  // Reads what the pane shows into `zones` until `done` or the time is up.
  template <typename Done>
  void follow(int pane, CommandZones& zones, Done done, std::chrono::seconds limit) {
    Completions sink;
    const auto deadline = Clock::now() + limit;
    ds::Array<Byte, 4096> bytes{};

    while (!done() && Clock::now() < deadline) {
      pollfd ready{.fd = pane, .events = POLLIN, .revents = 0};
      if (::poll(&ready, 1, 50) != 1) {
        continue;
      }

      const auto count = ::read(pane, bytes.dataMut(), bytes.size());
      if (count <= 0) {
        return;
      }

      zones.feed(bytes.view().first(static_cast<std::size_t>(count)), {}, sink);
    }
  }

  std::vector<std::string> complete(std::string_view line, const std::filesystem::path& directory, std::string_view socket, const std::filesystem::path& control) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    std::atomic<bool> cancelled{false};
    ShellCompleter completer{memory, cancelled, {.control_directory = control.native(), .time = std::chrono::seconds{20}}};
    ShellCompletionRequest request{.client = 1, .request = 2, .pane = 3, .shell = IntegratedShell::none, .line = {}, .directory = {}, .home = {}, .path = {}, .question = ShellQuestion::paths, .control = {}};

    request.line.assign(line);
    request.directory.assign(directory.string());
    request.home.assign("/nonexistent");
    request.path.assign(hostPath());
    request.control.assign(socket);
    std::vector<std::string> words;

    for (const auto& word : completer.observe(request).words) {
      words.emplace_back(word.text.view());
    }

    return words;
  }

  // The session shares its connection through a socket in `control`, the runtime's private
  // directory, and completes through it until it ends.
  void sharesItsConnection(const Host& host, const std::filesystem::path& control) {
    const auto remote = host.root / "remote";

    std::filesystem::create_directories(remote / "my dir");
    std::ofstream{remote / "my file.txt"};
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const auto scripts = ShellIntegration<ConcurrentMemory>::install(memory, (host.root / "data").string());
    const auto ssh = std::string{scripts.view()} + "/ssh/ssh.sh";
    const auto config = (host.root / "ssh_config").string();
    const auto token = ShellToken::generate();
    // As the integrated shell's `ssh` function runs it.
    const ds::Array<std::string_view, 5> arguments{"/bin/sh", ssh, "-F", config, "telar-test"};
    Command command{memory, Launch{.cwd = host.root.string(), .arguments = arguments}};

    command.setEnvironment({.name = "TELAR_SHELL_TOKEN", .value = token.text()});
    command.setEnvironment({.name = "TELAR_SHELL_SSH_CONTROL", .value = control.string()});
    PtyProcess pane{command.specification(TerminalSize{80, 24, 0, 0})};
    CommandZones zones{memory, "/", token};

    follow(pane.descriptor(), zones, [&] {
      return zones.remote();
    },
        std::chrono::seconds{20});
    check(zones.remote(), "the remote shell answered the nonce");
    const std::string socket{zones.remoteControl()};
    struct stat status{};

    check(socket.starts_with(control.string() + "/") && ::lstat(socket.c_str(), &status) == 0 && S_ISSOCK(status.st_mode), std::format("the session shares its connection through the private directory: {}", socket));
    check(complete("my", remote, socket, control) == std::vector<std::string>{"my dir/", "my file.txt"}, "the host's directory is listed through it");

    // The session ends, and its master with it.
    static_cast<void>(::write(pane.descriptor(), "exit\r", 5));
    follow(pane.descriptor(), zones, [&] {
      return ::access(socket.c_str(), F_OK) != 0;
    },
        std::chrono::seconds{10});
    check(::access(socket.c_str(), F_OK) != 0, "the shared connection ended with the session");
    check(complete("my", remote, socket, control).empty(), "a session that ended completes nothing");
  }

  void testASessionSharesItsConnectionForCompletion() {
    const Host host;

    sharesItsConnection(host, host.control);
  }

  // %C in a directory as long as macOS's TMPDIR makes would not fit a socket address: the session
  // shares its connection under a name of its own.
  void testALongPrivateDirectoryStillShares() {
    const Host host;
    const auto control = host.control / "too-long-for-percent-c";

    std::filesystem::create_directory(control);
    ::chmod(control.c_str(), 0700);
    check(control.string().size() + 41 > 86 && control.string().size() + 17 <= 86, "the directory leaves %C no room, and a short name some");
    sharesItsConnection(host, control);
  }

  const telar::testing::Case case_long{"ssh_completion.a_long_private_directory_still_shares", testALongPrivateDirectoryStillShares};
  const telar::testing::Case case_shared{"ssh_completion.a_session_shares_its_connection_for_completion", testASessionSharesItsConnectionForCompletion};

}
