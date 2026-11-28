#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.shell_completion;
import telar.runtime.terminal.shell_completion.tests.ssh_host;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

// A pane `ssh` reached completes on its host, through the connection its session shares.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::runtime::testing::Host;
  using telar::runtime::testing::hostPath;
  using telar::runtime::testing::program;

  using Clock = std::chrono::steady_clock;

  ShellCompletionRequest ask(ShellQuestion question, std::string_view line, const std::filesystem::path& directory, std::string_view socket, IntegratedShell shell = IntegratedShell::none) {
    ShellCompletionRequest request{.client = 1, .request = 2, .pane = 3, .shell = shell, .line = {}, .directory = {}, .home = {}, .path = {}, .question = question, .control = {}};

    request.line.assign(line);
    request.directory.assign(directory.string());
    // This host's home, which the host's own must not be mistaken for.
    request.home.assign("/nonexistent");
    request.path.assign(hostPath());
    request.control.assign(socket);
    return request;
  }

  // A loaded host may take a few seconds to make zsh's dump the first time.
  ShellCompletionOptions patient(const Host& host) {
    return {.control_directory = host.control.native(), .time = std::chrono::seconds{20}};
  }

  std::vector<std::string> complete(const ShellCompletionRequest& request, const ShellCompletionOptions& options) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    std::atomic<bool> cancelled{false};
    ShellCompleter completer{memory, cancelled, options};
    const auto result = completer.observe(request);
    std::vector<std::string> words;

    for (const auto& word : result.words) {
      words.emplace_back(word.text.view());
    }

    return words;
  }

  bool has(const std::vector<std::string>& words, std::string_view word) {
    return std::ranges::find(words, word) != words.end();
  }

  // A directory on the host with a little of everything.
  std::filesystem::path remoteDirectory(const Host& host) {
    const auto directory = host.root / "remote";

    std::filesystem::create_directories(directory / "my dir");
    std::filesystem::create_directory(directory / ".hidden");
    std::ofstream{directory / "my file.txt"};
    std::ofstream{directory / "other"};
    std::ofstream{directory / "tool"} << "#!/bin/sh\n";
    ::chmod((directory / "tool").c_str(), 0700);
    return directory;
  }

  void testAPathListsTheRemoteDirectory() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");
    const auto words = complete(ask(ShellQuestion::paths, "my", directory, socket), patient(host));

    check(words == std::vector<std::string>{"my dir/", "my file.txt"}, "the entries the word starts, a directory with its slash");
    check(complete(ask(ShellQuestion::paths, "my dir/", directory, socket), patient(host)).empty(), "an empty directory lists nothing");
    check(has(complete(ask(ShellQuestion::paths, ".h", directory, socket), patient(host)), ".hidden/"), "a word that starts with a dot lists hidden entries");
    check(!has(complete(ask(ShellQuestion::paths, "", directory, socket), patient(host)), ".hidden/"), "hidden entries only for a word that starts with a dot");
  }

  void testTheHomeIsTheHosts() {
    Host host;
    const auto socket = host.master(host.control / "master");

    std::filesystem::create_directory(host.home / "only-there");
    const auto words = complete(ask(ShellQuestion::paths, "~/on", host.root, socket), patient(host));

    check(words == std::vector<std::string>{"~/only-there/"}, "~/ is the home of the host's session, written back as typed");
  }

  void testDirectoriesAndExecutablesListWhatTheyName() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");
    const auto directories = complete(ask(ShellQuestion::directories, "", directory, socket), patient(host));
    const auto executables = complete(ask(ShellQuestion::executables, "./", directory, socket), patient(host));

    check(directories == std::vector<std::string>{"my dir/"}, "only the directories");
    check(executables == std::vector<std::string>{"./my dir/", "./tool"}, "the directories and the programs there");
  }

  constexpr ds::Array<IntegratedShell, 3> shells{IntegratedShell::zsh, IntegratedShell::bash, IntegratedShell::fish};

  std::string_view shellName(IntegratedShell shell) {
    switch (shell) {
    case IntegratedShell::zsh:
      return "zsh";
    case IntegratedShell::bash:
      return "bash";
    case IntegratedShell::fish:
      return "fish";
    case IntegratedShell::none:
      break;
    }

    return "none";
  }

  // Whether bash-completion is where the completion script looks for it: without it bash has a
  // completion for no command, and answers nothing, as a bash without a .bashrc would.
  bool bashCompletionInstalled() {
    constexpr std::array files{
        "/usr/local/share/bash-completion/bash_completion",
        "/opt/homebrew/share/bash-completion/bash_completion",
        "/usr/share/bash-completion/bash_completion",
        "/opt/homebrew/etc/bash_completion",
        "/usr/local/etc/bash_completion",
        "/etc/bash_completion",
    };

    return std::ranges::any_of(files, [](const char* file) {
      return ::access(file, R_OK) == 0;
    });
  }

  void testTheRemoteShellCompletesTheLine() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");
    std::size_t ran = 0;

    for (const auto shell : shells) {
      if (program(shellName(shell)).empty()) {
        std::println(std::cerr, "{} is not installed: its completion on the host is not checked", shellName(shell));
        continue;
      }

      if (shell == IntegratedShell::bash && !bashCompletionInstalled()) {
        std::println(std::cerr, "bash-completion is not installed: bash's completion on the host is not checked");
        continue;
      }

      ++ran;
      const auto words = complete(ask(ShellQuestion::line, "ls my", directory, socket, shell), patient(host));

      check(has(words, "my dir/") && has(words, "my file.txt") && !has(words, "other"), std::format("{} on the host completes the files the word starts", shellName(shell)));
    }

    if (ran == 0) {
      telar::testing::skip("no zsh, bash or fish is installed");
    }
  }

  // What the login shell's own startup prints on the host is no word of the answer.
  void testTheLoginShellsStartupIsNoAnswer() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");

    std::filesystem::create_directories(host.home / ".config/fish");
    for (const auto* file : {".bashrc", ".zshenv", ".config/fish/config.fish"}) {
      std::ofstream{host.home / file} << "echo my-greeting\n";
    }

    const auto words = complete(ask(ShellQuestion::paths, "my", directory, socket), patient(host));

    check(words == std::vector<std::string>{"my dir/", "my file.txt"}, "the greeting is not an entry");
  }

  void testHostileLinesNeverRunOnTheHost() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");
    constexpr ds::Array<std::string_view, 9> lines{
        "ls '$(touch pwned-1)",
        "ls $(touch pwned-2)",
        "ls `touch pwned-3`",
        "ls \"$(touch pwned-4)",
        "ls *(e:'touch pwned-5':)",
        "ls <(touch pwned-6)",
        "ls a'; touch pwned-7; '",
        "-c touch pwned-8",
        "ls x\ntouch pwned-9",
    };

    for (const auto line : lines) {
      static_cast<void>(complete(ask(ShellQuestion::paths, line, directory, socket), patient(host)));
      static_cast<void>(complete(ask(ShellQuestion::paths, line.substr(line.find(' ') + 1), directory, socket), patient(host)));
      for (const auto shell : shells) {
        if (!program(shellName(shell)).empty()) {
          static_cast<void>(complete(ask(ShellQuestion::line, line, directory, socket, shell), patient(host)));
        }
      }
    }

    for (const auto& place : {directory, host.home, host.root}) {
      for (const auto& entry : std::filesystem::directory_iterator{place}) {
        check(!entry.path().filename().string().starts_with("pwned"), std::format("the host ran {}", entry.path().filename().string()));
      }
    }
  }

  void testAClosedConnectionHasNoWordsWithinTheBound() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto socket = host.master(host.control / "master");
    const ShellCompletionOptions options{.control_directory = host.control.native()};

    check(!complete(ask(ShellQuestion::paths, "my", directory, socket), options).empty(), "the connection answers while it is open");
    host.close(socket);
    const auto started = Clock::now();
    const auto words = complete(ask(ShellQuestion::paths, "o", directory, socket), options);
    const auto took = Clock::now() - started;

    check(words.empty(), "a closed connection completes nothing, and ssh makes no connection of its own");
    check(took < options.time, std::format("it answered after {}", std::chrono::duration_cast<std::chrono::milliseconds>(took)));
  }

  // Another user could make a socket where anyone may write, and read every line sent through it.
  void testOnlyASocketOfTheUsersOwnCarriesTheLine() {
    Host host;
    const auto directory = remoteDirectory(host);
    const auto shared = host.root / "shared";

    std::filesystem::create_directory(shared);
    ::chmod(shared.c_str(), 0777);
    const auto open = host.master(shared / "master");

    check(complete(ask(ShellQuestion::paths, "my", directory, open), patient(host)).empty(), "a socket in a directory others may write is refused");

    const auto link = host.control / "link";

    std::filesystem::create_symlink(open, link);
    check(complete(ask(ShellQuestion::paths, "my", directory, link.string()), patient(host)).empty(), "a link in the private directory is no socket");

    // A directory of the user's alone, where the user's own ssh_config may keep its sockets, is
    // as good as the private one.
    const auto own = host.root / "own";

    std::filesystem::create_directory(own);
    ::chmod(own.c_str(), 0700);
    const auto mine = host.master(own / "master");

    check(!complete(ask(ShellQuestion::paths, "my", directory, mine), patient(host)).empty(), "a socket in the user's own directory carries the line");
  }

  const telar::testing::Case case_path{"remote_completion.a_path_lists_the_remote_directory", testAPathListsTheRemoteDirectory};
  const telar::testing::Case case_home{"remote_completion.the_home_is_the_hosts", testTheHomeIsTheHosts};
  const telar::testing::Case case_kinds{"remote_completion.directories_and_executables_list_what_they_name", testDirectoriesAndExecutablesListWhatTheyName};
  const telar::testing::Case case_shell{"remote_completion.the_remote_shell_completes_the_line", testTheRemoteShellCompletesTheLine};
  const telar::testing::Case case_startup{"remote_completion.the_login_shells_startup_is_no_answer", testTheLoginShellsStartupIsNoAnswer};
  const telar::testing::Case case_hostile{"remote_completion.hostile_lines_never_run_on_the_host", testHostileLinesNeverRunOnTheHost};
  const telar::testing::Case case_closed{"remote_completion.a_closed_connection_has_no_words_within_the_bound", testAClosedConnectionHasNoWordsWithinTheBound};
  const telar::testing::Case case_socket{"remote_completion.only_a_socket_of_the_users_own_carries_the_line", testOnlyASocketOfTheUsersOwnCarriesTheLine};

}
