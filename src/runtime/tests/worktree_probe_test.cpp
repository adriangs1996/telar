#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/types.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.runtime.workspaces.git_probe;
import telar.runtime.worktrees.git_probe;
import telar.vocabulary;
import telar.platform.process;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  void runGit(ConcurrentMemory& memory, const std::string& root, std::initializer_list<std::string_view> arguments) {
    std::array<std::string_view, 32> complete;
    std::size_t count = 0;

    for (const auto prefix : {"git", "-c", "user.name=Runtime Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"}) {
      complete[count++] = prefix;
    }

    for (const auto argument : arguments) {
      complete[count++] = argument;
    }

    Command command{memory, Launch{.cwd = root, .arguments = std::span{complete}.first(count)}, CommandPurpose::administration};
    CommandOutput output{memory, 4096};

    check(output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{5}) == 0);
  }

  // A workspace counts untracked files as uncommitted work, as git status --porcelain lists them,
  // and ignored ones as nothing.
  void untrackedFiles(ConcurrentMemory& memory) {
    std::array<char, 64> directory{};

    std::strcpy(directory.data(), "/tmp/telar-git-test.XXXXXX");
    check(::mkdtemp(directory.data()) != nullptr);
    const std::string root{directory.data()};

    runGit(memory, root, {"init", "--quiet", "--initial-branch=main", "--template="});
    std::ofstream{root + "/.gitignore"} << "ignored.txt\n";
    runGit(memory, root, {"add", ".gitignore"});
    runGit(memory, root, {"commit", "--quiet", "-m", "Initial fixture"});
    WorkspaceGitProbe probe{memory};
    WorkspaceGitRequest request{.identity = 3};

    request.path.assign(root);
    check(probe.observe(request).dirty == false);
    std::ofstream{root + "/ignored.txt"} << "ignored\n";
    check(probe.observe(request).dirty == false);
    std::ofstream{root + "/untracked.txt"} << "untracked\n";
    check(probe.observe(request).dirty == true);
    std::filesystem::remove_all(root);
  }

  void testWorktreeProbe() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;

    untrackedFiles(memory);
    std::array<char, 64> directory{};

    std::strcpy(directory.data(), "/tmp/telar-git-test.XXXXXX");
    check(::mkdtemp(directory.data()) != nullptr);
    const std::string root{directory.data()};

    runGit(memory, root, {"init", "--quiet", "--initial-branch=main", "--template="});
    std::ofstream{root + "/file.txt"} << "initial\n";
    runGit(memory, root, {"add", "file.txt"});
    runGit(memory, root, {"commit", "--quiet", "-m", "Initial fixture"});
    runGit(memory, root, {"checkout", "--quiet", "-b", "feature"});
    std::ofstream{root + "/file.txt", std::ios::app} << "committed\n";
    runGit(memory, root, {"add", "file.txt"});
    runGit(memory, root, {"commit", "--quiet", "-m", "Changed fixture"});
    std::ofstream{root + "/file.txt", std::ios::app} << "uncommitted\n";
    std::ofstream{root + "/.gitattributes"} << "*.txt filter=unsafe\n";
    const std::string dangerous = "touch " + root + "/unexpected-execution; cat";

    runGit(memory, root, {"config", "filter.unsafe.clean", dangerous});
    runGit(memory, root, {"config", "core.fsmonitor", dangerous});
    runGit(memory, root, {"config", "diff.external", dangerous});
    WorktreeGitProbe probe{memory};
    WorktreeProbeRequest request{};

    request.identity = 7;
    request.path.assign(root);
    request.base.assign("main");
    const auto result = probe.observe(request);

    check(result.present && result.measured && result.dirty && result.identity == 7);
    check(result.branch.view() == "feature" && result.added == 2 && result.removed == 0 && result.files == 1 && result.ahead == 1);
    WorkspaceGitProbe workspace_probe{memory};
    WorkspaceGitRequest workspace_request{.identity = 9};

    workspace_request.path.assign(root);
    const auto workspace_result = workspace_probe.observe(workspace_request);

    check(workspace_result.identity == 9 && workspace_result.present && workspace_result.branch.view() == "feature");
    check(workspace_result.dirty == true && !workspace_result.timed_out);
    check(!std::filesystem::exists(root + "/unexpected-execution"));
    std::string commit;

    std::ifstream{root + "/.git/refs/heads/feature"} >> commit;
    std::ofstream{root + "/.git/HEAD"} << commit << '\n';
    const auto detached = probe.observe(request);

    check(detached.present && detached.measured && detached.branch.view() == commit.substr(0, 8));
    check(detached.added == result.added && detached.ahead == result.ahead && detached.timeout == GitProbeTimeout::none);
    std::ofstream{root + "/.git/HEAD"} << "ref: refs/heads/" << std::string(201, 'x') << '\n';
    const auto invalid_branch = probe.observe(request);

    check(invalid_branch.present && invalid_branch.branch.view().empty() && !invalid_branch.measured);
    std::filesystem::remove_all(root);
    check(!probe.observe(request).present);
  }

  // A worktree another tool created registers with no base: the probe finds the main checkout's
  // branch and measures the distance from it, deletions included.
  void testLinkedWorktreeAgainstMain() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    std::array<char, 64> directory{};

    std::strcpy(directory.data(), "/tmp/telar-git-test.XXXXXX");
    check(::mkdtemp(directory.data()) != nullptr);
    const std::string root{directory.data()};
    const auto main = root + "/main";
    const auto linked = root + "/linked";

    std::filesystem::create_directory(main);
    runGit(memory, main, {"init", "--quiet", "--initial-branch=trunk", "--template="});
    std::ofstream{main + "/file.txt"} << "one\ntwo\nthree\nfour\n";
    runGit(memory, main, {"add", "file.txt"});
    runGit(memory, main, {"commit", "--quiet", "-m", "Initial fixture"});
    runGit(memory, main, {"worktree", "add", "--quiet", "-b", "feature", linked});

    // The feature deletes two committed lines and leaves one uncommitted change.
    std::ofstream{linked + "/file.txt"} << "one\nfour\n";
    runGit(memory, linked, {"commit", "--quiet", "-am", "Remove lines"});
    std::ofstream{linked + "/other.txt"} << "uncommitted\n";
    WorktreeGitProbe probe{memory};
    WorktreeProbeRequest request{};

    request.identity = 4;
    request.path.assign(linked);
    const auto result = probe.observe(request);

    check(result.present && result.branch.view() == "feature");
    check(result.base.view() == "trunk", "an external worktree has no base to measure against");
    check(result.measured && result.ahead == 1);
    check(result.removed == 2 && result.added == 0, "deleted lines are not counted");
    std::filesystem::remove_all(root);
  }

  const telar::testing::Case case_worktree_probe{"worktree_probe.worktree_probe", testWorktreeProbe};
  const telar::testing::Case case_linked_worktree_against_main{"worktree_probe.linked_worktree_against_main", testLinkedWorktreeAgainstMain};

}
