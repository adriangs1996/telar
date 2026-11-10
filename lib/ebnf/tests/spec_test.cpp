#ifdef __clangd__
static_assert(true);
#endif
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <print>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <random>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <gtest/gtest.h>

import telar.ebnf.matcher;
namespace {
  using words = std::vector<std::string_view>;

  auto readSpec(std::string_view name) -> std::string {
    auto file = std::ifstream{std::string{EBNF_SPECS_DIR} + "/" + std::string{name} + ".ebnf", std::ios::binary};

    if (!file) {
      throw std::runtime_error("Missing spec " + std::string{name});
    }

    return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
  }

  auto loadSpec(std::string_view name) -> const ebnf::command_spec & {
    static const auto git = ebnf::command_spec::compile(readSpec("git"));
    static const auto cd = ebnf::command_spec::compile(readSpec("cd"));
    static const auto ssh = ebnf::command_spec::compile(readSpec("ssh"));
    static const auto make = ebnf::command_spec::compile(readSpec("make"));
    static const auto kill = ebnf::command_spec::compile(readSpec("kill"));
    static const auto nmap = ebnf::command_spec::compile(readSpec("nmap"));

    if (name == "git") {
      return git;
    }
    if (name == "cd") {
      return cd;
    }
    if (name == "ssh") {
      return ssh;
    }
    if (name == "make") {
      return make;
    }
    if (name == "nmap") {
      return nmap;
    }
    return kill;
  }

  auto contains(const std::vector<std::string> &shown, std::string_view expected) -> bool {
    return std::ranges::find(shown, expected) != shown.end();
  }

  class Spec : public testing::Test {
  protected:
    std::unique_ptr<ebnf::match_scratch> scratch_ = std::make_unique<ebnf::match_scratch>();
    std::array<ebnf::candidate, 256> out_{};

    auto texts(std::string_view spec, const words &line, std::string_view partial) -> std::vector<std::string> {
      const auto result = loadSpec(spec).complete(line, partial, *scratch_, out_);
      EXPECT_EQ(result.status, ebnf::match_status::valid);
      EXPECT_FALSE(result.truncated);
      auto shown = std::vector<std::string>{};

      for (std::size_t index = 0; index < result.count; ++index) {
        const auto &candidate = out_[index];
        shown.push_back((candidate.kind == ebnf::candidate_kind::provider ? "@" : "") + std::string{candidate.prefix} + std::string{candidate.text});
      }

      return shown;
    }


    auto firstInvalid(std::string_view spec, const words &line) -> std::int64_t {
      const auto result = loadSpec(spec).check(line, *scratch_);
      EXPECT_NE(result.status, ebnf::match_status::unknown);
      return result.status == ebnf::match_status::invalid ? std::int64_t{result.word} : -1;
    }
  };

  TEST_F(Spec, EveryShippedSpecCompiles) {
    auto names = std::vector<std::string>{};
    for (const auto &entry : std::filesystem::directory_iterator{EBNF_SPECS_DIR}) {
      if (entry.path().extension() == ".ebnf") {
        names.push_back(entry.path().stem().string());
      }
    }
    EXPECT_GE(names.size(), 6u);
    for (const auto &name : names) {
      SCOPED_TRACE(name);
      EXPECT_NO_THROW(static_cast<void>(ebnf::command_spec::compile(readSpec(name))));
    }
  }

  TEST_F(Spec, GitSubcommandsAndDescriptions) {
    const auto result = loadSpec("git").complete({}, "sw", *scratch_, out_);

    ASSERT_EQ(result.count, 1u);
    EXPECT_EQ(out_[0].text, "switch");
    EXPECT_EQ(out_[0].description, "Switch branches");

    const auto subcommands = texts("git", {}, "");
    for (const auto name : {"switch", "checkout", "branch", "add", "restore", "commit", "push", "pull", "fetch", "merge", "rebase", "stash", "log", "diff", "status"}) {
      SCOPED_TRACE(name);
      EXPECT_NE(std::ranges::find(subcommands, name), subcommands.end());
    }

    EXPECT_EQ(texts("git", {}, "st"), (std::vector<std::string>{"stash", "status"}));
  }

