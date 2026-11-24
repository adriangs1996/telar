#include <cstdlib>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.files.repository;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Change {
    std::string path;
    FileState staged = FileState::unchanged;
    FileState unstaged = FileState::unchanged;
    std::uint32_t added = 0;
    std::uint32_t removed = 0;

    bool operator==(const Change&) const = default;
  };

  void write(const std::string& path, std::string_view text) {
    std::ofstream{path} << text;
  }

  bool run(const std::string& root, std::string_view command) {
    const auto line = "cd " + root + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=telar -c user.email=telar@example.invalid -c commit.gpgsign=false " + std::string{command} + " >/dev/null 2>&1";

    return std::system(line.c_str()) == 0; // NOLINT(concurrency-mt-unsafe,cert-env33-c): a test prepares its repository with the host's git
  }

  void testStatusRecordsAreRead() {
    using namespace std::string_view_literals;

    const auto ordinary = StatusRecord::parse("1 .M N... 100644 100644 100644 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234567 docs/a b.md"sv);
    const auto staged = StatusRecord::parse("1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 0123456789abcdef0123456789abcdef01234567 new.txt"sv);
    const auto unmerged = StatusRecord::parse("u UU N... 100644 100644 100644 100644 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234567 0123456789abcdef0123456789abcdef01234567 both.txt"sv);
    const auto untracked = StatusRecord::parse("? notes/"sv);
    const auto ignored = StatusRecord::parse("! out/"sv);

    check(ordinary && ordinary->path == "docs/a b.md" && ordinary->staged == FileState::unchanged && ordinary->unstaged == FileState::modified, "a path with a space, changed in the working tree");
    check(staged && staged->path == "new.txt" && staged->staged == FileState::added && staged->unstaged == FileState::unchanged);
    check(unmerged && unmerged->path == "both.txt" && unmerged->staged == FileState::conflicted && unmerged->unstaged == FileState::conflicted);
    check(untracked && untracked->path == "notes/" && untracked->unstaged == FileState::untracked);
    check(ignored && ignored->path == "out/" && ignored->unstaged == FileState::ignored);
    check(!StatusRecord::parse("# branch.head main"sv) && !StatusRecord::parse(""sv) && !StatusRecord::parse("1 .M"sv), "a header and a cut record name no path");
  }

  void testARepositorySaysWhatChanged() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) { // NOLINT(concurrency-mt-unsafe,cert-env33-c): a test asks the host whether it has git
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-repository-XXXXXX"};
    const std::string root{directory.path()};

    std::filesystem::create_directories(root + "/docs");
    write(root + "/docs/usage.md", "one\ntwo\nthree\n");
    write(root + "/kept.txt", "kept\n");
    write(root + "/.gitignore", "out/\n");
    check(run(root, "init -q -b trunk") && run(root, "add .") && run(root, "commit -q -m first"));

    write(root + "/docs/usage.md", "one\n2\nthree\nfour\n");
    write(root + "/staged.txt", "a\nb\n");
    check(run(root, "add staged.txt"));
    std::filesystem::create_directories(root + "/notes");
    write(root + "/notes/todo", "x\n");
    std::filesystem::create_directories(root + "/out");
    write(root + "/out/built", "x\n");

    const std::atomic<bool> cancelled{false};
    RepositoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(512 * 1024);
    DecodeStorage storage{scratch};

    reader.changes(QueryChanges{.request_id = 11, .path = root + "/docs"}, cancelled, reply);

    const auto changes = Codec::decode<RepositoryChanges>(reply.payload(), storage);
    std::vector<Change> listed;

    for (const auto& change : changes.changes) {
      listed.push_back({std::string{change.path}, change.staged, change.unstaged, change.added, change.removed});
    }

    std::ranges::sort(listed, {}, &Change::path);
    check(changes.request_id == 11 && std::filesystem::equivalent(std::string{changes.root}, root), "the repository's top, asked from a directory below it");
    check(changes.branch == "trunk" && changes.base.empty() && changes.ahead == 0 && !changes.truncated, "a repository with no remote names no base");
    check(listed == std::vector<Change>{
                        {"docs/usage.md", FileState::unchanged, FileState::modified, 2, 1},
                        {"notes/", FileState::unchanged, FileState::untracked, 0, 0},
                        {"out/", FileState::unchanged, FileState::ignored, 0, 0},
                        {"staged.txt", FileState::added, FileState::unchanged, 2, 0},
                    },
        "what the index holds, what the working tree changed with its lines, and what git does not track or ignores");

    TemporaryDirectory plain{"/tmp/telar-plain-XXXXXX"};

    reader.changes(QueryChanges{.request_id = 12, .path = plain.path()}, cancelled, reply);

    const auto outside = Codec::decode<RepositoryChanges>(reply.payload(), storage);

    check(outside.root.empty() && outside.changes.empty(), "outside a repository there is no root and nothing changed");
  }

  void testABranchIsMeasuredAgainstItsBase() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) { // NOLINT(concurrency-mt-unsafe,cert-env33-c): a test asks the host whether it has git
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-base-XXXXXX"};
    const std::string root{directory.path()};
    const std::atomic<bool> cancelled{false};
    RepositoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(64 * 1024);
    DecodeStorage storage{scratch};
    std::uint64_t request = 0;
    const auto measured = [&] {
      reader.changes(QueryChanges{.request_id = ++request, .path = root}, cancelled, reply);

      const auto changes = Codec::decode<RepositoryChanges>(reply.payload(), storage);

      return std::pair{std::string{changes.base}, changes.ahead};
    };

    write(root + "/kept.txt", "kept\n");
    check(run(root, "init -q -b trunk") && run(root, "add .") && run(root, "commit -q -m first"));
    // What a clone leaves: the remote's branch, and the head of the remote pointing at it.
    check(run(root, "update-ref refs/remotes/origin/trunk HEAD") && run(root, "symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk"));
    check(measured() == std::pair{std::string{"trunk"}, std::uint32_t{0}}, "on the base itself, with nothing it lacks");

    check(run(root, "checkout -q -b work") && run(root, "commit -q --allow-empty -m second") && run(root, "commit -q --allow-empty -m third"));
    check(measured() == std::pair{std::string{"trunk"}, std::uint32_t{2}}, "the head of the remote is the base, by its name without the remote, and the commits it lacks are counted");

    // The base moves without the commit changing: what was found for the commit stands a while.
    check(run(root, "update-ref refs/remotes/origin/trunk HEAD"));
    check(measured() == std::pair{std::string{"trunk"}, std::uint32_t{2}}, "git is not asked again for the same commit at once");

    // A remote that names no head: the branch this one follows is the base.
    check(run(root, "update-ref refs/remotes/origin/trunk trunk") && run(root, "symbolic-ref -d refs/remotes/origin/HEAD"));
    check(run(root, "config remote.origin.url /nowhere") && run(root, "config remote.origin.fetch +refs/heads/*:refs/remotes/origin/*"));
    check(run(root, "config branch.work.remote origin") && run(root, "config branch.work.merge refs/heads/trunk"));
    check(measured() == std::pair{std::string{"trunk"}, std::uint32_t{2}}, "with no head of the remote, the branch followed");
  }

  void testAFileIsInspected() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) { // NOLINT(concurrency-mt-unsafe,cert-env33-c): a test asks the host whether it has git
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-inspect-XXXXXX"};
    const std::string root{directory.path()};

    write(root + "/usage.md", "one\ntwo\nthree\n");
    check(run(root, "init -q -b trunk") && run(root, "add .") && run(root, "commit -q -m 'Describe the usage'"));
    write(root + "/usage.md", "one\n2\nthree\n");
    write(root + "/binary", std::string_view{"\x7f"
                                             "ELF\0\0\0",
                                7});
    write(root + "/long.txt", std::string(FileLimits::text_bytes + 100, 'x'));
    std::filesystem::create_symlink("usage.md", root + "/link");

    const std::atomic<bool> cancelled{false};
    RepositoryReader reader{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(512 * 1024);
    DecodeStorage storage{scratch};
    const auto inspect = [&](const std::string& path) {
      reader.inspect(InspectFile{.request_id = 13, .path = path}, cancelled, reply);
      return Codec::decode<FileInspection>(reply.payload(), storage);
    };

    const auto usage = inspect(root + "/usage.md");

    check(usage.kind == FileKind::file && usage.size == 12 && !usage.binary && !usage.truncated && usage.text == "one\n2\nthree\n", "a text file's head");
    check(usage.commit.size() == FileLimits::commit_bytes && usage.subject == "Describe the usage" && usage.committed_seconds != 0, "the last commit that changed it");
    check(usage.diff.starts_with("@@ -1,3 +1,3 @@") && usage.diff.contains("-two\n+2\n"), "and the hunks of what is not committed, without the header that names the file");

    const auto binary = inspect(root + "/binary");

    check(binary.binary && binary.text.empty() && binary.commit.empty() && binary.diff.empty(), "a binary file shows no text, and one git never saw no commit");

    const auto large = inspect(root + "/long.txt");

    check(!large.binary && large.truncated && large.text.size() <= FileLimits::text_bytes && large.text.size() >= FileLimits::text_bytes - 4, "a long file is cut to what a preview shows");

    const auto link = inspect(root + "/link");

    check(link.kind == FileKind::link && link.target == "usage.md" && link.text.empty(), "a link says where it points");

    bool refused = false;

    try {
      inspect(root + "/missing");
    } catch (const RequestError& error) {
      refused = error.code() == FailureCode::invalid_request;
    }

    check(refused, "a path that does not exist is refused");
  }

  const telar::testing::Case case_records{"repository.status_records_are_read", testStatusRecordsAreRead};
  const telar::testing::Case case_changes{"repository.a_repository_says_what_changed", testARepositorySaysWhatChanged};
  const telar::testing::Case case_base{"repository.a_branch_is_measured_against_its_base", testABranchIsMeasuredAgainstItsBase};
  const telar::testing::Case case_inspect{"repository.a_file_is_inspected", testAFileIsInspected};

}
