#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <future>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.terminal.shell_integration.token;
import telar.runtime.terminal.shell_integration.words;
import telar.wire.editor;
import telar.wire.vocabulary;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void testReplyCap() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-cap-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};

    // More commands on PATH than one reply carries.
    for (int index = 0; index < 300; ++index) {
      const auto path = root + "/" + std::format("capcmd{:03}", index);
      auto* file = std::fopen(path.c_str(), "w");

      check(file != nullptr);
      std::fclose(file);
      check(::chmod(path.c_str(), 0700) == 0);
    }

    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.prefix.assign("capcmd");
    request.path.assign(root);
    request.names = std::allocate_shared<ds::String<telar::ConcurrentMemory>>(telar::AllocatorRef<ds::String<telar::ConcurrentMemory>, telar::ConcurrentMemory>{memory}, memory);
    const auto result = reader.observe(request);

    check(result.words.size() == WordReader::maximum_words, "a reply carries more words than the wire allows");
    check(result.truncated);
    check(std::ranges::is_sorted(result.words) && result.words.front().text == "capcmd000");
    std::filesystem::remove_all(root);
  }

  // More executables than the reader keeps before sorting: the shell's own names and builtins
  // are not crowded out, and the reply is the first of everything, sorted.
  void testNamesSurviveLongPaths() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-names-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};

    for (int index = 0; index < 1100; ++index) {
      const auto path = root + "/" + std::format("cmd{:04}", index);
      auto* file = std::fopen(path.c_str(), "w");

      check(file != nullptr);
      std::fclose(file);
      check(::chmod(path.c_str(), 0700) == 0);
    }

    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.path.assign(root);
    request.shell = IntegratedShell::zsh;
    request.names = std::allocate_shared<ds::String<telar::ConcurrentMemory>>(telar::AllocatorRef<ds::String<telar::ConcurrentMemory>, telar::ConcurrentMemory>{memory}, memory, "aafunc gst=git%20status");
    const auto result = reader.observe(request);
    const auto has = [&](std::string_view word) {
      return std::ranges::any_of(result.words, [&](const Word& found) {
        return found.text.view() == word;
      });
    };

    check(result.truncated && result.words.size() == WordReader::maximum_words, "the reply is cut to what the wire carries");
    check(has("aafunc") && has("cd"), "a function and a builtin are kept whatever PATH holds");
    check(std::ranges::is_sorted(result.words), "sorted");
    std::filesystem::remove_all(root);
  }

  // A client with as many requests waiting as the service keeps makes room by failing its
  // oldest, which the runtime answers, instead of losing the new one without a word.
  void testFullQueueFailsOldest() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WordService service{memory};
    WordRequest request{.client = 1, .request = 1, .provider = CompletionProvider::make_target, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.directory.assign("/nonexistent");
    // The first runs until it is collected; the next four wait.
    for (std::uint64_t id = 1; id <= 5; ++id) {
      request.request = id;
      check(!service.request(request), "a request with room drops none");
    }

    request.request = 6;
    const auto dropped = service.request(request);

    check(dropped && *dropped == 2, "the oldest waiting request is failed to make room");
    request.client = 2;
    request.request = 7;
    check(!service.request(request), "another client's requests have room of their own");
  }

  // Branches come with the remote-tracking ones, and a branch only a remote has by its own name
  // too, as git checkout takes it; a revision also names tags.
  void testReferenceWords() {
    if (std::system("git --version >/dev/null 2>&1") != 0) {
      return;
    }

    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-refs-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};
    const auto script = "cd '" + root + "' && git init -q -b main && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m one && git update-ref refs/remotes/origin/main HEAD && git update-ref refs/remotes/origin/only-remote HEAD && git tag v1";

    check(std::system(script.c_str()) == 0);
    const auto words = [&](CompletionProvider provider) {
      WordReader reader{memory};
      WordRequest request{.client = 1, .request = 2, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};

      request.directory.assign(root);
      std::vector<std::string> found;

      for (const auto& word : reader.observe(request).words) {
        found.emplace_back(word.text.view());
      }

      return found;
    };

    check(words(CompletionProvider::branch) == std::vector<std::string>{"main", "only-remote", "origin/main", "origin/only-remote"}, "local and remote branches, and the remote one by its own name");
    check(words(CompletionProvider::reference) == std::vector<std::string>{"main", "only-remote", "origin/main", "origin/only-remote", "v1"}, "a revision names tags too");
    std::filesystem::remove_all(root);
  }

  // A comment line of only #, as a justfile's dividers, is skipped, not the end of the recipes.
  void testJustfileDividers() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-just-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};

    std::ofstream{root + "/justfile"} << "#\n####\n# Build it\nbuild:\n    make\n\n#\ntest:\n    make test\n";
    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::just_recipe, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.directory.assign(root);
    const auto words = reader.observe(request).words;

    check(words.size() == 2 && words[0].text == "build" && words[0].description == "Build it" && words[1].text == "test", "the recipes after a divider are listed");
    std::filesystem::remove_all(root);
  }

  void testTokenParse() {
    const auto valid = std::string(16, 'a') + "0123456789abcdef";
    const auto token = ShellToken::parse(valid);

    check(token && token->text() == valid && token->signs(valid));

    // A remote shell announces the token: anything but 32 lowercase hexadecimal digits is refused.
    check(!ShellToken::parse(valid.substr(1)), "a short token was accepted");
    check(!ShellToken::parse(valid + "0"), "a long token was accepted");
    check(!ShellToken::parse({}));
    check(!ShellToken::parse(std::string(16, 'A') + "0123456789abcdef"), "uppercase digits were accepted");
    check(!ShellToken::parse(std::string(31, 'a') + "g"), "a non-hexadecimal digit was accepted");
    check(!ShellToken::parse(std::string(31, 'a') + "\x1b"), "a control byte was accepted");
  }

  // A FIFO named like a makefile, as a cloned repository can hold, and a package.json past the
  // size the reader takes: neither blocks the completion worker nor is read.
  void testIgnoresSpecialAndOversizedFiles() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-files-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};
    const auto observe = [&](CompletionProvider provider) {
      WordReader reader{memory};
      WordRequest request{.client = 1, .request = 2, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};

      request.directory.assign(root);
      auto pending = std::async(std::launch::async, [&] {
        return reader.observe(request);
      });

      check(pending.wait_for(std::chrono::seconds{5}) == std::future_status::ready, "reading the directory's files blocked");
      return pending.get();
    };

    check(::mkfifo((root + "/Makefile").c_str(), 0600) == 0);
    check(observe(CompletionProvider::make_target).words.empty());

    const std::string scripts = R"({"scripts": {"build": "make"}})";

    std::ofstream{root + "/package.json"} << scripts;
    check(observe(CompletionProvider::package_script).words.size() == 1);

    std::ofstream{root + "/package.json"} << scripts << std::string(WordReader::maximum_file, ' ');
    check(observe(CompletionProvider::package_script).words.empty(), "a package.json past the limit was read");
    std::filesystem::remove_all(root);
  }

  // A description past the field is cut at a character, never inside one: the wire refuses
  // text that is not UTF-8.
  void testCutsDescriptionsAtCharacters() {
    // What a completion word's description holds on the wire.
    constexpr std::size_t description_bytes = 256;
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-cut-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};
    std::string command{"x"};

    // One byte, then two-byte characters: the 256th byte starts one.
    for (int index = 0; index < 200; ++index) {
      command += "\u00e9";
    }

    std::ofstream{root + "/package.json"} << R"({"scripts": {"build": ")" << command << R"("}})";
    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::package_script, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.directory.assign(root);
    const auto result = reader.observe(request);

    check(result.words.size() == 1);
    const auto description = result.words.front().description.view();

    check(!description.empty() && description.size() <= description_bytes, "the description was not cut to the field");
    check(inspectUtf8(description) == Utf8Validation::valid, "the description was cut inside a character");
    std::filesystem::remove_all(root);
  }

  // An alias of an alias can stand for more words than the reply's field holds: it is dropped,
  // not sent over the limit.
  void testDropsLongAliasExpansions() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    const auto names = "g=h%20" + std::string(250, 'a') + " h=git%20" + std::string(250, 'b') + " git";
    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.spec = true;
    request.prefix.assign("g");
    request.names = std::allocate_shared<ds::String<telar::ConcurrentMemory>>(telar::AllocatorRef<ds::String<telar::ConcurrentMemory>, telar::ConcurrentMemory>{memory}, memory, names);
    const auto result = reader.observe(request);

    check(result.expansion.size() <= CommandSpec::maximum_expansion_bytes, "the expansion is longer than the reply carries");
  }

  // Tab's paths: the direct children of the directory typed that start with what follows its
  // last slash, written back as typed, whatever lies deeper or is ignored.
  void testDirectoryWords() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-word-paths-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const std::string root{directory.data()};

    // Deeper matches than one reply carries must not crowd out the child.
    for (int index = 0; index < 60; ++index) {
      const auto nested = root + std::format("/d{:02}", index);

      std::filesystem::create_directory(nested);
      std::ofstream{nested + "/main.c"};
    }

    std::ofstream{root + "/main-application-config.yaml"};
    std::ofstream{root + "/.env"};
    std::ofstream{root + "/README"};
    std::ofstream{root + "/gradlew"};
    check(::chmod((root + "/gradlew").c_str(), 0700) == 0);
    std::filesystem::create_directory(root + "/node_modules");
    std::filesystem::create_directory_symlink(root + "/d00", root + "/linked");

    const auto words = [&](CompletionProvider provider, std::string_view prefix, std::string_view home = {}) {
      WordReader reader{memory};
      WordRequest request{.client = 1, .request = 2, .provider = provider, .prefix = {}, .directory = {}, .home = {}, .path = {}};

      request.prefix.assign(prefix);
      request.directory.assign(root);
      request.home.assign(home);
      const auto result = reader.observe(request);
      std::vector<std::string> found;

      for (const auto& word : result.words) {
        found.emplace_back(word.text.view());
      }

      return std::pair{found, result.truncated};
    };

    check(words(CompletionProvider::path, "ma").first == std::vector<std::string>{"main-application-config.yaml"}, "a direct child is found whatever lies deeper");
    const auto [all, cut] = words(CompletionProvider::path, "");

    check(all.size() == 65 && !cut && std::ranges::is_sorted(all), "every direct child, sorted");
    check(std::ranges::find(all, ".env") == all.end() && std::ranges::find(all, "node_modules/") != all.end(), "dot files stay hidden, ignored directories do not");
    check(std::ranges::find(all, "linked/") != all.end(), "a link to a directory is a directory");
    check(words(CompletionProvider::path, ".e").first == std::vector<std::string>{".env"}, "a dot typed shows dot files");
    check(words(CompletionProvider::directory, "").first.size() == 62, "directories alone");
    check(words(CompletionProvider::executable, "./gra").first == std::vector<std::string>{"./gradlew"}, "an executable named by its path");
    check(words(CompletionProvider::executable, "./RE").first.empty(), "a file that does not run is no command");
    check(words(CompletionProvider::path, "d00/m").first == std::vector<std::string>{"d00/main.c"}, "a directory typed is read, and written back as typed");
    check(words(CompletionProvider::path, "~/RE", root).first == std::vector<std::string>{"~/README"}, "~ reads the home and keeps ~ in what is written");
    check(words(CompletionProvider::path, "$HOME/RE", root).first.empty(), "a variable is the shell's to expand");

    for (int index = 0; index < 300; ++index) {
      std::ofstream{root + std::format("/many{:03}", index)};
    }

    const auto [many, truncated] = words(CompletionProvider::path, "many");

    check(many.size() == WordReader::maximum_words && truncated && many.front() == "many000", "a cut list says so");
    std::filesystem::remove_all(root);
  }

  // A shell `ssh` reached runs commands this host cannot see: their specs are offered anyway, so
  // a remote line completes its subcommands and flags.
  void testRemoteSpecs() {
    telar::testing::TestMemory adapter;
    telar::ConcurrentMemory& memory = adapter;
    WordReader reader{memory};
    WordRequest request{.client = 1, .request = 2, .provider = CompletionProvider::command, .prefix = {}, .directory = {}, .home = {}, .path = {}};

    request.spec = true;
    request.prefix.assign("git");
    request.path.assign("/nonexistent");
    check(reader.observe(request).spec_state == CommandSpecState::unavailable, "a command this shell does not run has no spec");
    request.remote = true;
    check(reader.observe(request).spec_state == CommandSpecState::available, "a remote shell's command has its spec");
  }

  const telar::testing::Case case_reply_cap{"shell_words.reply_cap", testReplyCap};
  const telar::testing::Case case_directory_words{"shell_words.directory_words", testDirectoryWords};
  const telar::testing::Case case_remote_specs{"shell_words.remote_specs", testRemoteSpecs};
  const telar::testing::Case case_names_survive_long_paths{"shell_words.names_survive_long_paths", testNamesSurviveLongPaths};
  const telar::testing::Case case_full_queue_fails_oldest{"shell_words.full_queue_fails_oldest", testFullQueueFailsOldest};
  const telar::testing::Case case_reference_words{"shell_words.reference_words", testReferenceWords};
  const telar::testing::Case case_justfile_dividers{"shell_words.justfile_dividers", testJustfileDividers};
  const telar::testing::Case case_token_parse{"shell_words.token_parse", testTokenParse};
  const telar::testing::Case case_ignores_special_and_oversized_files{"shell_words.ignores_special_and_oversized_files", testIgnoresSpecialAndOversizedFiles};
  const telar::testing::Case case_cuts_descriptions_at_characters{"shell_words.cuts_descriptions_at_characters", testCutsDescriptionsAtCharacters};
  const telar::testing::Case case_drops_long_alias_expansions{"shell_words.drops_long_alias_expansions", testDropsLongAliasExpansions};

}
