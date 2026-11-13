// Builds real repositories with the git CLI and compares what telar.git reads
// with `git status --porcelain=v2 --branch`. Only the tests run git.
//
//   telar-git-tests                  run the tests
//   telar-git-tests --time DIRECTORY time repeated reads of DIRECTORY

#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <openssl/sha.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <zlib.h>

import std;
import telar.git;

namespace {

namespace git = telar::git;
using Reader = git::StatusReader<telar::SystemAllocator>;

int failures = 0;
int checks = 0;
std::string root;
telar::SystemAllocator system_memory;

void check(bool condition, std::string_view what, std::source_location location = std::source_location::current()) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL line %u: %.*s\n", location.line(), static_cast<int>(what.size()), what.data());
  }
}

std::string quote(std::string_view text) {
  std::string quoted = "'";
  for (const auto character : text) {
    if (character == '\'') {
      quoted += "'\\''";
    } else {
      quoted += character;
    }
  }
  return quoted + "'";
}

// Runs a shell command and returns its standard output; a failure fails the test.
std::string shell(const std::string &command, bool must_succeed = true) {
  std::string output;
  FILE *pipe = ::popen((command + " 2>/dev/null").c_str(), "r");
  if (pipe == nullptr) {
    check(false, command);
    return output;
  }
  std::array<char, 4096> buffer;
  while (const auto count = std::fread(buffer.data(), 1, buffer.size(), pipe)) {
    output.append(buffer.data(), count);
  }
  const auto status = ::pclose(pipe);
  if (must_succeed && status != 0) {
    check(false, "command failed: " + command);
  }
  return output;
}

std::string run(const std::string &directory, const std::string &arguments, bool must_succeed = true) {
  return shell("cd " + quote(directory) + " && " + arguments, must_succeed);
}

std::string trimmed(std::string text) {
  while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) {
    text.pop_back();
  }
  return text;
}

void write(const std::string &path, std::string_view contents) {
  FILE *file = std::fopen(path.c_str(), "wb");
  check(file != nullptr, "open " + path);
  if (file != nullptr) {
    std::fwrite(contents.data(), 1, contents.size(), file);
    std::fclose(file);
  }
}

std::string slurp(const std::string &path) {
  std::string contents;
  FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) {
    return contents;
  }
  std::array<char, 4096> buffer;
  while (const auto count = std::fread(buffer.data(), 1, buffer.size(), file)) {
    contents.append(buffer.data(), count);
  }
  std::fclose(file);
  return contents;
}

// Files dated in the past, so an index written now holds no racy entries.
void backdate(const std::string &directory) {
  run(directory, "find . -path ./.git -prune -o -type f -exec touch -h -t 202001010000 {} +");
}

std::string fresh(const std::string &name) {
  const auto directory = root + "/" + name;
  shell("rm -rf " + quote(directory) + " && mkdir -p " + quote(directory));
  return directory;
}

std::string hex(const git::ObjectId &id) {
  std::array<char, 64> buffer;
  return std::string{id.hex(buffer)};
}

struct Expected {
  std::string oid;
  std::string head;
  std::string upstream;
  bool has_ab = false;
  std::uint32_t ahead = 0;
  std::uint32_t behind = 0;
  git::ChangeCounts changes;
};

Expected porcelain(const std::string &directory) {
  Expected expected;
  const auto output = run(directory, "git status --porcelain=v2 --branch --untracked-files=no --no-renames");
  std::string_view rest{output};
  while (!rest.empty()) {
    const auto end = rest.find('\n');
    const auto line = rest.substr(0, end);
    rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
    if (line.starts_with("# branch.oid ")) {
      expected.oid = line.substr(13);
    } else if (line.starts_with("# branch.head ")) {
      expected.head = line.substr(14);
    } else if (line.starts_with("# branch.upstream ")) {
      expected.upstream = line.substr(18);
    } else if (line.starts_with("# branch.ab ")) {
      expected.has_ab = true;
      const auto values = line.substr(12);
      const auto space = values.find(' ');
      std::from_chars(values.data() + 1, values.data() + space, expected.ahead);
      std::from_chars(values.data() + space + 2, values.data() + values.size(), expected.behind);
    } else if (line.starts_with("1 ") || line.starts_with("2 ")) {
      const auto staged = line[2];
      const auto unstaged = line[3];
      auto &counts = expected.changes;
      counts.staged_added += staged == 'A';
      counts.staged_modified += staged == 'M' || staged == 'T';
      counts.staged_deleted += staged == 'D';
      counts.unstaged_modified += unstaged == 'M' || unstaged == 'T';
      counts.unstaged_deleted += unstaged == 'D';
      counts.intent_to_add += unstaged == 'A';
    } else if (line.starts_with("u ")) {
      ++expected.changes.conflicted;
    }
  }
  return expected;
}

std::string describe(const git::ChangeCounts &counts) {
  return std::format("staged +{} ~{} -{} unstaged ~{} -{} ita {} conflicts {}", counts.staged_added, counts.staged_modified, counts.staged_deleted,
                     counts.unstaged_modified, counts.unstaged_deleted, counts.intent_to_add, counts.conflicted);
}

