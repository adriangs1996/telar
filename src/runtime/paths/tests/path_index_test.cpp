#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.paths.query_task;
import telar.runtime.transport.connection;
import telar.wire.editor;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Found {
    std::string path;
    PathKind kind;
    PathChange change = PathChange::none;

    bool operator==(const Found&) const = default;
  };

  struct Listing {
    std::vector<Found> paths;
    bool complete = false;
    bool truncated = false;
  };

  Listing listing(ConcurrentMemory& memory, PathIndex& index, std::string_view root, std::string_view query = {}, std::uint16_t limit = 50) {
    EncodedReply reply{memory};
    std::vector<Byte> scratch(256 * 1024);
    DecodeStorage storage{scratch};

    index.query(FindPaths{.request_id = 1, .root = root, .query = query, .limit = limit}, reply);
    const auto result = Codec::decode<PathResults>(reply.payload(), storage);
    Listing found{.complete = result.complete, .truncated = result.truncated};

    for (const auto& match : result.matches) {
      found.paths.push_back({.path = std::string{match.path}, .kind = match.kind, .change = match.change});
    }

    return found;
  }

  // What a listing says git holds of a path; none when it does not list it.
  ds::Option<PathChange> changeOf(const Listing& found, std::string_view path) {
    const auto entry = std::ranges::find(found.paths, path, &Found::path);

    return entry == found.paths.end() ? ds::Option<PathChange>{} : ds::Option<PathChange>{entry->change};
  }

  bool lists(const Listing& found, std::string_view path) {
    return std::ranges::any_of(found.paths, [&](const Found& entry) {
      return entry.path == path;
    });
  }

  void write(const std::string& path) {
    std::filesystem::create_directories(std::filesystem::path{path}.parent_path());
    std::ofstream{path} << "fixture";
  }

  void testGitIndexRespectsIgnore() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory repository{"/tmp/telar-paths-XXXXXX"};
    const std::string root{repository.path()};

    write(root + "/src/tracked.txt");
    write(root + "/src/untracked.txt");
    write(root + "/src/ignored.txt");
    std::ofstream{root + "/.gitignore"} << "ignored.txt\n";
    const auto line = "cd " + root + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q && git add .gitignore src/tracked.txt >/dev/null 2>&1";

    check(std::system(line.c_str()) == 0);
    PathIndex index{memory};
    const auto found = listing(memory, index, root);
    const auto directories = std::ranges::count(found.paths, Found{"src/", PathKind::directory});

    check(found.complete && lists(found, "src/tracked.txt"));
    check(lists(found, "src/untracked.txt"), "an untracked file is missing");
    check(!lists(found, "src/ignored.txt"), "an ignored file is listed");
    check(directories == 1 && !lists(found, "src"), "a parent directory is not listed once, as a directory");
  }

  // Each path says what git holds of it, against the repository's head and its index, from a
  // root below the repository's top as well; a committed one says nothing.
  void testGitChangesOfPaths() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory repository{"/tmp/telar-paths-XXXXXX"};
    const std::string root{repository.path()};

    write(root + "/src/committed.txt");
    write(root + "/src/modified.txt");
    write(root + "/src/removed.txt");
    write(root + "/other.txt");
    const auto commit = "cd " + root + " && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && git init -q && git add . && git -c user.name=t -c user.email=t@t commit -qm first";

    check(std::system(commit.c_str()) == 0);
    std::ofstream{root + "/src/modified.txt"} << "changed";
    std::filesystem::remove(root + "/src/removed.txt");
    write(root + "/src/staged.txt");
    write(root + "/src/untracked.txt");
    write(root + "/other-untracked.txt");
    const auto stage = "cd " + root + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git add src/staged.txt";

    check(std::system(stage.c_str()) == 0);
    PathIndex index{memory};
    const auto top = listing(memory, index, root);

    check(top.complete);
    check(changeOf(top, "src/committed.txt") == PathChange::none, "a committed file");
    check(changeOf(top, "src/modified.txt") == PathChange::modified, "a modified file");
    check(changeOf(top, "src/removed.txt") == PathChange::deleted, "a file removed from the work tree");
    check(changeOf(top, "src/staged.txt") == PathChange::added, "a file added to the index");
    check(changeOf(top, "src/untracked.txt") == PathChange::untracked, "an untracked file");

    // Below the top, git's paths are made the root's.
    PathIndex below{memory};
    const auto inner = listing(memory, below, root + "/src");

    check(inner.complete && changeOf(inner, "modified.txt") == PathChange::modified && changeOf(inner, "untracked.txt") == PathChange::untracked);
    check(changeOf(inner, "committed.txt") == PathChange::none && !lists(inner, "other-untracked.txt"));
  }

  // What git says of a path, by the two letters its short status gives it.
  void testPathChangeLetters() {
    check(pathChange('?', '?') == PathChange::untracked && pathChange(' ', 'M') == PathChange::modified && pathChange('M', ' ') == PathChange::modified);
    check(pathChange('A', ' ') == PathChange::added && pathChange('A', 'M') == PathChange::added && pathChange(' ', 'D') == PathChange::deleted);
    check(pathChange('U', 'U') == PathChange::conflicted && pathChange('A', 'A') == PathChange::conflicted && pathChange('D', 'D') == PathChange::conflicted);
    check(pathChange(' ', 'T') == PathChange::modified && pathChange(' ', ' ') == PathChange::none);
  }

  void testUnreadableRoot() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-paths-XXXXXX"};
    const std::string locked = std::string{directory.path()} + "/locked";
    std::vector<std::string> roots{std::string{directory.path()} + "/missing"};

    check(::mkdir(locked.c_str(), 0000) == 0);
    if (::geteuid() != 0) {
      roots.push_back(locked);
    }

    // A typo'd root fails visibly instead of answering a complete, empty list.
    for (const auto& root : roots) {
      PathIndex index{memory};
      PathQueryTask<ConcurrentMemory> task{memory, index};
      OwnedPathQuery request;
      std::vector<Byte> scratch(4096);
      DecodeStorage storage{scratch};

      request.assign(FindPaths{.request_id = 9, .root = root, .limit = 10});
      index.reset(root);
      index.build();
      const auto result = task.observe(request);

      check(result.complete && result.payload.front() == static_cast<Byte>(ServerTag::request_failed), root);
      const auto failure = Codec::decode<RequestFailed>(result.payload, storage);

      check(failure.request_id == 9 && failure.code == FailureCode::permission_denied, root);
    }

    ::chmod(locked.c_str(), 0700);
  }

  void testSkipsHeavyDirectories() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-paths-XXXXXX"};
    const std::string root{directory.path()};

    write(root + "/node_modules/a/b");
    write(root + "/src/x");
    PathIndex index{memory};
    const auto found = listing(memory, index, root);

    check(found.complete && lists(found, "src/x"));
    check(std::ranges::none_of(found.paths, [](const Found& entry) {
      return entry.path.starts_with("node_modules/");
    }),
        "a dependency tree was indexed");
  }

  void testRankingContract() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-paths-XXXXXX"};
    const std::string root{directory.path()};

    // Many weak matches the walk finds before the exact one, which sits deepest.
    for (int index = 0; index < 40; ++index) {
      write(std::format("{}/a{:02}/m-a-i-n-{:02}.c-p-p", root, index, index));
    }

    write(root + "/zz/deep/main.cpp");
    PathIndex index{memory};
    const auto all = listing(memory, index, root, "main.cpp");

    check(all.complete && !all.paths.empty() && all.paths.front().path == "zz/deep/main.cpp", "the exact match is not first");

    // A smaller limit keeps the best of the whole index, not the first matches found.
    for (const std::uint16_t limit : {1, 3, 10}) {
      const auto best = listing(memory, index, root, "main.cpp", limit);

      check(best.paths.size() == std::min<std::size_t>(limit, all.paths.size()));
      check(std::ranges::equal(best.paths, all.paths | std::views::take(limit)), "a limited query is not the head of the full one");
    }
  }

  void testSymlinksNotFollowed() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-paths-XXXXXX"};
    TemporaryDirectory outside{"/tmp/telar-paths-XXXXXX"};
    const std::string root = std::string{directory.path()} + "/root";

    write(root + "/inside.txt");
    write(std::string{outside.path()} + "/secret/outside.txt");
    check(::symlink(outside.path().data(), (root + "/outside").c_str()) == 0);
    check(::symlink("..", (root + "/parent").c_str()) == 0);
    PathIndex index{memory};
    const auto found = listing(memory, index, root);

    check(found.complete && !found.truncated, "the index looped through a link");
    check(lists(found, "inside.txt"));
    check(std::ranges::none_of(found.paths, [](const Found& entry) {
      // The link itself may be listed; what lies beneath its target may not.
      return (entry.path.starts_with("outside/") && entry.path != "outside/") || (entry.path.starts_with("parent/") && entry.path != "parent/");
    }),
        "a link's target was indexed");
  }

  const telar::testing::Case case_git_index_respects_ignore{"path_index.git_index_respects_ignore", testGitIndexRespectsIgnore};
  const telar::testing::Case case_git_changes_of_paths{"path_index.git_changes_of_paths", testGitChangesOfPaths};
  const telar::testing::Case case_path_change_letters{"path_index.path_change_letters", testPathChangeLetters};
  const telar::testing::Case case_unreadable_root{"path_index.unreadable_root", testUnreadableRoot};
  const telar::testing::Case case_skips_heavy_directories{"path_index.skips_heavy_directories", testSkipsHeavyDirectories};
  const telar::testing::Case case_ranking_contract{"path_index.ranking_contract", testRankingContract};
  const telar::testing::Case case_symlinks_not_followed{"path_index.symlinks_not_followed", testSymlinksNotFollowed};

}