  TEST_F(Spec, GitCompletesFlagsProvidersAndValues) {
    EXPECT_TRUE(contains(texts("git", {"switch"}, ""), "@branch"));
    EXPECT_TRUE(contains(texts("git", {"switch"}, "--d"), "--detach"));
    EXPECT_TRUE(contains(texts("git", {"switch"}, "--d"), "--discard-changes"));
    EXPECT_FALSE(contains(texts("git", {"switch"}, "--d"), "@branch"));
    EXPECT_TRUE(contains(texts("git", {"-C", "repo", "commit"}, "--am"), "--amend"));
    EXPECT_TRUE(contains(texts("git", {"push"}, ""), "@remote"));
    EXPECT_TRUE(contains(texts("git", {"push", "origin"}, ""), "@branch"));
    EXPECT_FALSE(contains(texts("git", {"push"}, ""), "@branch"));
    EXPECT_TRUE(contains(texts("git", {"log"}, "--format="), "--format=oneline"));
    EXPECT_TRUE(contains(texts("git", {"log"}, "--format="), "@--format=any"));
    EXPECT_EQ(texts("git", {"diff"}, "--color=n"), (std::vector<std::string>{"--color=never"}));
    EXPECT_TRUE(contains(texts("git", {"rebase"}, "--empty="), "--empty=drop"));
    EXPECT_TRUE(contains(texts("git", {"stash"}, "p"), "pop"));
    EXPECT_TRUE(contains(texts("git", {"stash", "pop"}, ""), "@stash"));
    EXPECT_TRUE(contains(texts("git", {"restore", "--"}, ""), "@file"));
    EXPECT_EQ(texts("git", {"restore", "--"}, "-"), (std::vector<std::string>{"@file"}));
  }

  TEST_F(Spec, GitChecksRealCommandLines) {
    EXPECT_EQ(firstInvalid("git", {"switch", "-c", "feature", "origin/main"}), -1);
    EXPECT_EQ(firstInvalid("git", {"commit", "-am", "fix the build", "--no-verify"}), -1);
    EXPECT_EQ(firstInvalid("git", {"log", "--oneline", "-5", "--author=me", "-n3", "main..topic", "--", "src"}), -1);
    EXPECT_EQ(firstInvalid("git", {"push", "-u", "origin", "HEAD", "--force-with-lease"}), -1);
    EXPECT_EQ(firstInvalid("git", {"pull", "--rebase=merges", "origin", "main"}), -1);
    EXPECT_EQ(firstInvalid("git", {"diff", "--cached", "-U5", "--stat", "HEAD~1"}), -1);
    EXPECT_EQ(firstInvalid("git", {"--no-pager", "-C", "..", "status", "-sb", "--porcelain=v2"}), -1);
    EXPECT_EQ(firstInvalid("git", {"stash", "push", "-m", "wip", "--", "a.txt"}), -1);
    EXPECT_EQ(firstInvalid("git", {"stash", "-u"}), -1);

    EXPECT_EQ(firstInvalid("git", {"swtich", "main"}), 0);
    EXPECT_EQ(firstInvalid("git", {"switch", "--frobnicate"}), 1);
    EXPECT_EQ(firstInvalid("git", {"log", "--format", "oneline"}), 1);
    EXPECT_EQ(firstInvalid("git", {"status", "--porcelain=v3"}), 1);
    EXPECT_EQ(firstInvalid("git", {"stash", "a.txt"}), 1);
    EXPECT_EQ(firstInvalid("git", {"push", "origin", "main", "--", "x"}), 3);
  }