bool sameCounts(const git::ChangeCounts &left, const git::ChangeCounts &right) {
  return left.staged_added == right.staged_added && left.staged_modified == right.staged_modified && left.staged_deleted == right.staged_deleted &&
         left.unstaged_modified == right.unstaged_modified && left.unstaged_deleted == right.unstaged_deleted && left.intent_to_add == right.intent_to_add &&
         left.conflicted == right.conflicted;
}

// Reads `directory` and checks every field git status reports.
void agrees(Reader &reader, const std::string &directory, std::string_view label, std::source_location location = std::source_location::current()) {
  const auto &status = reader.read(directory);
  const auto expected = porcelain(directory);
  const auto prefix = std::format("[{} @{}] ", label, location.line());
  check(status.repository == git::RepositoryState::ready, prefix + "repository ready");
  if (expected.head == "(detached)") {
    check(status.head == git::HeadState::detached, prefix + "detached");
  } else if (expected.oid == "(initial)") {
    check(status.head == git::HeadState::unborn && std::string_view{status.branch} == expected.head, prefix + "unborn " + expected.head);
  } else {
    check(status.head == git::HeadState::branch && std::string_view{status.branch} == expected.head, prefix + "branch " + expected.head + " got " + std::string{std::string_view{status.branch}});
  }
  if (expected.oid != "(initial)") {
    check(hex(status.head_id) == expected.oid, prefix + "head id " + expected.oid + " got " + hex(status.head_id));
  }
  if (expected.upstream.empty()) {
    check(status.upstream == git::UpstreamState::none, prefix + "no upstream");
  } else {
    check(std::string_view{status.upstream_name} == expected.upstream, prefix + "upstream " + expected.upstream + " got " + std::string{std::string_view{status.upstream_name}});
    check(status.upstream == (expected.has_ab ? git::UpstreamState::tracking : git::UpstreamState::gone), prefix + "upstream state");
  }
  if (expected.has_ab) {
    check(status.divergence == git::Accuracy::exact && status.ahead == expected.ahead && status.behind == expected.behind,
          prefix + std::format("ahead/behind +{} -{} got +{} -{} ({})", expected.ahead, expected.behind, status.ahead, status.behind, static_cast<int>(status.divergence)));
  }
  check(status.staged == git::Accuracy::exact && status.unstaged == git::Accuracy::exact, prefix + "changes exact");
  check(sameCounts(status.changes, expected.changes), prefix + "expected " + describe(expected.changes) + " got " + describe(status.changes));
}

void configure(const std::string &directory) {
  run(directory, "git config user.name Test && git config user.email test@example.com && git config commit.gpgsign false");
}

std::string initialize(const std::string &name, std::string_view options = "") {
  const auto directory = fresh(name);
  run(directory, "git init -q -b main " + std::string{options} + " .");
  configure(directory);
  return directory;
}

void commitAll(const std::string &directory, std::string_view message) {
  run(directory, "git add -A && git commit -q -m " + quote(message));
}

std::string longMessage(int variant) {
  std::string message = std::format("change {}\n\n", variant);
  for (int line = 0; line < 120; ++line) {
    message += std::format("Shared paragraph line {} that makes commits similar enough to deltify.\n", line);
  }
  return message;
}

// Counts the entries of each type in a packfile, walking it entry by entry.
std::array<int, 8> packEntryKinds(const std::string &path) {
  std::array<int, 8> kinds{};
  const auto pack = slurp(path);
  if (pack.size() < 32) {
    return kinds;
  }
  const auto *bytes = reinterpret_cast<const unsigned char *>(pack.data());
  const std::uint32_t count = bytes[8] << 24 | bytes[9] << 16 | bytes[10] << 8 | bytes[11];
  std::size_t position = 12;
  std::vector<unsigned char> sink(1 << 16);
  for (std::uint32_t entry = 0; entry < count && position < pack.size(); ++entry) {
    auto byte = bytes[position++];
    const auto kind = (byte >> 4) & 7;
    while ((byte & 0x80) != 0) {
      byte = bytes[position++];
    }
    if (kind == 6) {
      do {
        byte = bytes[position++];
      } while ((byte & 0x80) != 0);
    } else if (kind == 7) {
      position += 20;
    }
    ++kinds[kind];
    z_stream stream{};
    inflateInit(&stream);
    stream.next_in = const_cast<Bytef *>(bytes + position);
    stream.avail_in = static_cast<uInt>(pack.size() - position);
    int result = Z_OK;
    while (result == Z_OK) {
      stream.next_out = sink.data();
      stream.avail_out = static_cast<uInt>(sink.size());
      result = inflate(&stream, Z_NO_FLUSH);
    }
    position += stream.total_in;
    inflateEnd(&stream);
  }
  return kinds;
}

