#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.cli.worktree;
import telar.cli.command_limit;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime::cli;

  constexpr std::string_view identity = "example.invalid/team/repo";

  // Runs a shell command with Git kept from the user's configuration and returns its
  // standard output; a failure fails the case.
  std::string shell(const std::string& command) {
    const auto isolated = "GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null " + command + " 2>/dev/null";
    FILE* pipe = ::popen(isolated.c_str(), "r");

    check(pipe != nullptr, command);
    std::string output;
    ds::Array<char, 4096> buffer;

    while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), pipe)) {
      output.append(buffer.data(), count);
    }

    check(::pclose(pipe) == 0, command);
    return output;
  }

  // A repository with an origin and one commit, made the working directory, as `prepare` runs.
  std::string enterRepository() {
    std::string pattern = std::filesystem::temp_directory_path() / "telar-prepare-XXXXXX";

    check(::mkdtemp(pattern.data()) != nullptr);
    const auto root = std::filesystem::canonical(pattern).string();

    shell("cd '" + root + "' && git init -q -b main && git -c commit.gpgsign=false -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base && git remote add origin https://example.invalid/team/repo.git");
    check(::chdir(root.c_str()) == 0);
    return root;
  }

  // The other machine's telar, answering `repository receive` with `reply`, given the
  // commit it was asked to receive; it has no clone to list tips from.
  class Receiver final : public repository::RepositoryCapture {
  public:
    Receiver(Memory& memory, std::string (*reply)(std::string_view commit))
        : memory_(memory),
          reply_(reply) {}

    Text operator()(std::span<const std::string_view> words, int) override {
      if (std::ranges::find(words, "receive") == words.end()) {
        return Text{memory_};
      }

      const auto commit = std::ranges::find(words, "--commit");

      check(commit != words.end() && commit + 1 != words.end());
      return Text{memory_, reply_(*(commit + 1))};
    }

  private:
    Memory& memory_;
    std::string (*reply_)(std::string_view commit);
  };

  std::string reply(std::string_view path, std::string_view commit, bool ready) {
    return std::format(R"({{"path":"{}","commit":"{}","repository":"{}","repository_ready":{},"reused":false}})", path, commit, identity, ready ? "true" : "false");
  }

  // The outcome of preparing HEAD against `receiver`: the clone path, or the error.
  std::string prepared(Memory& memory, Receiver receiver) {
    try {
      const RepositoryOptions options{.action = RepositoryOptions::Action::prepare};

      return std::string{repository::prepare(memory, options, "telar", receiver).path.view()};
    } catch (const std::exception& error) {
      return error.what();
    }
  }

  // A reply that is not a ready clone of the commit sent is refused, so the dispatch
  // never pushes to or launches in a path the other machine did not vouch for, and the
  // transfer leaves no ref behind in the user's repository.
  void prepareRejectsBadReceiverReply() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const auto root = enterRepository();

    const auto transfers = [&] {
      return shell("git -C '" + root + "' for-each-ref refs/telar/transfer/");
    };

    // The fixture is sound: a ready clone of the commit is accepted.
    check(prepared(memory, Receiver{memory, [](std::string_view commit) {
      return reply("/srv/clones/repo", commit, true);
    }}) == "/srv/clones/repo");

    // A reply that does not parse is refused by the parser, under its own name.
    check(!prepared(memory, Receiver{memory, [](std::string_view) {
      return std::string{"not json"};
    }}).starts_with('/'));
    check(transfers().empty());

    const auto refused = ds::Array<std::string (*)(std::string_view), 3>{
        [](std::string_view commit) {
          return reply("clones/repo", commit, true);
        },
        [](std::string_view) {
          return reply("/srv/clones/repo", std::string(40, 'f'), true);
        },
        [](std::string_view commit) {
          return reply("/srv/clones/repo", commit, false);
        },
    };

    for (const auto answer : refused) {
      check(prepared(memory, Receiver{memory, answer}) == "InvalidPreparationResult");
      check(transfers().empty());
    }

    std::filesystem::remove_all(root);
  }

  // The other machine's telar as `prepare` reaches it: `repository tips` fails, and `repository
  // receive` keeps the words of every call and the bundle it was sent.
  class Recorder final : public repository::RepositoryCapture {
  public:
    explicit Recorder(Memory& memory)
        : memory_(memory) {}

    Text operator()(std::span<const std::string_view> words, int input) override {
      calls.emplace_back(words.begin(), words.end());
      if (std::ranges::find(words, "tips") != words.end()) {
        throw std::runtime_error{"tips unavailable"};
      }

      ds::Array<char, 4096> buffer;
      ssize_t count;

      while ((count = ::read(input, buffer.dataMut(), buffer.size())) > 0) {
        bundle.append(buffer.data(), static_cast<std::size_t>(count));
      }

      const auto commit = std::ranges::find(words, "--commit");

      check(commit != words.end() && commit + 1 != words.end());
      return Text{memory_, reply("/srv/clones/repo", *(commit + 1), true)};
    }

    Memory& memory_;
    std::vector<std::vector<std::string>> calls;
    std::string bundle;
  };

  // A machine that cannot list what its clone holds receives the whole history: the
  // dispatch goes on, and the bundle needs nothing the other side lacks.
  void prepareWithoutTipsSendsFullHistory() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    const auto root = enterRepository();

    shell("cd '" + root + "' && git -c commit.gpgsign=false -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m second");
    Recorder recorder{adapter};
    const RepositoryOptions options{.action = RepositoryOptions::Action::prepare};

    check(repository::prepare(adapter, options, "telar", recorder).path == "/srv/clones/repo");
    check(recorder.calls.size() == 2 && !recorder.bundle.empty());
    const auto file = root + "/../" + std::filesystem::path{root}.filename().string() + ".bundle";

    std::ofstream{file, std::ios::binary} << recorder.bundle;
    shell("cd '" + root + "' && rm -rf ../empty-clone && git init -q ../empty-clone && git -C ../empty-clone bundle verify '" + file + "'");
    std::filesystem::remove(file);
    std::filesystem::remove_all(root + "/../empty-clone");
    std::filesystem::remove_all(root);
  }

  // `--workspace` names the clone on the other machine for both the tips query and the receive.
  void prepareForwardsWorkspace() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    const auto root = enterRepository();
    Recorder recorder{adapter};
    const RepositoryOptions options{.action = RepositoryOptions::Action::prepare, .workspace = "/w"};

    static_cast<void>(repository::prepare(adapter, options, "telar", recorder));
    check(recorder.calls.size() == 2);
    for (const auto& words : recorder.calls) {
      const auto flag = std::ranges::find(words, "--workspace");

      check(flag != words.end() && flag + 1 != words.end() && *(flag + 1) == "/w");
    }

    std::filesystem::remove_all(root);
  }

  const telar::testing::Case case_prepare_rejects_bad_receiver_reply{"repository.prepare_rejects_bad_receiver_reply", prepareRejectsBadReceiverReply};
  const telar::testing::Case case_prepare_without_tips_sends_full_history{"repository.prepare_without_tips_sends_full_history", prepareWithoutTipsSendsFullHistory};
  const telar::testing::Case case_prepare_forwards_workspace{"repository.prepare_forwards_workspace", prepareForwardsWorkspace};

}