  TEST_F(Spec, CdSshMakeKill) {
    EXPECT_EQ(texts("cd", {}, ""), (std::vector<std::string>{"-L", "-P", "-", "@directory"}));
    EXPECT_EQ(texts("cd", {"-P"}, ""), (std::vector<std::string>{"-", "@directory"}));
    EXPECT_EQ(firstInvalid("cd", {"-L", "/tmp", "extra"}), 2);

    EXPECT_TRUE(contains(texts("ssh", {}, ""), "@ssh_host"));
    EXPECT_TRUE(contains(texts("ssh", {"-i"}, ""), "@file"));
    EXPECT_TRUE(contains(texts("ssh", {"host"}, ""), "@command"));
    EXPECT_EQ(firstInvalid("ssh", {"-vvv", "-p2222", "-oStrictHostKeyChecking=no", "user@host", "-NL", "8080:localhost:80"}), -1);
    EXPECT_EQ(firstInvalid("ssh", {"host", "ls", "-la", "/tmp"}), -1);
    EXPECT_EQ(firstInvalid("ssh", {"-p", "port", "host"}), 1);
    EXPECT_EQ(firstInvalid("ssh", {"-Z", "host"}), 0);

    EXPECT_TRUE(contains(texts("make", {}, ""), "@make_target"));
    EXPECT_TRUE(contains(texts("make", {"-C"}, ""), "@directory"));
    EXPECT_TRUE(contains(texts("make", {}, "--dir"), "--directory="));
    EXPECT_EQ(firstInvalid("make", {"-j8", "-C", "build", "all", "CFLAGS=-O2", "--jobs=4", "-k"}), -1);
    EXPECT_EQ(firstInvalid("make", {"--jobs=many"}), 0);

    EXPECT_TRUE(contains(texts("kill", {}, "-"), "-s"));
    EXPECT_TRUE(contains(texts("kill", {}, "-T"), "-TERM"));
    EXPECT_TRUE(contains(texts("kill", {"-s"}, "K"), "KILL"));
    EXPECT_TRUE(contains(texts("kill", {"-9"}, ""), "@process"));
    EXPECT_EQ(firstInvalid("kill", {"-9", "1234", "%1"}), -1);
    EXPECT_EQ(firstInvalid("kill", {"-s", "TERM", "42"}), -1);
    EXPECT_EQ(firstInvalid("kill", {"-l", "9"}), -1);
    EXPECT_EQ(firstInvalid("kill", {"--", "-123"}), -1);
    EXPECT_EQ(firstInvalid("kill", {"-NOPE", "1"}), 0);
    EXPECT_EQ(firstInvalid("kill", {"-s", "NOPE"}), 1);
  }

  TEST_F(Spec, Nmap) {
    const auto scans = loadSpec("nmap").complete({}, "-sS", *scratch_, out_);
    const auto syn = std::ranges::find(std::span{out_}.first(scans.count), std::string_view{"-sS"}, &ebnf::candidate::text);
    ASSERT_NE(syn, std::span{out_}.first(scans.count).end());
    EXPECT_EQ(syn->description, "TCP SYN scan");
    EXPECT_TRUE(contains(texts("nmap", {}, "-s"), "-sV"));
    EXPECT_TRUE(contains(texts("nmap", {}, "--script"), "--script-args"));
    EXPECT_TRUE(contains(texts("nmap", {"-oX"}, ""), "@file"));
    for (const auto timing : {"-T0", "-T3", "-T5"}) {
      EXPECT_TRUE(contains(texts("nmap", {}, "-T"), timing));
    }
    EXPECT_TRUE(contains(texts("nmap", {"--version-intensity"}, "7"), "7"));
    EXPECT_EQ(firstInvalid("nmap", {"-sS", "-sV", "-T4", "-p22,80,443", "-Pn", "--script=default", "-oA", "scan", "10.0.0.0/24"}), -1);
    EXPECT_EQ(firstInvalid("nmap", {"-A", "-p", "1-1024", "--top-ports", "100", "scanme.nmap.org"}), -1);
    EXPECT_EQ(firstInvalid("nmap", {"--frobnicate", "host"}), 0);
    EXPECT_EQ(firstInvalid("nmap", {"-T9", "host"}), 0);
    EXPECT_TRUE(contains(texts("nmap", {"-sV"}, ""), "@ssh_host"));
    EXPECT_EQ(firstInvalid("nmap", {"--version-intensity", "high"}), 1);
  }