void testPlainBranch(Reader &reader) {
  const auto directory = initialize("plain");
  write(directory + "/a.txt", "alpha\n");
  shell("mkdir -p " + quote(directory + "/dir/sub"));
  write(directory + "/dir/b.txt", "beta\n");
  write(directory + "/dir/sub/c.txt", "gamma\n");
  backdate(directory);
  commitAll(directory, "first");
  agrees(reader, directory, "clean");
  check(!reader.changed(), "unchanged after read");

  // Repeated reads reuse every cache: no object, no hashing.
  const auto &again = reader.read(directory + "/dir/sub");
  check(again.work.objects_read == 0 && again.work.files_hashed == 0 && again.work.commits_read == 0, "cached read does no work");

  write(directory + "/a.txt", "alpha changed\n");
  run(directory, "rm dir/b.txt");
  write(directory + "/new.txt", "new\n");
  write(directory + "/dir/sub/c.txt", "gamma staged\n");
  run(directory, "git add new.txt dir/sub/c.txt");
  write(directory + "/dir/sub/c.txt", "gamma staged then edited\n");
  agrees(reader, directory, "mixed changes");

  commitAll(directory, "second");
  check(reader.changed(), "changed after commit");
  write(directory + "/intent.txt", "intent\n");
  run(directory, "git add -N intent.txt && chmod +x a.txt && ln -s a.txt link && git add link && git commit -q -m link");
  run(directory, "rm link && echo plain > link");
  run(directory, "git rm -q --cached dir/sub/c.txt");
  agrees(reader, directory, "mode, type, intent-to-add, removed from index");
}

void testDetachedAndPackedRefs(Reader &reader) {
  const auto directory = initialize("detached");
  for (int index = 0; index < 3; ++index) {
    write(directory + "/file.txt", std::format("version {}\n", index));
    commitAll(directory, std::format("commit {}", index));
  }
  run(directory, "git checkout -q --detach HEAD~1");
  agrees(reader, directory, "detached");
  check(reader.status().branch.empty(), "detached has no branch");

  run(directory, "git checkout -q main && git branch feature && git pack-refs --all");
  check(!shell("test -e " + quote(directory + "/.git/refs/heads/main") + " && echo loose", false).contains("loose"), "main is packed");
  agrees(reader, directory, "packed main");
  run(directory, "git checkout -q feature");
  agrees(reader, directory, "packed feature");

  // Branches: packed ones and loose ones, nested names included.
  run(directory, "git branch fix/nested/deep && git branch zeta");
  reader.read(directory);
  std::set<std::string> names;
  reader.branches(100, [&](std::string_view name) { names.emplace(name); });
  check(names == std::set<std::string>{"main", "feature", "fix/nested/deep", "zeta"}, "lists packed and loose branches");
  std::size_t limited = 0;
  reader.branches(2, [&](std::string_view) { ++limited; });
  check(limited == 2, "stops at the limit");
}

void testUnborn(Reader &reader) {
  const auto directory = initialize("unborn");
  write(directory + "/first.txt", "first\n");
  run(directory, "git add first.txt");
  agrees(reader, directory, "unborn with a staged file");
}

void testUpstream(Reader &reader) {
  const auto origin = fresh("origin.git");
  run(origin, "git init -q --bare -b main .");
  const auto work = root + "/work";
  const auto other = root + "/other";
  shell("rm -rf " + quote(work) + " " + quote(other));
  const auto seed = initialize("seed");
  write(seed + "/base.txt", "base\n");
  commitAll(seed, "base");
  run(seed, "git remote add origin " + quote(origin) + " && git push -q origin main");
  shell("git clone -q " + quote(origin) + " " + quote(work) + " && git clone -q " + quote(origin) + " " + quote(other));
  configure(work);
  configure(other);
  for (int index = 0; index < 4; ++index) {
    write(work + "/work.txt", longMessage(index));
    run(work, "git add -A && git commit -q -F - <<'EOF'\n" + longMessage(index) + "EOF");
  }
  for (int index = 0; index < 3; ++index) {
    write(other + "/other.txt", std::format("other {}\n", index));
    run(other, "git add -A && git commit -q -F - <<'EOF'\n" + longMessage(100 + index) + "EOF");
  }
  run(other, "git push -q origin main");
  run(work, "git fetch -q origin");
  agrees(reader, work, "loose objects");

  run(work, "git gc -q");
  check(shell("ls " + quote(work + "/.git/objects/info")).contains("commit-graph"), "gc wrote a commit-graph");
  agrees(reader, work, "packed with commit-graph");
  {
    Reader graph_reader{system_memory};
    check(graph_reader.read(work).work.commits_read == 0, "the walk reads no commit object when the graph has them all");
  }

  // A merge gives the graph a commit with two parents.
  run(work, "git merge -q --no-edit origin/main && git gc -q");
  agrees(reader, work, "merged");
  write(work + "/after.txt", "after\n");
  commitAll(work, "after merge, not in the graph");
  agrees(reader, work, "commit newer than the graph");
  {
    Reader graph_reader{system_memory};
    check(graph_reader.read(work).work.commits_read == 1, "only the commit outside the graph is read");
  }

  run(work, "rm -f .git/objects/info/commit-graph && git repack -q -a -d -f --depth=50 --window=250");
  const auto deltas = run(work, "git verify-pack -v .git/objects/pack/*.idx | awk '$2 == \"commit\" && NF == 7' | wc -l");
  check(std::stoi(trimmed(deltas)) > 0, "some commits are deltified");
  check(packEntryKinds(work + "/" + trimmed(run(work, "ls .git/objects/pack/*.pack")))[6] > 0, "the pack holds OFS_DELTA entries");
  agrees(reader, work, "OFS_DELTA commits without a graph");

  run(work, "git -c repack.useDeltaBaseOffset=false repack -q -a -d -f --depth=50 --window=250");
  check(packEntryKinds(work + "/" + trimmed(run(work, "ls .git/objects/pack/*.pack")))[7] > 0, "the pack holds REF_DELTA entries");
  agrees(reader, work, "REF_DELTA commits without a graph");

  run(work, "git commit-graph write --reachable --split");
  check(shell("ls " + quote(work + "/.git/objects/info/commit-graphs")).contains("commit-graph-chain"), "split graph chain written");
  agrees(reader, work, "split commit-graph");
  write(work + "/more.txt", "more\n");
  commitAll(work, "more");
  run(work, "git commit-graph write --reachable --split=no-merge");
  agrees(reader, work, "two graph layers");

  run(work, "git branch -q --set-upstream-to=origin/main main && git update-ref -d refs/remotes/origin/main");
  agrees(reader, work, "upstream gone");

  // A custom fetch refspec maps the upstream to another tracking namespace.
  run(work, "git config remote.origin.fetch '+refs/heads/*:refs/remotes/mirror/*' && git fetch -q origin");
  agrees(reader, work, "custom refspec");

  // Walk budget: a tiny limit reports unknown instead of a wrong count.
  Reader small{system_memory, git::Limits{.walk_commits = 2}};
  const auto &limited = small.read(work);
  check(limited.divergence == git::Accuracy::unknown, "walk limit reports unknown");
}

