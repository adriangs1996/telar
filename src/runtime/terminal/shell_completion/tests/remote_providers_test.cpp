#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.shell_completion;
import telar.runtime.terminal.shell_completion.tests.ssh_host;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;

// A pane `ssh` reached completes a spec's providers on its host: the branches of the repository
// it works in there, the targets of the project files there, its processes and its programs.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using telar::runtime::testing::Host;
  using telar::runtime::testing::hostPath;
  using telar::runtime::testing::program;
  using telar::runtime::testing::run;
  using telar::runtime::testing::shellQuoted;

  using Clock = std::chrono::steady_clock;

  ShellCompletionRequest ask(CompletionProvider provider, std::string_view prefix, const std::filesystem::path& directory, std::string_view socket, IntegratedShell shell = IntegratedShell::none) {
    ShellCompletionRequest request{.client = 1, .request = 2, .pane = 3, .shell = shell, .line = {}, .directory = {}, .home = {}, .path = {}, .question = ShellQuestion::provider, .control = {}, .provider = provider};

    request.line.assign(prefix);
    request.directory.assign(directory.string());
    // This host's home, which the host's own must not be mistaken for.
    request.home.assign("/nonexistent");
    request.path.assign(hostPath());
    request.control.assign(socket);
    return request;
  }

  ShellCompletionOptions patient(const Host& host) {
    return {.control_directory = host.control.native(), .time = std::chrono::seconds{20}};
  }

  // Each word with its description.
  std::vector<std::pair<std::string, std::string>> described(const ShellCompletionRequest& request, const ShellCompletionOptions& options) {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    std::atomic<bool> cancelled{false};
    ShellCompleter completer{memory, cancelled, options};
    const auto result = completer.observe(request);
    std::vector<std::pair<std::string, std::string>> words;

    for (const auto& word : result.words) {
      words.emplace_back(word.text.view(), word.description.view());
    }

    return words;
  }

  std::vector<std::string> complete(const ShellCompletionRequest& request, const ShellCompletionOptions& options) {
    std::vector<std::string> words;

    for (auto& [text, description] : described(request, options)) {
      words.push_back(std::move(text));
    }

    return words;
  }

  bool has(const std::vector<std::string>& words, std::string_view word) {
    return std::ranges::find(words, word) != words.end();
  }

  // Runs git in `repository` with an identity of the test's own, quietly.
  void git(const std::filesystem::path& repository, std::string_view arguments) {
    check(run(std::format("git -C {} -c user.name=telar -c user.email=telar@example.invalid -c init.defaultBranch=main -c commit.gpgsign=false {} >/dev/null 2>&1", shellQuoted(repository), arguments)), std::format("git {}", arguments));
  }

  // A repository on the host, with a branch, a remote-tracking branch, a tag, a remote and a
  // stash, none of which the repository this test runs from has.
  std::filesystem::path hostRepository(Host& host) {
    if (program("git").empty()) {
      host.skip("git is not installed: the host's repository is not checked");
    }

    const auto repository = host.root / "repository";

    std::filesystem::create_directory(repository);
    git(repository, "init -q");
    std::ofstream{repository / "file"} << "one\n";
    git(repository, "add file");
    git(repository, "commit -q -m first");
    git(repository, "branch feature/only-on-the-host");
    git(repository, "update-ref refs/remotes/upstream/far-away HEAD");
    git(repository, "tag v-host");
    git(repository, "remote add upstream /nonexistent");
    std::ofstream{repository / "file"} << "two\n";
    git(repository, "stash -q");
    return repository;
  }

  void testBranchesAreTheHostRepositorysOwn() {
    Host host;
    const auto repository = hostRepository(host);
    const auto socket = host.master(host.control / "master");
    const auto branches = complete(ask(CompletionProvider::branch, "", repository, socket), patient(host));

    // Nothing of the repository the runtime itself runs in, and no tag.
    check(branches == std::vector<std::string>{"far-away", "feature/only-on-the-host", "main", "upstream/far-away"}, "the repository's branches, and a remote's by its own name too");
    check(complete(ask(CompletionProvider::branch, "fe", repository, socket), patient(host)) == std::vector<std::string>{"feature/only-on-the-host"}, "the branches the word starts");
    check(has(complete(ask(CompletionProvider::reference, "v-", repository, socket), patient(host)), "v-host"), "a revision names the tags too");
    check(complete(ask(CompletionProvider::branch, "", host.home, socket), patient(host)).empty(), "outside a repository there are none");
  }

  void testRemotesAndStashesAreTheHostRepositorysOwn() {
    Host host;
    const auto repository = hostRepository(host);
    const auto socket = host.master(host.control / "master");

    check(complete(ask(CompletionProvider::remote, "", repository, socket), patient(host)) == std::vector<std::string>{"upstream"}, "the repository's remotes");
    check(complete(ask(CompletionProvider::stash, "", repository, socket), patient(host)) == std::vector<std::string>{"stash@{0}"}, "its stashes");
  }

  void testProjectFilesNameTheirTargetsOnTheHost() {
    Host host;
    const auto socket = host.master(host.control / "master");
    const auto project = host.root / "project";
    const auto inside = project / "src" / "deep";

    std::filesystem::create_directories(inside);
    std::ofstream{project / "Makefile"} << "build: main.o\n\tcc main.o\ntest: build\n";
    std::ofstream{project / "justfile"} << "# Ship it\ndeploy:\n  echo deploy\n_hidden:\n  true\n";
    std::ofstream{project / "package.json"} << R"({"scripts": {"start": "node server.js", "lint": "eslint ."}})";
    std::ofstream{project / "compose.yaml"} << "services:\n  web:\n    image: nginx\n  database:\n    image: postgres\n";

    check(complete(ask(CompletionProvider::make_target, "", project, socket), patient(host)) == std::vector<std::string>{"build", "test"}, "the makefile's targets in its directory");
    check(complete(ask(CompletionProvider::make_target, "", inside, socket), patient(host)).empty(), "make reads no parent's makefile");
    check(described(ask(CompletionProvider::just_recipe, "", inside, socket), patient(host)) == std::vector<std::pair<std::string, std::string>>{{"deploy", "Ship it"}}, "the nearest justfile's public recipes, with their comments");
    check(described(ask(CompletionProvider::package_script, "st", inside, socket), patient(host)) == std::vector<std::pair<std::string, std::string>>{{"start", "node server.js"}}, "the nearest package.json's scripts, with what they run");
    check(complete(ask(CompletionProvider::compose_service, "", inside, socket), patient(host)) == std::vector<std::string>{"database", "web"}, "the nearest compose file's services");
  }

  void testProcessesAreTheHostUsersOwn() {
    Host host;
    const auto socket = host.master(host.control / "master");
    const auto child = ::fork();

    if (child == 0) {
      ::execl("/bin/sleep", "sleep", "30", static_cast<char*>(nullptr));
      ::_exit(127);
    }

    const auto words = described(ask(CompletionProvider::process, std::to_string(child), host.home, socket), patient(host));

    ::kill(child, SIGKILL);
    ::waitpid(child, nullptr, 0);
    check(std::ranges::contains(words, std::pair<std::string, std::string>{std::to_string(child), "sleep"}), "a process of the user's, by its id, with its name");
  }

  void testCommandsAreTheHostsProgramsAndItsShellsBuiltins() {
    Host host;
    const auto socket = host.master(host.control / "master");
    const auto commands = complete(ask(CompletionProvider::command, "sh", host.home, socket, IntegratedShell::bash), patient(host));

    check(has(commands, "sh"), "a program on the host's PATH");
    check(has(commands, "shopt") && has(complete(ask(CompletionProvider::command, "shi", host.home, socket, IntegratedShell::bash), patient(host)), "shift"), "the remote shell's builtins");
    const bool started = std::ranges::all_of(commands, [](const std::string& command) {
      return command.starts_with("sh");
    });

    check(started, "only the commands the word starts");
    check(complete(ask(CompletionProvider::command, "./sh", host.home, socket, IntegratedShell::bash), patient(host)) == std::vector<std::string>{}, "a word with a slash names a path, not a command");
  }

  // The word reaches the host as data, and git runs nothing a repository's configuration names.
  void testHostileInputsNeverRunOnTheHost() {
    Host host;
    const auto repository = hostRepository(host);
    const auto socket = host.master(host.control / "master");
    const auto marker = host.root / "pwned-config";

    git(repository, std::format("config core.fsmonitor {}", shellQuoted("touch " + marker.string())));
    git(repository, std::format("config core.pager {}", shellQuoted("touch " + marker.string())));
    std::filesystem::create_directories(repository / ".git" / "hooks");
    std::ofstream{repository / ".git" / "hooks" / "reference-transaction"} << "#!/bin/sh\ntouch " << shellQuoted(marker) << "\n";
    std::filesystem::permissions(repository / ".git" / "hooks" / "reference-transaction", std::filesystem::perms::owner_all);
    constexpr ds::Array<std::string_view, 8> words{
        "$(touch pwned-1)",
        "`touch pwned-2`",
        "a'; touch pwned-3; '",
        "\"$(touch pwned-4)",
        "*(e:'touch pwned-5':)",
        "-c touch pwned-6",
        "x\ntouch pwned-7",
        "$(touch${IFS}pwned-8)",
    };

    constexpr ds::Array<CompletionProvider, 10> providers{CompletionProvider::command, CompletionProvider::branch, CompletionProvider::reference, CompletionProvider::remote, CompletionProvider::stash, CompletionProvider::process, CompletionProvider::make_target, CompletionProvider::just_recipe, CompletionProvider::package_script, CompletionProvider::compose_service};

    for (const auto provider : providers) {
      for (const auto word : words) {
        static_cast<void>(complete(ask(provider, word, repository, socket, IntegratedShell::bash), patient(host)));
      }
    }

    check(!std::filesystem::exists(marker), "git ran a program the repository's configuration names");
    for (const auto& place : {repository, host.home, host.root}) {
      for (const auto& entry : std::filesystem::directory_iterator{place}) {
        check(!entry.path().filename().string().starts_with("pwned-") || entry.path() == marker, std::format("the host ran {}", entry.path().filename().string()));
      }
    }
  }

  // Waits for the service's answers, at most `limit`, keeping each one's request and words.
  std::map<std::uint64_t, std::vector<std::string>> answers(ShellCompletionService& service, std::size_t count, std::chrono::milliseconds limit) {
    std::map<std::uint64_t, std::vector<std::string>> found;
    const auto deadline = Clock::now() + limit;

    while (found.size() < count && Clock::now() < deadline) {
      pollfd descriptor{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

      static_cast<void>(::poll(&descriptor, 1, 20));
      service.collect([&](const ShellCompletionResult& result) {
        auto& words = found[result.request];

        for (const auto& word : result.words) {
          words.emplace_back(word.text.view());
        }
      });
    }

    return found;
  }

  // One Tab asks the host for a directory's entries and a provider's words at once: neither is
  // the other's line typed on, so both are answered.
  void testOneTabsQuestionsAreAllAnswered() {
    Host host;
    const auto repository = hostRepository(host);
    const auto socket = host.master(host.control / "master");
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ShellCompletionService service{memory, patient(host)};
    auto files = ask(CompletionProvider::path, "fi", repository, socket);
    auto branches = ask(CompletionProvider::branch, "fe", repository, socket);

    files.question = ShellQuestion::paths;
    branches.request = 5;
    check(!service.request(files).hasValue() && !service.request(branches).hasValue(), "neither question replaces the other");
    const auto found = answers(service, 2, std::chrono::seconds{30});

    check(found.size() == 2 && found.at(2) == std::vector<std::string>{"file"} && found.at(5) == std::vector<std::string>{"feature/only-on-the-host"}, "the files and the branches both come back");
  }

  const telar::testing::Case case_branches{"remote_providers.branches_are_the_host_repositorys_own", testBranchesAreTheHostRepositorysOwn};
  const telar::testing::Case case_remotes{"remote_providers.remotes_and_stashes_are_the_host_repositorys_own", testRemotesAndStashesAreTheHostRepositorysOwn};
  const telar::testing::Case case_files{"remote_providers.project_files_name_their_targets_on_the_host", testProjectFilesNameTheirTargetsOnTheHost};
  const telar::testing::Case case_processes{"remote_providers.processes_are_the_host_users_own", testProcessesAreTheHostUsersOwn};
  const telar::testing::Case case_commands{"remote_providers.commands_are_the_hosts_programs_and_its_shells_builtins", testCommandsAreTheHostsProgramsAndItsShellsBuiltins};
  const telar::testing::Case case_hostile{"remote_providers.hostile_inputs_never_run_on_the_host", testHostileInputsNeverRunOnTheHost};
  const telar::testing::Case case_questions{"remote_providers.one_tabs_questions_are_all_answered", testOneTabsQuestionsAreAllAnswered};

}
