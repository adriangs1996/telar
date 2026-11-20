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
import telar.base.ds;
import telar.base.memory.allocators;

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

  const telar::testing::Case case_reply_cap{"shell_words.reply_cap", testReplyCap};
  const telar::testing::Case case_token_parse{"shell_words.token_parse", testTokenParse};
  const telar::testing::Case case_ignores_special_and_oversized_files{"shell_words.ignores_special_and_oversized_files", testIgnoresSpecialAndOversizedFiles};

}