void testWorktree(Reader &reader) {
  const auto directory = initialize("main-tree");
  write(directory + "/shared.txt", "shared\n");
  commitAll(directory, "shared");
  const auto linked = root + "/linked";
  shell("rm -rf " + quote(linked));
  run(directory, "git worktree add -q -b topic " + quote(linked));
  write(linked + "/shared.txt", "edited in the worktree\n");
  agrees(reader, linked, "linked worktree");
  check(reader.status().linked_worktree, "linked worktree detected");
  run(directory, "git pack-refs --all");
  agrees(reader, linked, "linked worktree with packed refs");
  agrees(reader, directory, "main worktree");
  check(!reader.status().linked_worktree, "main worktree is not linked");
}

// Rewrites the first index entry's stat data to match the file now, then
// fixes the index checksum, so that only content tells the file changed.
void forgeStatData(const std::string &directory, const std::string &file) {
  auto index = slurp(directory + "/.git/index");
  struct stat status{};
  ::lstat((directory + "/" + file).c_str(), &status);
  auto put = [&](std::size_t offset, std::uint32_t value) {
    index[offset] = static_cast<char>(value >> 24);
    index[offset + 1] = static_cast<char>(value >> 16);
    index[offset + 2] = static_cast<char>(value >> 8);
    index[offset + 3] = static_cast<char>(value);
  };
  const std::size_t entry = 12;
#if defined(__APPLE__)
  const auto changed = status.st_ctimespec;
  const auto modified = status.st_mtimespec;
#else
  const auto changed = status.st_ctim;
  const auto modified = status.st_mtim;
#endif
  put(entry, static_cast<std::uint32_t>(changed.tv_sec));
  put(entry + 4, static_cast<std::uint32_t>(changed.tv_nsec));
  put(entry + 8, static_cast<std::uint32_t>(modified.tv_sec));
  put(entry + 12, static_cast<std::uint32_t>(modified.tv_nsec));
  put(entry + 20, static_cast<std::uint32_t>(status.st_ino));
  put(entry + 36, static_cast<std::uint32_t>(status.st_size));
  std::array<unsigned char, SHA_DIGEST_LENGTH> digest;
  SHA1(reinterpret_cast<const unsigned char *>(index.data()), index.size() - digest.size(), digest.data());
  std::memcpy(index.data() + index.size() - digest.size(), digest.data(), digest.size());
  write(directory + "/.git/index", index);
}

void testRacyEntries(Reader &reader) {
  const auto directory = initialize("racy");
  write(directory + "/a.txt", "1111\n");
  commitAll(directory, "racy");
  write(directory + "/a.txt", "2222\n");
  run(directory, "touch -t 202001010000 a.txt");
  forgeStatData(directory, "a.txt");

  // The index is older than the file: stat data cannot be trusted, content decides.
  run(directory, "touch -t 201901010000 .git/index");
  const auto &racy = reader.read(directory);
  check(racy.unstaged == git::Accuracy::exact && racy.changes.unstaged_modified == 1 && racy.work.files_hashed == 1, "racy entry hashed and found modified");
  agrees(reader, directory, "racy, as git sees it");

  // An index newer than the file trusts matching stat data, as git does.
  run(directory, "touch .git/index");
  const auto &trusted = reader.read(directory);
  check(trusted.changes.unstaged_modified == 0 && trusted.work.files_hashed == 0, "stat data trusted when not racy");

  // Racily clean files hash to their blob and stay clean.
  const auto clean = initialize("racy-clean");
  write(clean + "/a.txt", "same\n");
  commitAll(clean, "clean");
  run(clean, "touch -t 202001010000 .git/index");
  const auto &verified = reader.read(clean);
  check(verified.changes.unstaged_modified == 0 && verified.work.files_hashed == 1, "racily clean file is clean");
}