  // Arbitrary lines, including clusters, glued words and raw bytes, keep every result in bounds.
  TEST_F(Spec, RandomLinesStayInBounds) {
    constexpr auto vocabulary = std::to_array<std::string_view>({
        "log", "commit", "push", "stash", "-", "--", "-am", "-vvv", "-n3", "-5", "--format=", "--color=al",
        "--oneline", "origin", "main", "-C", "x", "--frob", "-xyz", "", "\xff\x01", "-U", "-U7", "--rebase=merges",
    });
    auto random = std::mt19937{20261109};
    auto line = words{};
    constexpr std::size_t max_length = 40;
    // One buffer per word index, so every view in the line stays valid.
    auto bytes = std::vector<std::string>(max_length);

    for (int round = 0; round < 3000; ++round) {
      line.clear();
      const auto length = random() % max_length;

      for (std::size_t index = 0; index < length; ++index) {
        if (random() % 8 == 0) {
          auto &noise = bytes[index];
          noise.assign(random() % 6, '\0');
          std::ranges::generate(noise, [&random] { return static_cast<char>(random()); });
          line.emplace_back(noise);
        } else {
          line.push_back(vocabulary[random() % vocabulary.size()]);
        }
      }

      const auto checked = loadSpec("git").check(line, *scratch_);
      ASSERT_NE(checked.status, ebnf::match_status::unknown);
      ASSERT_TRUE(checked.status == ebnf::match_status::valid || checked.word < line.size());

      const auto partial = vocabulary[random() % vocabulary.size()];
      const auto completed = loadSpec("git").complete(line, partial, *scratch_, std::span{out_}.first(random() % out_.size()));
      ASSERT_EQ(completed.status, checked.status);
      ASSERT_LE(completed.count, out_.size());
    }
  }

  TEST(SpecCompile, RandomSourcesFailOnlyWithLoadErrors) {
    constexpr auto pieces = std::to_array<std::string_view>({
        "a", "b", " = ", " ; ", " | ", " , ", "( ", " )", "[ ", " ]", "{ ", " }", "\"x\"", "'-y'", "@p", "@any",
        " : ", "\"d\"", " ~ ", "(* c *)", " - ", " + ", " ? ", " * ", ".", "@",
    });
    auto random = std::mt19937{7};
    auto source = std::string{};

    for (int round = 0; round < 5000; ++round) {
      source = random() % 2 == 0 ? "a = " : "";
      const auto length = random() % 24;

      for (std::size_t index = 0; index < length; ++index) {
        source += pieces[random() % pieces.size()];
      }

      try {
        static_cast<void>(ebnf::command_spec::compile(source));
      } catch (const std::invalid_argument &) {
      } catch (const std::length_error &) {
      }
    }
  }

  // Run with: ebnf_tests --gtest_also_run_disabled_tests --gtest_filter='*Benchmark*'
  TEST_F(Spec, DISABLED_Benchmark) {
    const auto &git = loadSpec("git");
    auto long_log = words{"--no-pager", "-C", "repo", "log"};
    const auto log_tail = std::array<std::string_view, 12>{"--oneline", "--graph", "--author", "me", "--since=2.weeks", "-n", "20", "--no-merges", "-p", "--stat", "main..topic", "--decorate=short"};

    while (long_log.size() < 48) {
      long_log.push_back(log_tail[long_log.size() % log_tail.size()]);
    }
    long_log.insert(long_log.end(), {"--", "src"});

    auto many_files = words{"add", "-v"};
    while (many_files.size() < 50) {
      many_files.emplace_back("src/file.cpp");
    }

    const auto clusters = words{"commit", "-avm", "message", "-S", "--trailer", "Co: x", "--", "a", "b"};

    const auto measure = [&](const char *label, const words &line, std::string_view partial) {
      constexpr int rounds = 2000;
      std::size_t candidates = 0;
      const auto check_start = std::chrono::steady_clock::now();
      for (int round = 0; round < rounds; ++round) {
        candidates += git.check(line, *scratch_).status == ebnf::match_status::valid ? 1 : 0;
      }
      const auto check_end = std::chrono::steady_clock::now();
      for (int round = 0; round < rounds; ++round) {
        candidates += git.complete(line, partial, *scratch_, out_).count;
      }
      const auto complete_end = std::chrono::steady_clock::now();
      const auto per = [&](auto begin, auto end) {
        return std::chrono::duration<double, std::micro>(end - begin).count() / rounds;
      };
      ASSERT_EQ(git.check(line, *scratch_).status, ebnf::match_status::valid) << label;
      std::println("{:<28} words={:3} items={:5} check={:7.2f} us complete={:7.2f} us ({})", label, line.size(), scratch_->itemsUsed(), per(check_start, check_end), per(check_end, complete_end), candidates);
    };

    measure("git log, many options", long_log, "--");
    measure("git add, many files", many_files, "");
    measure("git commit, clusters", clusters, "");
    measure("git, empty line", {}, "");
  }
}
