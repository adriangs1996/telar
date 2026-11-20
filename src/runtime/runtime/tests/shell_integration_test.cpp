#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>
#include <cstdlib>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_memory;
import telar.ebnf.matcher;
import telar.runtime.shell_integration.git_context;
import telar.runtime.shell_integration.words;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.runtime.model.slot_store;
import telar.base.ds;
import telar.base.text;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  namespace {

    std::string text(std::string_view value) {
      return std::string{value};
    }

    ds::Option<std::string> findProgram(std::string_view name) {
      const char* variable = std::getenv("PATH");
      std::string_view path = variable == nullptr ? "/usr/bin:/bin" : variable;

      while (!path.empty()) {
        const auto separator = path.find(':');
        auto candidate = text(path.substr(0, separator)) + "/" + text(name);
        if (::access(candidate.c_str(), X_OK) == 0) {
          return candidate;
        }

        path.remove_prefix(separator == std::string_view::npos ? path.size() : separator + 1);
      }

      return ds::none;
    }

  }

  // The repository a shell works in, read on the git worker.
  void gitContext() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;

    if (!findProgram("git")) {
      telar::testing::skip("git is not installed");
    }

    TemporaryDirectory repository{"/tmp/telar-git-XXXXXX"};
    const auto run = [&](std::string_view command) {
      const auto line = "cd " + text(repository.path()) + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 " + text(command) + " >/dev/null 2>&1";

      check(std::system(line.c_str()) == 0);
    };

    run("git init -q -b trunk . && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m first && touch new && echo x > tracked && git add tracked");

    ShellGitService service{memory};

    service.request(7, 1, repository.path());
    ds::Option<ShellGitResult> result;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    while (!result) {
      check(std::chrono::steady_clock::now() < deadline);
      pollfd ready{.fd = service.descriptor(), .events = POLLIN, .revents = 0};

      ::poll(&ready, 1, 50);
      service.collect([&](const ShellGitResult& value) {
        result = value;
      });
    }

    check(result->pane == 7 && result->generation == 1);
    const auto& summary = result->summary;

    check(summary.repository && !summary.detached && summary.branch.view() == "trunk");
    check(summary.changes_known && summary.staged == 1 && summary.unstaged == 0);
    const auto message = summary.message(7);

    check(message.pane_id == 7 && message.branch == "trunk");

    run("git branch feature/x && git branch other");
    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::branch, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.directory.assign(repository.path());
    const auto texts = [&](const WordRequest& query) {
      std::vector<std::string> result;

      for (const auto& word : reader.observe(query).words) {
        result.emplace_back(word.text.view());
      }

      return result;
    };

    check(texts(request) == std::vector<std::string>{"feature/x", "other", "trunk"});
    run("git remote add upstream https://example.invalid/r.git && echo a > stashed && git add stashed && git -c user.name=t -c user.email=t@t stash -q && git -c user.name=t -c user.email=t@t stash -q --include-untracked 2>/dev/null; true");
    request.provider = CompletionProvider::remote;
    check(texts(request) == std::vector<std::string>{"upstream"});
    request.provider = CompletionProvider::stash;
    check(texts(request).size() >= 1 && texts(request).front() == "stash@{0}");
  }

  // The values completion asks the runtime for, read from files the shell's machine holds.
  void words() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;

    TemporaryDirectory root{"/tmp/telar-words-XXXXXX"};
    const auto base = text(root.path());
    const auto make = [&](std::string_view relative, std::string_view contents, mode_t mode) {
      const auto path = base + "/" + text(relative);
      auto* file = std::fopen(path.c_str(), "w");

      check(file != nullptr);
      std::fputs(text(contents).c_str(), file);
      std::fclose(file);
      check(::chmod(path.c_str(), mode) == 0);
    };

    check(::mkdir((base + "/bin").c_str(), 0700) == 0 && ::mkdir((base + "/.ssh").c_str(), 0700) == 0);
    make("bin/telar-one", "", 0700);
    make("bin/telar-two", "", 0700);
    make("bin/telar-data", "", 0600);
    make(".ssh/config", "Host build-01 build-02\n  HostName x\nhost *.internal\nHost=builder\nMatch all\n", 0600);
    make("Makefile", "all: build\nbuild test: deps\n\tcc\n.PHONY: all\nVAR := 1\n%.o: %.c\ninstall::\n", 0600);

    WordReader reader{memory, base + "/telar"};
    const auto ask = [&](CompletionProvider provider, std::string_view prefix) {
      WordRequest request{.client = 1, .request = 9, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};

      request.prefix.assign(prefix);
      request.directory.assign(root.path());
      request.home.assign(root.path());
      request.path.assign(base + "/bin:relative:/nonexistent");
      const auto result = reader.observe(request);

      check(result.client == 1 && result.request == 9);
      std::vector<std::string> texts;

      for (const auto& word : result.words) {
        texts.emplace_back(word.text.view());
      }

      return texts;
    };

    check(ask(CompletionProvider::command, "telar-") == std::vector<std::string>{"telar-one", "telar-two"});
    // A shell's builtins and the names it reported count as commands; until it reports them,
    // the list cannot tell a missing command.
    WordRequest named{.client = 1, .request = 4, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    named.prefix.assign("gs");
    named.path.assign(base + "/bin");
    check(reader.observe(named).truncated && reader.observe(named).words.empty());
    named.shell = IntegratedShell::zsh;
    named.names = std::allocate_shared<ds::String<ConcurrentMemory>>(AllocatorRef<ds::String<ConcurrentMemory>, ConcurrentMemory>{memory}, memory, "gst  ll gsw");
    const auto names = reader.observe(named);

    check(!names.truncated && names.words.size() == 2 && names.words[0].text == "gst" && names.words[1].text == "gsw");
    named.prefix.assign("setop");
    check(reader.observe(named).words.size() == 1 && reader.observe(named).words[0].text == "setopt");
    check(ask(CompletionProvider::ssh_host, "build") == std::vector<std::string>{"build-01", "build-02", "builder"});
    check(ask(CompletionProvider::make_target, "") == std::vector<std::string>{"all", "build", "install", "test"});
    // Files read for values: a justfile's public recipes and aliases, the nearest package.json's
    // scripts and a compose file's services, from the directory or one of its parents.
    make("justfile", "set shell := [\"zsh\", \"-c\"]\nversion := \"1\"\n# Build everything\nbuild target='all':\n    echo {{target}}\n\n[private]\nhidden:\n    true\n_helper:\n    true\n@test *args: build\n    true\nalias b := build\n[doc('Ship it')]\ndeploy-prod:\n    true\n", 0600);
    make("package.json", "{\"name\": \"x\", \"scripts\": {\"dev\": \"vite\", \"test:unit\": \"vitest run\"}}", 0600);
    make("compose.yaml", "name: x\nservices:\n  web:\n    image: nginx\n    ports:\n      - \"80:80\"\n  \"db\":\n    image: postgres\nvolumes:\n  data:\n", 0600);
    check(ask(CompletionProvider::just_recipe, "") == std::vector<std::string>{"b", "build", "deploy-prod", "test"});
    check(ask(CompletionProvider::package_script, "") == std::vector<std::string>{"dev", "test:unit"});
    check(ask(CompletionProvider::compose_service, "") == std::vector<std::string>{"db", "web"});
    check(::mkdir((base + "/nested").c_str(), 0700) == 0);
    WordRequest nested{.client = 1, .request = 9, .provider = CompletionProvider::just_recipe, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    nested.directory.assign(base + "/nested");
    const auto from_child = reader.observe(nested).words;

    check(from_child.size() == 4 && from_child[1].text == "build" && from_child[1].description == "Build everything" && from_child[2].description == "Ship it" && from_child[0].description == "Alias of build");
    check(ask(CompletionProvider::branch, "").empty());

    // Command specs: offered for a command the shell runs, from the user's completions
    // directory when it compiles, else the one telar ships; an unchanged one is not sent again.
    const auto shipped = shippedSpecs();

    for (const auto& [name, source] : shipped) {
      try {
        static_cast<void>(ebnf::command_spec::compile(source));
      } catch (const std::exception& error) {
        std::fprintf(stderr, "spec %.*s: %s\n", static_cast<int>(name.size()), name.data(), error.what());
        check(false);
      }
    }

    check(std::ranges::find(shipped, std::string_view{"telar"}, &std::pair<std::string_view, std::string_view>::first) != shipped.end());
    make("bin/nmap", "", 0700);
    std::string reported = "gst";
    const auto spec = [&](std::string_view command, std::uint64_t known = 0) {
      WordRequest request{.client = 1, .request = 5, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

      request.prefix.assign(command);
      request.path.assign(base + "/bin");
      request.shell = IntegratedShell::zsh;
      request.names = std::allocate_shared<ds::String<ConcurrentMemory>>(AllocatorRef<ds::String<ConcurrentMemory>, ConcurrentMemory>{memory}, memory, reported);
      request.spec = true;
      request.known_digest = known;
      return reader.observe(request);
    };

    const auto nmap = spec("nmap");

    check(nmap.spec && nmap.command == "nmap" && nmap.spec_state == CommandSpecState::available && nmap.source.view().contains("nmap = ") && nmap.digest != 0);
    check(spec("nmap", nmap.digest).spec_state == CommandSpecState::unchanged && spec("nmap", nmap.digest).source.empty());
    check(spec("git").spec_state == CommandSpecState::unavailable);
    check(spec("cd").spec_state == CommandSpecState::available);
    check(spec("../nmap").spec_state == CommandSpecState::unavailable);
    // An alias completes as the command it stands for, through aliases of aliases; one that
    // names itself (ls='ls -G') stands for that command.
    make("bin/git", "", 0700);
    reported = "n=nmap gst=git%20status gl=gst%20--oneline less=less%20-R weird f";
    const auto alias = spec("n");

    check(alias.spec_state == CommandSpecState::available && alias.expansion == "nmap" && alias.source == nmap.source && alias.digest == nmap.digest);
    check(spec("gst").expansion == "git status" && spec("gst").source.view().contains("git = "));
    check(spec("gl").expansion == "git status --oneline");
    check(spec("less").spec_state == CommandSpecState::unavailable);
    check(spec("weird").spec_state == CommandSpecState::unavailable && spec("weird").expansion.empty());
    reported = "gst";
    check(::mkdir((base + "/telar").c_str(), 0700) == 0 && ::mkdir((base + "/telar/completions").c_str(), 0700) == 0);
    make("telar/completions/nmap.ebnf", "nmap = { \"--mine\" : \"The user's own\" } ;\n", 0600);
    const auto users = spec("nmap");

    check(users.spec_state == CommandSpecState::available && users.source.view().contains("--mine") && users.digest != nmap.digest);
    make("telar/completions/nmap.ebnf", "nmap = { \"--broken\" \n", 0600);
    check(spec("nmap").source == nmap.source);

    // This process is the user's, named; newer ones come first. The prefix also matches
    // longer process identifiers, newer than this one, so it need not be the first.
    WordRequest processes{.client = 1, .request = 3, .provider = CompletionProvider::process, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    processes.prefix.assign(std::to_string(::getpid()));
    const auto own = reader.observe(processes).words;
    const auto pid = std::to_string(::getpid());
    const auto found = std::ranges::find_if(own, [&](const Word& word) {
      return word.text == std::string_view{pid};
    });

    check(found != own.end() && !found->description.empty());
    check(std::ranges::is_sorted(own, std::greater{}, [](const Word& word) {
      return parseExact<long long>(word.text.view()).valueOr(0);
    }));
  }

  const telar::testing::Case case_git_context{"shell_integration.git_context", gitContext};
  const telar::testing::Case case_words{"shell_integration.words", words};

}