void testSymlinkedDirectory(Reader &reader) {
  const auto directory = initialize("symlinked");
  shell("mkdir -p " + quote(directory + "/dir"));
  write(directory + "/dir/one.txt", "one\n");
  write(directory + "/dir/two.txt", "two\n");
  commitAll(directory, "dir");
  const auto outside = fresh("outside");
  write(outside + "/one.txt", "one\n");
  write(outside + "/two.txt", "two\n");
  run(directory, "rm -rf dir && ln -s " + quote(outside) + " dir");
  agrees(reader, directory, "directory replaced by a symlink");
  check(reader.status().changes.unstaged_deleted == 2, "files behind a symlink are deleted");
}

void testSha256(Reader &reader) {
  const auto directory = fresh("sha256");
  if (!shell("cd " + quote(directory) + " && git init -q -b main --object-format=sha256 . && echo ok", false).contains("ok")) {
    std::fprintf(stderr, "skip: git cannot create SHA-256 repositories\n");
    return;
  }
  configure(directory);
  write(directory + "/a.txt", "alpha\n");
  commitAll(directory, "sha256");
  write(directory + "/a.txt", "alpha changed\n");
  write(directory + "/b.txt", "beta\n");
  run(directory, "git add b.txt");
  agrees(reader, directory, "sha256");
  check(reader.status().format == git::ObjectFormat::sha256, "sha256 format");
  run(directory, "git gc -q");
  agrees(reader, directory, "sha256 packed");
}

