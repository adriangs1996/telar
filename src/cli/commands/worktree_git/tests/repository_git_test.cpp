#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <cstring>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.platform.process;
import telar.vocabulary;
import telar.testing;
import telar.testing.test_memory;
import telar.cli.commands.worktree_git;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli;

  class Directory {
  public:
    Directory() {
      std::strcpy(path_.dataMut(), "/tmp/telar-worktree-git.XXXXXX");
      check(::mkdtemp(path_.dataMut()) != nullptr);
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path_.data(), ignored);
    }

    std::string path(std::string_view name) const {
      return std::string{path_.data()} + "/" + std::string{name};
    }

  private:
    ds::Array<char, 64> path_{};
  };

  // Runs Git for a fixture, without the code under test, and returns its trimmed output.
  std::string git(std::string_view directory, std::initializer_list<std::string_view> arguments) {
    SystemAllocator system;
    std::vector<std::string_view> complete{"git", "-c", "user.name=Worktree Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "protocol.file.allow=always"};

    complete.insert(complete.end(), arguments);
    Command command{system, Launch{.cwd = directory, .arguments = complete}, CommandPurpose::administration};
    CommandOutput output{system, 4096};

    check(output.run(command, std::chrono::steady_clock::now() + std::chrono::seconds{10}) == 0);
    auto text = std::string{output.text()};

    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
      text.pop_back();
    }

    return text;
  }

  std::string repository(const Directory& directory, std::string_view name) {
    const auto root = directory.path(name);

    std::filesystem::create_directory(root);
    git(root, {"init", "--quiet", "--initial-branch=main", "--template="});
    std::ofstream{root + "/file.txt"} << "base\n";
    git(root, {"add", "file.txt"});
    git(root, {"commit", "--quiet", "-m", "Initial fixture"});
    return root;
  }

  std::string commit(std::string_view root, std::string_view file, std::string_view message) {
    std::ofstream{std::string{root} + "/" + std::string{file}} << message << "\n";
    git(root, {"add", "--", file});
    git(root, {"commit", "--quiet", "-m", message});
    return git(root, {"rev-parse", "HEAD"});
  }

  // What `ready` refuses with, or "ready".
  std::string readiness(std::string_view root) {
    telar::testing::TestMemory adapter;
    repository::Git repository{adapter, root};

    try {
      repository::ready(repository, "HEAD");
      return "ready";
    } catch (const std::runtime_error& error) {
      return error.what();
    }
  }

  // Another machine cannot rebuild a clone from a bundle of a shallow, partial, submodule or
  // LFS repository: each is refused before anything is sent.
  void readyRefusesIncompleteRepositories() {
    const Directory directory;
    const auto complete = repository(directory, "complete");

    check(readiness(complete) == "ready");

    const auto shallow = directory.path("shallow");

    commit(complete, "second.txt", "Second");
    git(directory.path(""), {"clone", "--quiet", "--depth", "1", "file://" + complete, shallow});
    check(readiness(shallow) == "ShallowRepositoryUnsupported");

    const auto partial = repository(directory, "partial");

    git(partial, {"config", "extensions.partialclone", "origin"});
    check(readiness(partial) == "PartialRepositoryUnsupported");

    const auto submodule = repository(directory, "submodule");
    const auto head = git(submodule, {"rev-parse", "HEAD"});

    git(submodule, {"update-index", "--add", "--cacheinfo", "160000," + head + ",vendor/lib"});
    git(submodule, {"commit", "--quiet", "-m", "Gitlink"});
    check(readiness(submodule) == "SubmoduleRepositoryUnsupported");

    const auto lfs = repository(directory, "lfs");

    std::filesystem::create_directory(lfs + "/assets");
    std::ofstream{lfs + "/assets/.gitattributes"} << "*.bin filter=lfs diff=lfs merge=lfs -text\n";
    git(lfs, {"add", "assets/.gitattributes"});
    git(lfs, {"commit", "--quiet", "-m", "LFS attributes"});
    check(readiness(lfs) == "LfsRepositoryUnsupported");
  }

  // A branch counts as merged only when its upstream holds its tip, so `remove --delete-branch`
  // asks before dropping work that was never pushed.
  void mergedUsesUpstream() {
    const Directory directory;
    const auto root = repository(directory, "repository");

    git(root, {"branch", "published"});
    git(root, {"checkout", "--quiet", "-b", "feature"});
    commit(root, "feature.txt", "Feature work");
    git(root, {"checkout", "--quiet", "main"});
    git(root, {"merge", "--quiet", "--ff-only", "feature"});
    git(root, {"branch", "--quiet", "--set-upstream-to=published", "feature"});

    telar::testing::TestMemory adapter;
    sessions::WorktreeGit worktrees{adapter};

    check(!worktrees.merged({.root = root, .branch = "feature"}));
    git(root, {"branch", "--quiet", "--unset-upstream", "feature"});
    check(worktrees.merged({.root = root, .branch = "feature"}));
  }

  // A branch that already exists is checked out at its own tip, not reset to the base.
  void addReusesExistingBranch() {
    const Directory directory;
    const auto root = repository(directory, "repository");
    const auto base = git(root, {"rev-parse", "HEAD"});

    git(root, {"checkout", "--quiet", "-b", "feature"});
    const auto tip = commit(root, "feature.txt", "Feature work");

    git(root, {"checkout", "--quiet", "main"});
    telar::testing::TestMemory adapter;
    sessions::WorktreeGit worktrees{adapter};
    const auto checkout = directory.path("feature");

    worktrees.add(root, checkout, "feature", "main");
    check(git(checkout, {"rev-parse", "--abbrev-ref", "HEAD"}) == "feature");
    check(git(checkout, {"rev-parse", "HEAD"}) == tip && tip != base);
  }

  const telar::testing::Case case_ready_refuses_incomplete_repositories{"repository.ready_refuses_incomplete_repositories", readyRefusesIncompleteRepositories};
  const telar::testing::Case case_merged_uses_upstream{"worktree_git.merged_uses_upstream", mergedUsesUpstream};
  const telar::testing::Case case_add_reuses_existing_branch{"worktree_git.add_reuses_existing_branch", addReusesExistingBranch};

}
