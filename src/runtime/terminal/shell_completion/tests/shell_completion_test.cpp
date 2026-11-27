#include <cstdlib>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.shell_completion;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  using Clock = std::chrono::steady_clock;

  struct Directory {
    Directory() {
      std::string name = (std::filesystem::temp_directory_path() / "telar-shell-completion-XXXXXX").string();

      check(::mkdtemp(name.data()) != nullptr);
      path = name;
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path, ignored);
    }

    Directory(const Directory&) = delete;
    Directory& operator=(const Directory&) = delete;
    Directory(Directory&&) = delete;
    Directory& operator=(Directory&&) = delete;

    void file(std::string_view name, std::string_view text = {}) const {
      std::ofstream{path / name} << text;
    }

    std::filesystem::path path;
  };

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

  std::string hostPath() {
    const char* path = std::getenv("PATH");

    return path == nullptr ? std::string{"/usr/bin:/bin"} : std::string{path};
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

  bool installed(IntegratedShell shell) {
    const auto name = shellName(shell);
    const auto path = hostPath();

    for (const auto directory : std::views::split(std::string_view{path}, ':')) {
      const auto candidate = std::filesystem::path{std::string_view{directory}} / name;
      if (::access(candidate.c_str(), X_OK) == 0) {
        return true;
      }
    }

    return false;
  }

  ShellCompletionRequest lineIn(IntegratedShell shell, std::string_view line, const std::filesystem::path& directory, std::string_view path) {
    ShellCompletionRequest request{.client = 1, .request = 2, .pane = 3, .shell = shell, .line = {}, .directory = {}, .home = {}, .path = {}};

    request.line.assign(line);
    request.directory.assign(directory.string());
    request.home.assign(directory.string());
    request.path.assign(path);
    return request;
  }

  struct Answer {
    std::vector<std::string> words;
    std::vector<std::string> descriptions;
  };

  // A loaded host may take a second to make zsh's dump, which each case keeps in its directory.
  ShellCompletionOptions patient(const Directory& directory) {
    return {.cache_directory = directory.path.native(), .time = std::chrono::seconds{20}};
  }

  Answer complete(IntegratedShell shell, std::string_view line, const Directory& directory, ds::Option<ShellCompletionOptions> options = ds::none, std::string_view path = {}) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    std::atomic<bool> cancelled{false};
    ShellCompleter completer{memory, cancelled, options ? *options : patient(directory)};
    const auto host = hostPath();
    const auto result = completer.observe(lineIn(shell, line, directory.path, path.empty() ? std::string_view{host} : path));
    Answer answer;

    for (const auto& word : result.words) {
      answer.words.emplace_back(word.text.view());
      answer.descriptions.emplace_back(word.description.view());
    }

    return answer;
  }

  bool has(const Answer& answer, std::string_view word) {
    return std::ranges::find(answer.words, word) != answer.words.end();
  }

  constexpr ds::Array<IntegratedShell, 3> shells{IntegratedShell::zsh, IntegratedShell::bash, IntegratedShell::fish};

  // Skips the case when none of the shells is installed; a missing one is named and passed over.
  template <typename Body>
  void eachShell(Body&& body) {
    std::size_t ran = 0;

    for (const auto shell : shells) {
      if (!installed(shell)) {
        std::println(std::cerr, "{} is not installed: its completion is not checked", shellName(shell));
        continue;
      }

      if (shell == IntegratedShell::bash && !bashCompletionInstalled()) {
        std::println(std::cerr, "bash-completion is not installed: bash's completion is not checked");
        continue;
      }

      ++ran;
      body(shell);
    }

    if (ran == 0) {
      telar::testing::skip("no zsh, bash or fish is installed");
    }
  }

  void testFilesCompleteAsWholeUnquotedWords() {
    eachShell([](IntegratedShell shell) {
      const Directory directory;

      std::filesystem::create_directory(directory.path / "my dir");
      directory.file("my file.txt");
      directory.file("other");
      const auto answer = complete(shell, "ls my", directory);

      check(has(answer, "my dir/") && has(answer, "my file.txt") && !has(answer, "other"), std::format("{} completes the files the word starts, a directory with its slash", shellName(shell)));
    });
  }

  void testOptionsComeFromTheShellsOwnCompletion() {
    eachShell([](IntegratedShell shell) {
      const Directory directory;
      const auto answer = complete(shell, "git --no-p", directory);

      // bash completes git only where bash-completion and git's completion are installed.
      if (shell == IntegratedShell::bash && answer.words.empty()) {
        std::println(std::cerr, "bash has no completion for git here: its options are not checked");
        return;
      }

      check(has(answer, "--no-pager"), std::format("{} completes git's option", shellName(shell)));
    });
  }

  void testDescriptionsSayWhatAChoiceDoes() {
    for (const auto shell : {IntegratedShell::zsh, IntegratedShell::fish}) {
      if (!installed(shell)) {
        continue;
      }

      const Directory directory;
      const auto answer = complete(shell, "git --no-p", directory);
      const auto found = std::ranges::find(answer.words, "--no-pager");

      check(found != answer.words.end(), std::format("{} completes git's option", shellName(shell)));
      const auto& description = answer.descriptions[static_cast<std::size_t>(found - answer.words.begin())];

      check(description.contains("pager") && !description.starts_with("--no-pager") && !description.starts_with('-') && !description.starts_with(' '), std::format("{} describes the option, not the option again: {}", shellName(shell), description));
    }
  }

  void testHostileLinesNeverRunWhatTheyHold() {
    eachShell([](IntegratedShell shell) {
      const Directory directory;
      constexpr ds::Array<std::string_view, 9> lines{
          "ls '$(touch pwned-1)",
          "ls $(touch pwned-2)",
          "ls `touch pwned-3`",
          "ls \"$(touch pwned-4)",
          "ls *(e:'touch pwned-5':)",
          "ls <(touch pwned-6)",
          "--init-command=touch\\ pwned-7 x",
          "-c touch pwned-8",
          "ls x\ntouch pwned-9",
      };

      for (const auto line : lines) {
        static_cast<void>(complete(shell, line, directory));
      }

      // Quotes and separators reach the shell as data.
      static_cast<void>(complete(shell, "ls 'a\"b'; touch pwned-10 && ls ", directory));
      for (const auto& entry : std::filesystem::directory_iterator{directory.path}) {
        check(!entry.path().filename().string().starts_with("pwned"), std::format("{} ran {}", shellName(shell), entry.path().filename().string()));
      }
    });
  }

  // A stand-in for the shell that never answers, named after the shell it stands in for.
  std::string slowShell(const Directory& directory, IntegratedShell shell) {
    const auto bin = directory.path / "bin";

    std::filesystem::create_directory(bin);
    const auto program = bin / shellName(shell);

    std::ofstream{program} << "#!/bin/sh\nexec sleep 30\n";
    check(::chmod(program.c_str(), 0700) == 0);
    return bin.string() + ":/usr/bin:/bin";
  }

  void testASlowShellIsEndedWithinItsTime() {
    const Directory directory;
    const auto path = slowShell(directory, IntegratedShell::bash);
    const auto started = Clock::now();
    const auto answer = complete(IntegratedShell::bash, "ls a", directory, ShellCompletionOptions{.time = std::chrono::milliseconds{300}}, path);
    const auto took = Clock::now() - started;

    check(answer.words.empty(), "a shell out of time completes nothing");
    check(took < std::chrono::seconds{2}, std::format("the shell was ended after {}", std::chrono::duration_cast<std::chrono::milliseconds>(took)));
  }

  void testARepeatedLineIsAnsweredFromTheLastAnswer() {
    if (!installed(IntegratedShell::zsh)) {
      telar::testing::skip("zsh is not installed");
    }

    const Directory directory;

    directory.file("alpha");
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    std::atomic<bool> cancelled{false};
    ShellCompleter completer{memory, cancelled, patient(directory)};
    const auto host = hostPath();
    const auto request = lineIn(IntegratedShell::zsh, "cat al", directory.path, host);
    const auto first = completer.observe(request);

    check(first.words.size() == 1 && first.words[0].text.view() == "alpha");
    directory.file("alps");
    const auto again = completer.observe(request);

    check(again.words.size() == 1, "the same line in the same directory is answered as it was a moment ago");
    auto elsewhere = request;

    elsewhere.line.assign("cat alp");
    check(completer.observe(elsewhere).words.size() == 2, "another line asks the shell, which finds the new file");
  }

  // Waits for the service's answers, at most `limit`.
  std::vector<ShellCompletionResult> answers(ShellCompletionService& service, telar::ConcurrentMemory& memory, std::size_t count, std::chrono::milliseconds limit) {
    std::vector<ShellCompletionResult> found;
    const auto deadline = Clock::now() + limit;

    while (found.size() < count && Clock::now() < deadline) {
      pollfd descriptor{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

      static_cast<void>(::poll(&descriptor, 1, 20));
      service.collect([&](const ShellCompletionResult& result) {
        ShellCompletionResult copy{memory};

        copy.client = result.client;
        copy.request = result.request;
        copy.pane = result.pane;
        found.push_back(std::move(copy));
      });
    }

    return found;
  }

  void testANewerLineOfThePaneEndsItsRunningShell() {
    const Directory directory;
    const auto path = slowShell(directory, IntegratedShell::bash);
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ShellCompletionService service{memory, {.time = std::chrono::seconds{20}}};
    auto first = lineIn(IntegratedShell::bash, "ls a", directory.path, path);
    auto second = first;

    second.request = 5;
    second.line.assign("ls ab");
    check(!service.request(first).hasValue());
    // The first shell starts before the line changes.
    std::this_thread::sleep_for(std::chrono::milliseconds{100});
    const auto started = Clock::now();

    check(!service.request(second).hasValue(), "the running request is answered, not dropped");
    const auto found = answers(service, memory, 1, std::chrono::seconds{5});

    check(found.size() == 1 && found[0].request == 2, "the line typed on from is answered");
    check(Clock::now() - started < std::chrono::seconds{2}, "its shell was ended, not waited for");
  }

  void testAPaneWaitsWithItsLatestLineOnly() {
    const Directory directory;
    const auto path = slowShell(directory, IntegratedShell::bash);
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ShellCompletionService service{memory, {.time = std::chrono::seconds{20}}};
    auto running = lineIn(IntegratedShell::bash, "ls a", directory.path, path);
    auto waiting = running;
    auto latest = running;

    running.pane = 9;
    waiting.request = 5;
    latest.request = 6;
    check(!service.request(running).hasValue());
    check(!service.request(waiting).hasValue());
    const auto dropped = service.request(latest);

    check(dropped.hasValue() && dropped->client == 1 && dropped->request == 5, "the line the pane replaced comes back to be answered");
  }

  const telar::testing::Case case_files{"shell_completion.files_complete_as_whole_unquoted_words", testFilesCompleteAsWholeUnquotedWords};
  const telar::testing::Case case_options{"shell_completion.options_come_from_the_shells_own_completion", testOptionsComeFromTheShellsOwnCompletion};
  const telar::testing::Case case_descriptions{"shell_completion.descriptions_say_what_a_choice_does", testDescriptionsSayWhatAChoiceDoes};
  const telar::testing::Case case_hostile{"shell_completion.hostile_lines_never_run_what_they_hold", testHostileLinesNeverRunWhatTheyHold};
  const telar::testing::Case case_slow{"shell_completion.a_slow_shell_is_ended_within_its_time", testASlowShellIsEndedWithinItsTime};
  const telar::testing::Case case_repeated{"shell_completion.a_repeated_line_is_answered_from_the_last_answer", testARepeatedLineIsAnsweredFromTheLastAnswer};
  const telar::testing::Case case_newer{"shell_completion.a_newer_line_of_the_pane_ends_its_running_shell", testANewerLineOfThePaneEndsItsRunningShell};
  const telar::testing::Case case_latest{"shell_completion.a_pane_waits_with_its_latest_line_only", testAPaneWaitsWithItsLatestLineOnly};

}