void testHostile(Reader &reader) {
  const auto directory = initialize("hostile");
  write(directory + "/a.txt", "alpha\n");
  write(directory + "/b.txt", "beta\n");
  commitAll(directory, "base");
  const auto index = slurp(directory + "/.git/index");

  write(directory + "/.git/index", index.substr(0, index.size() / 2));
  const auto &truncated = reader.read(directory);
  check(truncated.repository == git::RepositoryState::ready && truncated.staged == git::Accuracy::unknown && truncated.unstaged == git::Accuracy::unknown,
        "truncated index is unknown");

  auto corrupt = index;
  corrupt[20] = static_cast<char>(corrupt[20] ^ 0x55);
  write(directory + "/.git/index", corrupt);
  check(reader.read(directory).unstaged == git::Accuracy::unknown, "index with a bad checksum is unknown");

  auto forged = index;
  forged[7] = 9; // version 9
  write(directory + "/.git/index", forged);
  check(reader.read(directory).unstaged == git::Accuracy::unsupported, "unknown index version is unsupported");
  write(directory + "/.git/index", index);
  agrees(reader, directory, "restored index");

  // Split index: a required extension this reader does not implement.
  run(directory, "git update-index --split-index");
  check(reader.read(directory).unstaged == git::Accuracy::unsupported, "split index unsupported");
  run(directory, "git update-index --no-split-index");
  agrees(reader, directory, "split index removed");

  // Bogus pack offsets: point every object in the index past the pack.
  run(directory, "git gc -q && rm -f .git/objects/info/commit-graph");
  const auto idx_path = trimmed(run(directory, "ls .git/objects/pack/*.idx"));
  const auto pack_index = slurp(directory + "/" + idx_path);
  auto bogus = pack_index;
  const auto count = static_cast<std::size_t>(static_cast<unsigned char>(bogus[8 + 255 * 4]) << 24 | static_cast<unsigned char>(bogus[8 + 255 * 4 + 1]) << 16 |
                                              static_cast<unsigned char>(bogus[8 + 255 * 4 + 2]) << 8 | static_cast<unsigned char>(bogus[8 + 255 * 4 + 3]));
  const auto offsets = 8 + 1024 + count * 24;
  for (std::size_t index_entry = 0; index_entry < count; ++index_entry) {
    bogus[offsets + 4 * index_entry] = 0x7f;
  }
  ::chmod((directory + "/" + idx_path).c_str(), 0644);
  write(directory + "/" + idx_path, bogus);
  write(directory + "/a.txt", "touched so the staged comparison reads HEAD\n");
  run(directory, "git -c core.fsmonitor=false update-index --refresh", false);
  const auto &offset = reader.read(directory);
  check(offset.repository == git::RepositoryState::ready && offset.head == git::HeadState::branch, "bogus offsets keep the branch");
  // Fresh reader so no cached comparison hides the broken pack.
  Reader fresh_reader{system_memory};
  const auto &broken = fresh_reader.read(directory);
  check(broken.staged == git::Accuracy::unknown, "bogus pack offset makes the staged comparison unknown");
  write(directory + "/" + idx_path, pack_index);

  // Bogus delta chain: a pack whose entries are all truncated.
  const auto pack_path = idx_path.substr(0, idx_path.size() - 4) + ".pack";
  const auto pack = slurp(directory + "/" + pack_path);
  ::chmod((directory + "/" + pack_path).c_str(), 0644);
  write(directory + "/" + pack_path, pack.substr(0, 40) + std::string(pack.size() - 40, '\xff'));
  Reader garbage_reader{system_memory};
  check(garbage_reader.read(directory).staged == git::Accuracy::unknown, "garbage pack data is unknown");
  write(directory + "/" + pack_path, pack);

  const auto head = slurp(directory + "/.git/HEAD");
  write(directory + "/.git/HEAD", "ref: refs/heads/" + std::string(5000, 'x') + "\n");
  check(reader.read(directory).repository != git::RepositoryState::ready || reader.status().head == git::HeadState::unknown, "oversized HEAD is not trusted");

  write(directory + "/.git/HEAD", "ref: refs/heads/../../config\n");
  const auto &traversal = reader.read(directory);
  check(traversal.head == git::HeadState::unknown, "ref name escaping refs/ is refused");

  run(directory, "mkfifo .git/refs/heads/fifo");
  write(directory + "/.git/HEAD", "ref: refs/heads/fifo\n");
  const auto &fifo = reader.read(directory);
  check(fifo.head == git::HeadState::unknown, "a FIFO ref is refused without blocking");
  run(directory, "rm .git/refs/heads/fifo");
  write(directory + "/.git/HEAD", head);

  const auto config = slurp(directory + "/.git/config");
  write(directory + "/.git/config", config + "[core\n");
  check(reader.read(directory).repository == git::RepositoryState::invalid, "malformed config is invalid");
  write(directory + "/.git/config", config + "# " + std::string(2 << 20, 'x') + "\n");
  check(reader.read(directory).repository == git::RepositoryState::invalid, "oversized config is refused");
  write(directory + "/.git/config", "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tfuturething = true\n");
  check(reader.read(directory).repository == git::RepositoryState::unsupported, "unknown extension is unsupported");
  write(directory + "/.git/config", "[core]\n\trepositoryformatversion = 0\n[extensions]\n\tfuturething = true\n[include]\n\tpath = /nonexistent\n[core]\n\tfsmonitor = touch /tmp/pwned\n");
  check(reader.read(directory).repository == git::RepositoryState::ready, "version 0 ignores extensions, include and fsmonitor");
  write(directory + "/.git/config", config);
  agrees(reader, directory, "restored");

  const auto gitfile = fresh("gitfile");
  write(gitfile + "/.git", "not a gitdir line\n");
  check(reader.read(gitfile).repository == git::RepositoryState::invalid, "malformed .git file is invalid");
  write(gitfile + "/.git", "gitdir: ../does-not-exist\n");
  check(reader.read(gitfile).repository == git::RepositoryState::invalid, "dangling gitdir is invalid");
  if (::geteuid() != 0) {
    // /usr belongs to root: a gitdir owned by someone else is refused before it is read.
    write(gitfile + "/.git", "gitdir: /usr\n");
    const auto state = reader.read(gitfile).repository;
    check(state == git::RepositoryState::not_owned || state == git::RepositoryState::invalid, "foreign gitdir refused");
  }

  const auto plain = fresh("not-a-repository");
  check(reader.read(plain).repository == git::RepositoryState::none, "no repository");
  check(reader.read(root + "/missing-directory").repository == git::RepositoryState::none, "missing directory");
  check(reader.read("relative/path").repository == git::RepositoryState::unknown, "relative path refused");

  const auto reftable = fresh("reftable");
  if (shell("cd " + quote(reftable) + " && git init -q --ref-format=reftable . && echo ok", false).contains("ok")) {
    check(reader.read(reftable).repository == git::RepositoryState::unsupported, "reftable unsupported");
  }
}

void testConflict(Reader &reader) {
  const auto directory = initialize("conflict");
  write(directory + "/a.txt", "base\n");
  commitAll(directory, "base");
  run(directory, "git checkout -q -b side");
  write(directory + "/a.txt", "side\n");
  commitAll(directory, "side");
  run(directory, "git checkout -q main");
  write(directory + "/a.txt", "main\n");
  commitAll(directory, "main");
  run(directory, "git merge -q side", false);
  agrees(reader, directory, "conflict");
  check(reader.status().changes.conflicted == 1, "one conflict");
}

