#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cerrno>
#include <poll.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.vocabulary;
import telar.platform.fs;
import telar.platform.process;
import telar.git.checkout;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Rejected {};

  // Runs `command` to its end and returns its exit code and standard output.
  std::pair<int, std::string> execute(Command<Memory>& command) {
    PipeProcess process{command.specification(TerminalSize{.cols = 80, .rows = 24})};
    std::string output;
    std::array<char, 4096> buffer;

    std::array<int, 2> open{process.output(), process.error()};

    process.closeInput();
    while (open[0] >= 0 || open[1] >= 0) {
      std::array<pollfd, 2> streams{{{.fd = open[0], .events = POLLIN}, {.fd = open[1], .events = POLLIN}}};

      check(::poll(streams.data(), streams.size(), 10'000) > 0);
      for (std::size_t index = 0; index < streams.size(); ++index) {
        if (streams[index].fd < 0 || streams[index].revents == 0) {
          continue;
        }

        const auto count = ::read(streams[index].fd, buffer.data(), buffer.size());
        if (count > 0 && index == 0) {
          output.append(buffer.data(), static_cast<std::size_t>(count));
        } else if (count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)) {
          open[index] = -1;
        }
      }
    }

    std::optional<int> status;

    while (!(status = process.reap())) {
      std::this_thread::sleep_for(std::chrono::milliseconds{5});
    }

    return {shellExitCode(*status), std::move(output)};
  }

  int shell(const std::string& command) {
    const auto status = std::system(command.c_str());

    return status < 0 ? status : WEXITSTATUS(status);
  }

  // A repository can name any program as a filter driver, and git runs it on files it hashes: git
  // run hardened against a repository overrides every driver it configures, so neither the
  // inspection nor a status runs the repository's program.
  void testHardenedGitOverridesRepositoryFilters() {
    if (shell("git --version >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    TemporaryDirectory temporary{"/tmp/telar-hardened-git-XXXXXX"};
    const std::string root{temporary.path()};
    const auto repository = root + "/repository";
    const auto marker = root + "/filter-ran";
    const auto in = "cd '" + repository + "' && ";

    check(::setenv("HOME", root.c_str(), 1) == 0 && ::setenv("GIT_CONFIG_NOSYSTEM", "1", 1) == 0);
    check(shell("mkdir -p '" + repository + "' && " + in + "git init -q . && git config user.name Test && git config user.email test@example.com && git config commit.gpgsign false") == 0);
    check(shell(in + "printf 'a.txt filter=evil\\n' > .gitattributes && printf 'alpha\\n' > a.txt && git add -A && git commit -q -m base") == 0);
    check(shell(in + "git config filter.evil.clean 'touch \"" + marker + "\"; cat' && printf 'omega\\n' > a.txt") == 0);
    // The fixture: an unhardened status runs the driver. The content keeps its size, so git
    // must hash the file, through the driver, to tell whether it changed.
    check(shell(in + "git status --porcelain >/dev/null 2>&1") == 0 && std::filesystem::exists(marker));
    std::filesystem::remove(marker);
    check(shell(in + "printf 'gamma\\n' > a.txt") == 0);

    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    HardenedGit<Memory> git{memory, repository};

    git.inspect(execute, [] {
      throw Rejected{};
    });
    const auto [status, output] = git.with({"status", "--porcelain"}, execute);

    check(status == 0 && output.contains("a.txt"));
    check(!std::filesystem::exists(marker), "the repository's filter driver ran");
  }

  // A repository that may fetch objects lazily is observed only by a git that honors
  // GIT_NO_LAZY_FETCH; an unreadable listing is refused too.
  void testHardenedGitRejectsLazyFetchWithOldGit() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;

    const auto rejected = [&](int listing_status, std::string_view listing) {
      HardenedGit<Memory> git{memory, "/"};

      try {
        git.inspect(
            [&](Command<Memory>& command) {
              const auto arguments = command.arguments();
              if (std::string_view{arguments.back()} == "version") {
                return std::pair{0, std::string{"git version 2.44.0\n"}};
              }

              return std::pair{listing_status, std::string{listing}};
            },
            [] {
              throw Rejected{};
            }
        );
      } catch (const Rejected&) {
        return true;
      }

      return false;
    };

    using namespace std::string_view_literals;

    check(rejected(0, "local\0remote.origin.promisor\ntrue\0"sv));
    check(rejected(0, "local\0extensions.partialclone\norigin\0"sv));
    check(rejected(2, ""));
    check(!rejected(1, ""));
    check(!rejected(0, "local\0filter.lfs.clean\ngit-lfs clean\0"sv));
  }

  const telar::testing::Case case_hardened_filters{"hardened_git.overrides_repository_filters", testHardenedGitOverridesRepositoryFilters};
  const telar::testing::Case case_hardened_lazy_fetch{"hardened_git.rejects_lazy_fetch_with_old_git", testHardenedGitRejectsLazyFetchWithOldGit};

}