void testSubmoduleAndBare(Reader &reader) {
  const auto library = initialize("library");
  write(library + "/lib.txt", "lib\n");
  commitAll(library, "library");
  const auto parent = initialize("parent");
  write(parent + "/top.txt", "top\n");
  commitAll(parent, "top");
  run(parent, "git -c protocol.file.allow=always submodule --quiet add " + quote(library) + " sub && git commit -q -m submodule");
  // The submodule's .git is a file with a relative gitdir, and its config names core.worktree.
  check(slurp(parent + "/sub/.git").starts_with("gitdir: ../"), "submodule uses a relative gitdir");
  write(parent + "/sub/lib.txt", "edited inside the submodule\n");
  agrees(reader, parent + "/sub", "submodule");
  check(std::string_view{reader.status().branch} == "main", "submodule branch");

  const auto bare = root + "/bare.git";
  shell("rm -rf " + quote(bare) + " && git clone -q --bare " + quote(library) + " " + quote(bare));
  const auto &status = reader.read(bare);
  check(status.repository == git::RepositoryState::ready && status.bare && status.head == git::HeadState::branch && status.unstaged == git::Accuracy::not_applicable,
        "bare repository");
  const auto &inside = reader.read(parent + "/.git/refs");
  check(inside.repository == git::RepositoryState::ready && inside.bare, "inside a git directory");
}

void testLocalUpstream(Reader &reader) {
  const auto directory = initialize("local-upstream");
  write(directory + "/a.txt", "a\n");
  commitAll(directory, "a");
  run(directory, "git checkout -q -b feature && git branch -q --set-upstream-to=main feature");
  write(directory + "/b.txt", "b\n");
  commitAll(directory, "b");
  agrees(reader, directory, "upstream is a local branch");
}

// Flips bytes in each file the reader parses and reads again: whatever the
// result, it must not crash, hang or read out of bounds (run under ASan).
void testCorruption() {
  const auto directory = initialize("fuzz");
  for (int index = 0; index < 6; ++index) {
    shell("mkdir -p " + quote(directory + std::format("/d{}", index % 3)));
    write(directory + std::format("/d{}/f{}.txt", index % 3, index), longMessage(index));
    commitAll(directory, longMessage(index));
  }
  run(directory, "git branch topic HEAD~3 && git config branch.main.remote . && git config branch.main.merge refs/heads/topic");
  run(directory, "git gc -q && git update-index --index-version 4");
  const auto files = {std::string{".git/index"}, trimmed(run(directory, "ls .git/objects/pack/*.idx")), trimmed(run(directory, "ls .git/objects/pack/*.pack")),
                      std::string{".git/objects/info/commit-graph"}, std::string{".git/packed-refs"}, std::string{".git/config"}, std::string{".git/HEAD"}};
  std::mt19937 random{1234};
  int reads = 0;
  for (const auto &name : files) {
    const auto path = directory + "/" + name;
    const auto original = slurp(path);
    if (original.empty()) {
      continue;
    }
    ::chmod(path.c_str(), 0644);
    for (int round = 0; round < 40; ++round) {
      auto damaged = original;
      const auto flips = 1 + random() % 8;
      for (unsigned flip = 0; flip < flips; ++flip) {
        damaged[random() % damaged.size()] = static_cast<char>(random());
      }
      if (round % 5 == 0) {
        damaged.resize(random() % damaged.size());
      }
      write(path, damaged);
      Reader fresh_reader{system_memory};
      const auto &status = fresh_reader.read(directory);
      reads += status.repository != git::RepositoryState::none;
    }
    write(path, original);
  }
  check(reads > 0, "corrupted repositories were read");
  Reader final_reader{system_memory};
  agrees(final_reader, directory, "after corruption rounds");
}

// A long history built with fast-import: two branches of hundreds of commits
// from a common base, some with skewed committer dates.
void testLongHistory(Reader &reader) {
  const auto directory = initialize("long-history");
  std::string stream;
  int mark = 0;
  auto commit = [&](std::string_view branch, int from, std::int64_t time, int value) {
    ++mark;
    stream += std::format("commit refs/heads/{}\nmark :{}\ncommitter Test <test@example.com> {} +0000\ndata 8\ncommit {}\n", branch, mark, time, value % 10);
    if (from != 0) {
      stream += std::format("from :{}\n", from);
    }
    const auto content = std::format("{}\n", value);
    stream += std::format("M 644 inline file.txt\ndata {}\n{}\n", content.size(), content);
    return mark;
  };
  auto previous = commit("main", 0, 1600000000, 0);
  int fork = 0;
  for (int index = 1; index <= 700; ++index) {
    previous = commit("main", previous, 1600000000 + index * 60, index);
    if (index == 300) {
      fork = previous;
    }
  }
  previous = fork;
  for (int index = 0; index < 450; ++index) {
    // Every 50th commit claims to be a day older than its parent.
    const auto skew = index % 50 == 25 ? -86400 : 0;
    previous = commit("side", previous, 1600100000 + index * 60 + skew, 10000 + index);
  }
  write(root + "/stream", stream);
  run(directory, "git fast-import --quiet < " + quote(root + "/stream") + " && git checkout -q -f main");
  run(directory, "git config branch.main.remote . && git config branch.main.merge refs/heads/side");
  agrees(reader, directory, "long history from loose objects");
  run(directory, "git gc -q");
  agrees(reader, directory, "long history with a commit-graph");
  run(directory, "rm -f .git/objects/info/commit-graph");
  agrees(reader, directory, "long history from packs, by date");
}

void testIndexVersions(Reader &reader) {
  for (const auto version : {2, 3, 4}) {
    const auto directory = initialize(std::format("index-v{}", version));
    shell("mkdir -p " + quote(directory + "/deep/er/path"));
    for (int index = 0; index < 20; ++index) {
      write(directory + std::format("/deep/er/path/file-{:02}.txt", index), std::format("{}\n", index));
    }
    write(directory + "/top.txt", "top\n");
    commitAll(directory, "files");
    run(directory, std::format("git update-index --index-version {}", version));
    write(directory + "/deep/er/path/file-07.txt", "changed\n");
    run(directory, "rm deep/er/path/file-13.txt");
    agrees(reader, directory, std::format("index v{}", version));
  }
}

int timeReads(const char *directory) {
  telar::SystemAllocator memory;
  Reader reader{memory};
  timeval start{};
  timeval end{};
  ::gettimeofday(&start, nullptr);
  const auto &first = reader.read(directory);
  ::gettimeofday(&end, nullptr);
  const auto first_us = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_usec - start.tv_usec);
  std::printf("first read: %ld us, repository %d head %d branch %s ahead %u behind %u (%d) staged %d unstaged %d\n", static_cast<long>(first_us),
              static_cast<int>(first.repository), static_cast<int>(first.head), first.branch.c_str(), first.ahead, first.behind, static_cast<int>(first.divergence),
              static_cast<int>(first.staged), static_cast<int>(first.unstaged));
  std::printf("  %s\n", describe(first.changes).c_str());
  std::printf("  work: objects %llu commits %llu trees %llu entries %llu hashed %llu files, %llu bytes\n", static_cast<unsigned long long>(first.work.objects_read),
              static_cast<unsigned long long>(first.work.commits_read), static_cast<unsigned long long>(first.work.trees_read),
              static_cast<unsigned long long>(first.work.entries_checked), static_cast<unsigned long long>(first.work.files_hashed),
              static_cast<unsigned long long>(first.work.bytes_hashed));
  constexpr int rounds = 200;
  ::gettimeofday(&start, nullptr);
  for (int round = 0; round < rounds; ++round) {
    reader.read(directory);
  }
  ::gettimeofday(&end, nullptr);
  const auto total = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_usec - start.tv_usec);
  const auto &last = reader.status();
  std::printf("repeated read: %ld us average over %d; last read hashed %llu files, checked %llu entries, read %llu objects\n", static_cast<long>(total / rounds), rounds,
              static_cast<unsigned long long>(last.work.files_hashed), static_cast<unsigned long long>(last.work.entries_checked),
              static_cast<unsigned long long>(last.work.objects_read));
  ::gettimeofday(&start, nullptr);
  for (int round = 0; round < rounds; ++round) {
    (void)reader.changed();
  }
  ::gettimeofday(&end, nullptr);
  const auto probe = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_usec - start.tv_usec);
  std::printf("changed(): %.2f us average\n", static_cast<double>(probe) / rounds);
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc == 3 && std::string_view{argv[1]} == "--time") {
    return timeReads(argv[2]);
  }
  if (std::system("git --version >/dev/null 2>&1") != 0) {
    std::fprintf(stderr, "skip: git is not installed\n");
    return 77;
  }
  const char *temporary = std::getenv("TMPDIR");
  auto base = std::string{temporary != nullptr && *temporary != '\0' ? temporary : "/tmp"};
  base += "/telar-git-XXXXXX";
  std::vector<char> name(base.begin(), base.end());
  name.push_back('\0');
  if (::mkdtemp(name.data()) == nullptr) {
    std::fprintf(stderr, "cannot create a temporary directory\n");
    return 1;
  }
  root = name.data();
  // An isolated git: no user or system config, no hooks, no index rewrites by git status.
  ::setenv("HOME", root.c_str(), 1);
  ::setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
  ::setenv("GIT_OPTIONAL_LOCKS", "0", 1);
  ::setenv("GIT_TERMINAL_PROMPT", "0", 1);
  ::setenv("LC_ALL", "C", 1);
  for (const auto *variable : {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_CEILING_DIRECTORIES"}) {
    ::unsetenv(variable);
  }
  write(root + "/.gitconfig", "[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n");

  Reader reader{system_memory};
  testPlainBranch(reader);
  testDetachedAndPackedRefs(reader);
  testUnborn(reader);
  testUpstream(reader);
  testWorktree(reader);
  testRacyEntries(reader);
  testSymlinkedDirectory(reader);
  testSha256(reader);
  testConflict(reader);
  testIndexVersions(reader);
  testSubmoduleAndBare(reader);
  testLocalUpstream(reader);
  testLongHistory(reader);
  testCorruption();
  testHostile(reader);

  shell("rm -rf " + quote(root));
  if (failures != 0) {
    std::fprintf(stderr, "%d of %d checks failed\n", failures, checks);
    return 1;
  }
  std::printf("all %d telar.git checks passed\n", checks);
  return 0;
}
