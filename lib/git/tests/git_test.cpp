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
import telar.base.memory.allocators;
import telar.testing;
import telar.base.ds;

namespace {

  namespace {

    namespace git = telar::git;
    using Reader = git::StatusReader;

    std::string root;
    telar::SystemAllocator system_allocator;
    telar::MemoryAdapter system_memory{system_allocator};

    void check(bool condition, std::string_view what, std::source_location location = std::source_location::current()) {
      telar::testing::expect(condition, what, location);
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
    std::string shell(const std::string& command, bool must_succeed = true) {
      std::string output;
      FILE* pipe = ::popen((command + " 2>/dev/null").c_str(), "r");
      if (pipe == nullptr) {
        check(false, command);
        return output;
      }

      telar::ds::Array<char, 4096> buffer;

      while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), pipe)) {
        output.append(buffer.data(), count);
      }

      const auto status = ::pclose(pipe);
      if (must_succeed && status != 0) {
        check(false, "command failed: " + command);
      }

      return output;
    }

    std::string run(const std::string& directory, const std::string& arguments, bool must_succeed = true) {
      return shell("cd " + quote(directory) + " && " + arguments, must_succeed);
    }

    std::string trimmed(std::string text) {
      while (!text.empty() && (text.back() == '\n' || text.back() == ' ')) {
        text.pop_back();
      }

      return text;
    }

    void write(const std::string& path, std::string_view contents) {
      FILE* file = std::fopen(path.c_str(), "wb");

      check(file != nullptr, "open " + path);
      if (file != nullptr) {
        std::fwrite(contents.data(), 1, contents.size(), file);
        std::fclose(file);
      }
    }

    std::string slurp(const std::string& path) {
      std::string contents;
      FILE* file = std::fopen(path.c_str(), "rb");
      if (file == nullptr) {
        return contents;
      }

      telar::ds::Array<char, 4096> buffer;

      while (const auto count = std::fread(buffer.dataMut(), 1, buffer.size(), file)) {
        contents.append(buffer.data(), count);
      }

      std::fclose(file);
      return contents;
    }

    // Files dated in the past, so an index written now holds no racy entries.
    void backdate(const std::string& directory) {
      run(directory, "find . -path ./.git -prune -o -type f -exec touch -h -t 202001010000 {} +");
    }

    std::string fresh(const std::string& name) {
      const auto directory = root + "/" + name;

      shell("rm -rf " + quote(directory) + " && mkdir -p " + quote(directory));
      return directory;
    }

    std::string hex(const git::ObjectId& id) {
      telar::ds::Array<char, 64> buffer;

      return std::string{id.hex(buffer.viewMut())};
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

    Expected porcelain(const std::string& directory) {
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
          auto& counts = expected.changes;

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

    std::string describe(const git::ChangeCounts& counts) {
      return std::format("staged +{} ~{} -{} unstaged ~{} -{} ita {} conflicts {}", counts.staged_added, counts.staged_modified, counts.staged_deleted, counts.unstaged_modified, counts.unstaged_deleted, counts.intent_to_add, counts.conflicted);
    }

    bool sameCounts(const git::ChangeCounts& left, const git::ChangeCounts& right) {
      return left.staged_added == right.staged_added && left.staged_modified == right.staged_modified && left.staged_deleted == right.staged_deleted &&
             left.unstaged_modified == right.unstaged_modified && left.unstaged_deleted == right.unstaged_deleted && left.intent_to_add == right.intent_to_add &&
             left.conflicted == right.conflicted;
    }

    // Reads `directory` and checks every field git status reports.
    void agrees(Reader& reader, const std::string& directory, std::string_view label, std::source_location location = std::source_location::current()) {
      const auto& status = reader.read(directory);
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
        check(status.divergence == git::Accuracy::exact && status.ahead == expected.ahead && status.behind == expected.behind, prefix + std::format("ahead/behind +{} -{} got +{} -{} ({})", expected.ahead, expected.behind, status.ahead, status.behind, static_cast<int>(status.divergence)));
      }

      check(status.staged == git::Accuracy::exact && status.unstaged == git::Accuracy::exact, prefix + "changes exact");
      check(sameCounts(status.changes, expected.changes), prefix + "expected " + describe(expected.changes) + " got " + describe(status.changes));
    }

    void configure(const std::string& directory) {
      run(directory, "git config user.name Test && git config user.email test@example.com && git config commit.gpgsign false");
    }

    std::string initialize(const std::string& name, std::string_view options = "") {
      const auto directory = fresh(name);

      run(directory, "git init -q -b main " + std::string{options} + " .");
      configure(directory);
      return directory;
    }

    void commitAll(const std::string& directory, std::string_view message) {
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
    telar::ds::Array<int, 8> packEntryKinds(const std::string& path) {
      telar::ds::Array<int, 8> kinds{};
      const auto pack = slurp(path);
      if (pack.size() < 32) {
        return kinds;
      }

      const auto* bytes = reinterpret_cast<const unsigned char*>(pack.data());
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

        ++kinds.atMut(kind);
        z_stream stream{};

        inflateInit(&stream);
        stream.next_in = const_cast<Bytef*>(bytes + position);
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

    void testPlainBranch(Reader& reader) {
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
      const auto& again = reader.read(directory + "/dir/sub");

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

    void testDetachedAndPackedRefs(Reader& reader) {
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

      reader.branches(100, [&](std::string_view name) {
        names.emplace(name);
      });

      check(names == std::set<std::string>{"main", "feature", "fix/nested/deep", "zeta"}, "lists packed and loose branches");
      std::size_t limited = 0;

      reader.branches(2, [&](std::string_view) {
        ++limited;
      });

      check(limited == 2, "stops at the limit");
    }

    // Remote-tracking branches and tags, loose and packed, read with the refs alone: listing
    // them never compares the working tree.
    void testRemoteBranchesAndTags(Reader& reader) {
      const auto directory = initialize("references");

      write(directory + "/file.txt", "one\n");
      commitAll(directory, "first");
      run(directory, "git update-ref refs/remotes/origin/main HEAD && git update-ref refs/remotes/origin/only-remote HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main");
      run(directory, "git tag v1 && git tag -a v2 -m two && git pack-refs --all && git tag v3 && git update-ref refs/remotes/upstream/loose HEAD");
      write(directory + "/file.txt", "dirty\n");

      const auto& status = reader.refs(directory);
      const auto list = [&](auto visit) {
        std::set<std::string> names;

        visit([&](std::string_view name) {
          names.emplace(name);
        });
        return names;
      };

      check(status.repository == telar::git::RepositoryState::ready, "the refs are read");
      check(status.changes.unstaged_modified == 0, "reading the refs compares no working tree");
      check(list([&](auto&& visit) {
        reader.remoteBranches(100, visit);
      }) == std::set<std::string>{"origin/main", "origin/only-remote", "upstream/loose"},
          "lists remote-tracking branches, packed and loose, without HEAD");
      check(list([&](auto&& visit) {
        reader.tags(100, visit);
      }) == std::set<std::string>{"v1", "v2", "v3"},
          "lists tags, packed and loose");
    }

    void testUnborn(Reader& reader) {
      const auto directory = initialize("unborn");

      write(directory + "/first.txt", "first\n");
      run(directory, "git add first.txt");
      agrees(reader, directory, "unborn with a staged file");
    }

    void testUpstream(Reader& reader) {
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
      const auto& limited = small.read(work);

      check(limited.divergence == git::Accuracy::unknown, "walk limit reports unknown");
    }

    void testWorktree(Reader& reader) {
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
    void forgeStatData(const std::string& directory, const std::string& file) {
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
      telar::ds::Array<unsigned char, SHA_DIGEST_LENGTH> digest;

      SHA1(reinterpret_cast<const unsigned char*>(index.data()), index.size() - digest.size(), digest.dataMut());
      std::memcpy(index.data() + index.size() - digest.size(), digest.data(), digest.size());
      write(directory + "/.git/index", index);
    }

    void testRacyEntries(Reader& reader) {
      const auto directory = initialize("racy");

      write(directory + "/a.txt", "1111\n");
      commitAll(directory, "racy");
      write(directory + "/a.txt", "2222\n");
      run(directory, "touch -t 202001010000 a.txt");
      forgeStatData(directory, "a.txt");

      // The index is older than the file: stat data cannot be trusted, content decides.
      run(directory, "touch -t 201901010000 .git/index");
      const auto& racy = reader.read(directory);

      check(racy.unstaged == git::Accuracy::exact && racy.changes.unstaged_modified == 1 && racy.work.files_hashed == 1, "racy entry hashed and found modified");
      agrees(reader, directory, "racy, as git sees it");

      // An index newer than the file trusts matching stat data, as git does.
      run(directory, "touch .git/index");
      const auto& trusted = reader.read(directory);

      check(trusted.changes.unstaged_modified == 0 && trusted.work.files_hashed == 0, "stat data trusted when not racy");

      // Racily clean files hash to their blob and stay clean.
      const auto clean = initialize("racy-clean");

      write(clean + "/a.txt", "same\n");
      commitAll(clean, "clean");
      run(clean, "touch -t 202001010000 .git/index");
      const auto& verified = reader.read(clean);

      check(verified.changes.unstaged_modified == 0 && verified.work.files_hashed == 1, "racily clean file is clean");
    }

    void testSymlinkedDirectory(Reader& reader) {
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

    void testSha256(Reader& reader) {
      const auto directory = fresh("sha256");
      if (!shell("cd " + quote(directory) + " && git init -q -b main --object-format=sha256 . && echo ok", false).contains("ok")) {
        telar::testing::skip("git cannot create SHA-256 repositories");
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

    void testHostile(Reader& reader) {
      const auto directory = initialize("hostile");

      write(directory + "/a.txt", "alpha\n");
      write(directory + "/b.txt", "beta\n");
      commitAll(directory, "base");
      const auto index = slurp(directory + "/.git/index");

      write(directory + "/.git/index", index.substr(0, index.size() / 2));
      const auto& truncated = reader.read(directory);

      check(truncated.repository == git::RepositoryState::ready && truncated.staged == git::Accuracy::unknown && truncated.unstaged == git::Accuracy::unknown, "truncated index is unknown");

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
      const auto count = static_cast<std::size_t>(static_cast<unsigned char>(bogus[8 + 255 * 4]) << 24 | static_cast<unsigned char>(bogus[8 + 255 * 4 + 1]) << 16 | static_cast<unsigned char>(bogus[8 + 255 * 4 + 2]) << 8 | static_cast<unsigned char>(bogus[8 + 255 * 4 + 3]));
      const auto offsets = 8 + 1024 + count * 24;

      for (std::size_t index_entry = 0; index_entry < count; ++index_entry) {
        bogus[offsets + 4 * index_entry] = 0x7f;
      }

      ::chmod((directory + "/" + idx_path).c_str(), 0644);
      write(directory + "/" + idx_path, bogus);
      write(directory + "/a.txt", "touched so the staged comparison reads HEAD\n");
      run(directory, "git -c core.fsmonitor=false update-index --refresh", false);
      const auto& offset = reader.read(directory);

      check(offset.repository == git::RepositoryState::ready && offset.head == git::HeadState::branch, "bogus offsets keep the branch");
      // Fresh reader so no cached comparison hides the broken pack.
      Reader fresh_reader{system_memory};
      const auto& broken = fresh_reader.read(directory);

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
      const auto& traversal = reader.read(directory);

      check(traversal.head == git::HeadState::unknown, "ref name escaping refs/ is refused");

      run(directory, "mkfifo .git/refs/heads/fifo");
      write(directory + "/.git/HEAD", "ref: refs/heads/fifo\n");
      const auto& fifo = reader.read(directory);

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

    std::string rawId(const std::string& hex_id) {
      std::string bytes;

      for (std::size_t index = 0; index + 1 < hex_id.size(); index += 2) {
        bytes += static_cast<char>(std::stoi(hex_id.substr(index, 2), nullptr, 16));
      }

      return bytes;
    }

    std::string sha1(std::string_view bytes) {
      telar::ds::Array<unsigned char, SHA_DIGEST_LENGTH> digest{};

      SHA1(reinterpret_cast<const unsigned char*>(bytes.data()), bytes.size(), digest.dataMut());
      return {reinterpret_cast<const char*>(digest.data()), digest.size()};
    }

    std::string hexBytes(std::string_view bytes) {
      std::string text;

      for (const auto byte : bytes) {
        text += std::format("{:02x}", static_cast<unsigned char>(byte));
      }

      return text;
    }

    // Writes `bytes` as a loose object of `kind` without git's checks of its contents.
    std::string literalObject(const std::string& directory, std::string_view kind, std::string_view bytes) {
      const auto path = directory + "/.git/literal";

      write(path, bytes);
      const auto id = trimmed(run(directory, "git hash-object -t " + std::string{kind} + " --literally -w " + quote(path)));

      run(directory, "rm -f " + quote(path));
      return id;
    }

    // Points main at a new commit of `tree`, so the staged comparison reads that tree.
    void commitTree(const std::string& directory, const std::string& tree) {
      const auto commit = literalObject(directory, "commit", "tree " + tree + "\nauthor T <t@example.com> 0 +0000\ncommitter T <t@example.com> 0 +0000\n\nhostile\n");

      run(directory, "git update-ref refs/heads/main " + commit);
    }

    // A cloned repository can hold a tree that git itself would refuse: its entries are never a
    // path outside the tree, never out of order, with an unknown mode or with a short object id.
    // The staged comparison against such a HEAD is unknown, never a count.
    void testHostileTreeEntries(Reader&) {
      const auto directory = initialize("hostile-trees");

      write(directory + "/a.txt", "alpha\n");
      commitAll(directory, "base");
      const auto blob = rawId(trimmed(run(directory, "git rev-parse HEAD:a.txt")));
      const auto entry = [&](std::string_view mode, std::string_view name) {
        return std::string{mode} + " " + std::string{name} + '\0' + blob;
      };

      const auto valid = literalObject(directory, "tree", entry("100644", "a.txt") + entry("100644", "b.txt"));

      commitTree(directory, valid);
      Reader control{system_memory};

      check(control.read(directory).staged == git::Accuracy::exact, "a well-formed tree is compared");
      for (const auto& [label, tree] : std::initializer_list<std::pair<std::string_view, std::string>>{
               {"dot-dot entry", entry("100644", "..") + entry("100644", "a.txt")},
               {"dot entry", entry("100644", ".") + entry("100644", "a.txt")},
               {"slash in a name", entry("100644", "a.txt") + entry("100644", "a/b")},
               {"unsorted entries", entry("100644", "b.txt") + entry("100644", "a.txt")},
               {"unknown mode", entry("100600", "a.txt")},
               {"truncated object id", "100644 a.txt" + std::string(1, '\0') + blob.substr(0, 10)},
           }) {
        commitTree(directory, literalObject(directory, "tree", tree));
        Reader fresh_reader{system_memory};
        const auto& status = fresh_reader.read(directory);

        check(status.repository == git::RepositoryState::ready && status.staged == git::Accuracy::unknown, std::string{label} + " makes the staged comparison unknown");
      }
    }

    std::string deflated(std::string_view bytes) {
      auto length = compressBound(static_cast<uLong>(bytes.size()));
      std::string output(length, '\0');

      compress(reinterpret_cast<Bytef*>(output.data()), &length, reinterpret_cast<const Bytef*>(bytes.data()), static_cast<uLong>(bytes.size()));
      output.resize(length);
      return output;
    }

    // The type and size header of a pack entry.
    std::string entryHeader(unsigned kind, std::size_t size) {
      std::string header;
      auto byte = static_cast<unsigned char>((kind << 4) | (size & 0x0f));

      size >>= 4;
      while (size != 0) {
        header += static_cast<char>(byte | 0x80);
        byte = static_cast<unsigned char>(size & 0x7f);
        size >>= 7;
      }

      return header + static_cast<char>(byte);
    }

    std::string deltaSize(std::size_t size) {
      std::string bytes;

      do {
        auto byte = static_cast<unsigned char>(size & 0x7f);

        size >>= 7;
        bytes += static_cast<char>(size != 0 ? byte | 0x80 : byte);
      } while (size != 0);

      return bytes;
    }

    // Writes a pack of a tree `base` and an OFS or REF delta against it whose result claims the
    // id `target`, with its .idx, so the object database resolves `target` through `delta`. A
    // delta's result has its base's type, so the result is a tree too.
    void writeDeltaPack(const std::string& directory, std::string_view base, const std::string& target, std::string_view delta, bool reference) {
      const auto base_id = sha1("tree " + std::to_string(base.size()) + '\0' + std::string{base});
      std::string pack = "PACK";

      for (const std::uint32_t word : {2u, 2u}) {
        for (int shift = 24; shift >= 0; shift -= 8) {
          pack += static_cast<char>(word >> shift);
        }
      }

      const auto base_offset = pack.size();

      pack += entryHeader(2, base.size()) + deflated(base);
      const auto delta_offset = pack.size();

      if (reference) {
        pack += entryHeader(7, delta.size()) + base_id;
      } else {
        auto distance = delta_offset - base_offset;
        std::string encoded(1, static_cast<char>(distance & 0x7f));

        while ((distance >>= 7) != 0) {
          --distance;
          encoded.insert(encoded.begin(), static_cast<char>(0x80 | (distance & 0x7f)));
        }

        pack += entryHeader(6, delta.size()) + encoded;
      }

      pack += deflated(delta);
      const auto checksum = sha1(pack);

      pack += checksum;
      const auto entry_crc = [&](std::size_t begin, std::size_t end) {
        return static_cast<std::uint32_t>(crc32(0, reinterpret_cast<const Bytef*>(pack.data() + begin), static_cast<uInt>(end - begin)));
      };

      std::vector<std::tuple<std::string, std::uint32_t, std::uint32_t>> objects{
          {base_id, entry_crc(base_offset, delta_offset), static_cast<std::uint32_t>(base_offset)},
          {target, entry_crc(delta_offset, pack.size() - checksum.size()), static_cast<std::uint32_t>(delta_offset)},
      };

      std::ranges::sort(objects);
      std::string index = "\xfftOc";
      const auto word = [&](std::uint32_t value) {
        for (int shift = 24; shift >= 0; shift -= 8) {
          index += static_cast<char>(value >> shift);
        }
      };

      word(2);
      for (unsigned first = 0; first < 256; ++first) {
        word(static_cast<std::uint32_t>(std::ranges::count_if(objects, [&](const auto& object) {
          return static_cast<unsigned char>(std::get<0>(object)[0]) <= first;
        })));
      }

      for (const auto& object : objects) {
        index += std::get<0>(object);
      }

      for (const auto& object : objects) {
        word(std::get<1>(object));
      }

      for (const auto& object : objects) {
        word(std::get<2>(object));
      }

      index += checksum;
      index += sha1(index);
      const auto name = directory + "/.git/objects/pack/pack-" + hexBytes(checksum);

      shell("mkdir -p " + quote(directory + "/.git/objects/pack"));
      write(name + ".pack", pack);
      write(name + ".idx", index);
    }

    // A pack from a cloned repository can hold a delta whose zlib stream is valid but whose
    // instructions are not: a copy outside the base, an insert past the result, opcode 0 or
    // a source size other than the base's. Resolving it makes the staged comparison unknown and
    // never writes or reads outside either buffer.
    void testHostilePackDelta(Reader&) {
      for (const bool reference : {false, true}) {
        for (const auto& [label, delta, accepted] : std::initializer_list<std::tuple<std::string_view, std::string, bool>>{
                 {"a delta within both buffers", "copy", true},
                 {"a copy just past the base", "outside", false},
                 {"a copy far outside the base", "far", false},
                 {"an insert past the result", "insert", false},
                 {"opcode 0", "zero", false},
                 {"another source size", "source", false},
             }) {
          const auto directory = initialize(reference ? "hostile-delta-ref" : "hostile-delta-ofs");

          write(directory + "/a.txt", "alpha\n");
          commitAll(directory, "base");
          // The base and the tree a correct delta makes of it: a.txt with blobs other than the
          // committed one, so the comparison counts it. The delta copies the entry's mode and
          // name from the base and inserts the new id.
          const std::string prefix = "100644 a.txt" + std::string(1, '\0');
          const auto base = prefix + sha1("zero");
          const auto id = sha1("other");
          const auto tree = prefix + id;
          const auto tree_id = sha1("tree " + std::to_string(tree.size()) + '\0' + tree);
          const std::string copy = "\x90" + std::string(1, static_cast<char>(prefix.size()));
          const auto insert = std::string(1, static_cast<char>(id.size())) + id;
          std::string instructions;

          if (delta == "copy") {
            instructions = deltaSize(base.size()) + deltaSize(tree.size()) + copy + insert;
          } else if (delta == "outside") {
            instructions = deltaSize(base.size()) + deltaSize(tree.size()) + "\x91" + static_cast<char>(base.size() - 3) + static_cast<char>(prefix.size()) + insert;
          } else if (delta == "far") {
            instructions = deltaSize(base.size()) + deltaSize(tree.size()) + "\x9f" + std::string(3, '\0') + "\x40" + static_cast<char>(prefix.size()) + insert;
          } else if (delta == "insert") {
            instructions = deltaSize(base.size()) + deltaSize(prefix.size()) + copy + insert;
          } else if (delta == "zero") {
            instructions = deltaSize(base.size()) + deltaSize(tree.size()) + copy + std::string(1, '\0') + insert;
          } else {
            instructions = deltaSize(base.size() + 1) + deltaSize(tree.size()) + copy + insert;
          }

          writeDeltaPack(directory, base, tree_id, instructions, reference);
          commitTree(directory, hexBytes(tree_id));
          Reader fresh_reader{system_memory};
          const auto& status = fresh_reader.read(directory);
          const auto expected = accepted ? git::Accuracy::exact : git::Accuracy::unknown;

          check(status.repository == git::RepositoryState::ready && status.staged == expected, std::string{label} + (reference ? " (REF_DELTA)" : " (OFS_DELTA)"));
          if (accepted) {
            check(status.changes.staged_modified == 1, "the resolved tree is compared");
          }
        }
      }
    }

    // Changes the owner of `path` to a user other than the caller.
    void giveAway(const std::string& path, uid_t owner) {
      check(::lchown(path.c_str(), owner, static_cast<gid_t>(-1)) == 0, "chown " + path);
    }

    // A repository another user can write is never read: its config and objects are that user's
    // (the class of CVE-2022-24765). Without root, root's own "/" is the directory someone else
    // owns; as root, the test hands each directory of a repository to another user in turn.
    void testNotOwnedRepository(Reader& reader) {
      const auto not_owned = [&](const std::string& directory, std::string_view label) {
        Reader fresh_reader{system_memory};

        check(fresh_reader.read(directory).repository == git::RepositoryState::not_owned, std::string{label} + " is not owned");
      };

      if (::geteuid() != 0) {
        const auto gitdir = fresh("foreign-common-gitdir");
        const auto worktree = fresh("foreign-common-worktree");

        shell("mkdir -p " + quote(gitdir + "/objects") + " " + quote(gitdir + "/refs"));
        write(gitdir + "/HEAD", "ref: refs/heads/main\n");
        write(gitdir + "/commondir", "/\n");
        write(worktree + "/.git", "gitdir: " + gitdir + "\n");
        not_owned(worktree, "a common directory another user owns");

        const auto configured = initialize("foreign-configured-worktree");

        write(configured + "/a.txt", "alpha\n");
        commitAll(configured, "base");
        run(configured, "git config core.worktree /");
        not_owned(configured + "/.git", "a configured worktree another user owns");
        return;
      }

      constexpr uid_t other = 65534;
      const auto directory = initialize("foreign-owner");

      write(directory + "/a.txt", "alpha\n");
      commitAll(directory, "base");
      agrees(reader, directory, "owned repository");
      giveAway(directory, other);
      not_owned(directory, "a worktree another user owns");
      giveAway(directory, 0);
      giveAway(directory + "/.git", other);
      not_owned(directory, "a git directory another user owns");
      giveAway(directory + "/.git", 0);

      const auto gitdir = fresh("foreign-gitfile-target");
      const auto linked = fresh("foreign-gitfile");

      run(gitdir, "git init -q --bare .");
      write(linked + "/.git", "gitdir: " + gitdir + "\n");
      giveAway(linked + "/.git", other);
      not_owned(linked, "a .git file another user owns");
      giveAway(linked + "/.git", 0);
      giveAway(gitdir, other);
      not_owned(linked, "a gitdir another user owns");
    }

    void testConflict(Reader& reader) {
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

    void testSubmoduleAndBare(Reader& reader) {
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
      const auto& status = reader.read(bare);

      check(status.repository == git::RepositoryState::ready && status.bare && status.head == git::HeadState::branch && status.unstaged == git::Accuracy::not_applicable, "bare repository");
      const auto& inside = reader.read(parent + "/.git/refs");

      check(inside.repository == git::RepositoryState::ready && inside.bare, "inside a git directory");
    }

    void testLocalUpstream(Reader& reader) {
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
      const auto files = {std::string{".git/index"}, trimmed(run(directory, "ls .git/objects/pack/*.idx")), trimmed(run(directory, "ls .git/objects/pack/*.pack")), std::string{".git/objects/info/commit-graph"}, std::string{".git/packed-refs"}, std::string{".git/config"}, std::string{".git/HEAD"}};
      std::mt19937 random{1234};
      int reads = 0;

      for (const auto& name : files) {
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
          const auto& status = fresh_reader.read(directory);

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
    void testLongHistory(Reader& reader) {
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

    void testIndexVersions(Reader& reader) {
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

    // An origin with one commit on main, and a configured clone of it at root/<name>.
    std::string cloneWithOrigin(const std::string& name) {
      const auto origin = fresh(name + "-origin.git");

      run(origin, "git init -q --bare -b main .");
      const auto seed = initialize(name + "-seed");

      write(seed + "/base.txt", "base\n");
      commitAll(seed, "base");
      run(seed, "git remote add origin " + quote(origin) + " && git push -q origin main");
      const auto work = root + "/" + name;

      shell("rm -rf " + quote(work) + " && git clone -q " + quote(origin) + " " + quote(work));
      configure(work);
      return work;
    }

    // A tree over 64 KiB stored as a delta copies its base in runs of 0x10000 bytes, which the
    // delta writes with no size bytes; the staged comparison reads that tree.
    void testLargeTreeDelta(Reader& reader) {
      const auto directory = initialize("large-tree");

      run(directory, "mkdir big && cd big && i=0 && while [ $i -lt 2600 ]; do : > entry-with-a-name-long-enough-$i; i=$((i + 1)); done && : > zz-last");
      backdate(directory);
      commitAll(directory, "large tree");
      // The smaller tree deltifies against the larger one, so HEAD's tree is the delta.
      run(directory, "git rm -q big/zz-last && git commit -q -m smaller && git repack -q -a -d -f --window=50 --depth=50");
      const auto tree = trimmed(run(directory, "git rev-parse HEAD:big"));
      const auto fields = trimmed(run(directory, "git verify-pack -v .git/objects/pack/*.idx | awk '$1 == \"" + tree + "\" { print NF }'"));

      check(fields == "7", "HEAD:big is stored as a delta");
      check(std::stoul(trimmed(run(directory, "git cat-file -s " + tree))) > 2 * 0x10000, "the tree spans several 0x10000 copies");
      write(directory + "/big/entry-with-a-name-long-enough-7", "staged\n");
      run(directory, "git add big");
      agrees(reader, directory, "large tree delta");
    }

    // Config syntax git reads: a BOM, CRLF lines, quoted and concatenated values, escapes, inline
    // comments and the legacy [section.Subsection] form, which git lowercases.
    void testConfigSyntax(Reader& reader) {
      const auto work = cloneWithOrigin("config-syntax");
      const auto url = trimmed(run(work, "git config remote.origin.url"));
      const auto config = [&](std::string_view branches) {
        return "\xEF\xBB\xBF[core]\r\n\trepositoryformatversion = 0\r\n\tbare = false\r\n[user]\r\n\tname = \"Te\\tst \\\"q\\\"\" ; escapes\r\n[remote \"origin\"]\r\n\turl = " + url + "\r\n\tfetch = +refs/heads/*:refs/remotes/origin/*\r\n" + std::string{branches};
      };

      write(work + "/.git/config", config("[branch \"main\"]\r\n\tremote = origin ; an inline comment\r\n\tmerge = \"refs/heads/\"main # a quoted part\r\n"));
      check(trimmed(run(work, "git rev-parse --abbrev-ref '@{u}'")) == "origin/main", "git reads the quoted value");
      agrees(reader, work, "quoted value");

      write(work + "/.git/config", config("[branch.Main]\r\n\tremote = origin\r\n\tmerge = refs/heads/main\r\n"));
      check(trimmed(run(work, "git rev-parse --abbrev-ref '@{u}'")) == "origin/main", "git reads the legacy section");
      agrees(reader, work, "legacy subsection");

      write(work + "/.git/config", config("[branch.Main]\r\n\tremote = origin\r\n\tmerge = \"refs/heads/ma\\qin\"\r\n"));
      check(trimmed(run(work, "git status >/dev/null; echo $?")) != "0", "git refuses an unknown escape");
      check(reader.read(work).repository == git::RepositoryState::invalid, "an unknown escape is invalid");
    }

    // HEAD names its branch with a reference name the reader accepts exactly when
    // `git check-ref-format` does.
    void testReferenceNames(Reader& reader) {
      const auto directory = initialize("reference-names");

      write(directory + "/a.txt", "a\n");
      commitAll(directory, "a");
      const auto head = slurp(directory + "/.git/HEAD");

      for (const std::string_view name : {"a b", "a~1", "a^", "a:b", "a?", "a*", "a[", "a\\b", "a@{1}", "a\x01", "a\x7f", ".h", "x.lock", "a/", "a.", "feat/x", "a@b", "a.b", "@"}) {
        const auto reference = "refs/heads/" + std::string{name};
        const bool git_accepts = run(directory, "git check-ref-format " + quote(reference) + " && echo valid", false) == "valid\n";

        write(directory + "/.git/HEAD", "ref: " + reference + "\n");
        const auto state = reader.read(directory).head;

        check((state != git::HeadState::unknown) == git_accepts, "HEAD naming " + reference + (git_accepts ? " is valid for git" : " is invalid for git"));
      }

      write(directory + "/.git/HEAD", head);
      agrees(reader, directory, "restored HEAD");
    }

    // With extensions.worktreeConfig, config.worktree adds to the repository's config, as git
    // reads it; a malformed one makes the repository invalid, as it makes git fail.
    void testWorktreeConfigExtension(Reader& reader) {
      const auto work = cloneWithOrigin("worktree-config");

      run(work, "git config core.repositoryformatversion 1 && git config extensions.worktreeConfig true && git config --unset branch.main.remote && git config --unset branch.main.merge");
      write(work + "/.git/config.worktree", "[branch \"main\"]\n\tremote = origin\n\tmerge = refs/heads/main\n");
      check(trimmed(run(work, "git rev-parse --abbrev-ref '@{u}'")) == "origin/main", "git reads the upstream from config.worktree");
      agrees(reader, work, "upstream from config.worktree");

      write(work + "/.git/config.worktree", "[core]\n\tbare = true\n");
      check(reader.read(work).bare == (trimmed(run(work, "git rev-parse --is-bare-repository")) == "true"), "core.bare from config.worktree, as git reads it");

      write(work + "/.git/config.worktree", "[core\n");
      check(trimmed(run(work, "git rev-parse --git-dir >/dev/null; echo $?")) != "0", "git refuses a malformed config.worktree");
      check(reader.read(work).repository == git::RepositoryState::invalid, "a malformed config.worktree is invalid");
    }

    // A negative refspec that excludes the merge ref: the upstream is what git status reports.
    void testNegativeRefspec(Reader& reader) {
      const auto work = cloneWithOrigin("negative-refspec");

      run(work, "git config --add remote.origin.fetch '^refs/heads/main'");
      agrees(reader, work, "negative refspec");
    }

    // A shallow clone's walk stops at the shallow commits, whose parents are not there: ahead and
    // behind match git's, and an unreadable shallow file makes them unknown.
    void testShallowDivergence(Reader& reader) {
      const auto origin = initialize("shallow-origin");

      for (int index = 0; index < 5; ++index) {
        write(origin + "/file.txt", std::format("origin {}\n", index));
        commitAll(origin, std::format("origin {}", index));
      }

      const auto work = root + "/shallow";

      shell("rm -rf " + quote(work) + " && git clone -q --depth 3 " + quote("file://" + origin) + " " + quote(work));
      configure(work);
      check(slurp(work + "/.git/shallow").size() > 0, "the clone is shallow");
      for (int index = 0; index < 2; ++index) {
        write(work + "/local.txt", std::format("local {}\n", index));
        commitAll(work, std::format("local {}", index));
        write(origin + "/file.txt", std::format("origin more {}\n", index));
        commitAll(origin, std::format("origin more {}", index));
      }

      run(work, "git fetch -q origin");
      agrees(reader, work, "shallow clone");

      write(work + "/.git/shallow", slurp(work + "/.git/shallow") + "not an object id\n");
      Reader fresh_reader{system_memory};

      check(fresh_reader.read(work).divergence == git::Accuracy::unknown, "a corrupt shallow file makes divergence unknown");
    }

    // An octopus merge keeps its third and later parents in the commit-graph's EDGE chunk.
    void testOctopusCommitGraph(Reader& reader) {
      const auto work = cloneWithOrigin("octopus");

      for (const auto* branch : {"one", "two", "three"}) {
        run(work, std::format("git checkout -q -b {} main", branch));
        write(work + "/" + branch + ".txt", std::string{branch} + "\n");
        commitAll(work, branch);
      }

      run(work, "git checkout -q main && git merge -q --no-edit one two three");
      check(trimmed(run(work, "git rev-list --parents -n 1 HEAD | awk '{ print NF }'")) == "4", "the merge has three parents");
      run(work, "git gc -q && git commit-graph write --reachable");
      check(shell("ls " + quote(work + "/.git/objects/info")).contains("commit-graph"), "commit-graph written");
      agrees(reader, work, "octopus merge in the commit-graph");
    }

    void setTime(const std::string& path, std::time_t seconds) {
      const telar::ds::Array<timespec, 2> times{{{seconds, 0}, {seconds, 0}}};

      check(::utimensat(AT_FDCWD, path.c_str(), times.data(), AT_SYMLINK_NOFOLLOW) == 0, "set the time of " + path);
    }

    // A symlink whose stat data no longer matches its index entry is judged by the hash of its
    // target, as git does: the same target is clean, a retargeted link of the same length is
    // modified even when its time equals the index's.
    void testRacySymlink(Reader& reader) {
      const auto directory = initialize("racy-symlink");

      check(::symlink("target-a", (directory + "/link").c_str()) == 0, "symlink");
      commitAll(directory, "link");
      setTime(directory + "/link", 1'600'000'000);
      agrees(reader, directory, "link touched, target unchanged");

      ::unlink((directory + "/link").c_str());
      check(::symlink("target-b", (directory + "/link").c_str()) == 0, "retarget");
      setTime(directory + "/link", 1'700'000'000);
      setTime(directory + "/.git/index", 1'700'000'000);
      const auto& status = reader.read(directory);

      check(status.unstaged == git::Accuracy::exact && status.changes.unstaged_modified == 1, "the retargeted link is modified");
      agrees(reader, directory, "retargeted link");
    }

    int timeReads(const char* directory) {
      telar::SystemAllocator allocator;
      telar::MemoryAdapter memory{allocator};
      Reader reader{memory};
      timeval start{};
      timeval end{};

      ::gettimeofday(&start, nullptr);
      const auto& first = reader.read(directory);

      ::gettimeofday(&end, nullptr);
      const auto first_us = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_usec - start.tv_usec);

      std::printf("first read: %ld us, repository %d head %d branch %s ahead %u behind %u (%d) staged %d unstaged %d\n", static_cast<long>(first_us), static_cast<int>(first.repository), static_cast<int>(first.head), first.branch.data(), first.ahead, first.behind, static_cast<int>(first.divergence), static_cast<int>(first.staged), static_cast<int>(first.unstaged));
      std::printf("  %s\n", describe(first.changes).c_str());
      std::printf("  work: objects %llu commits %llu trees %llu entries %llu hashed %llu files, %llu bytes\n", static_cast<unsigned long long>(first.work.objects_read), static_cast<unsigned long long>(first.work.commits_read), static_cast<unsigned long long>(first.work.trees_read), static_cast<unsigned long long>(first.work.entries_checked), static_cast<unsigned long long>(first.work.files_hashed), static_cast<unsigned long long>(first.work.bytes_hashed));
      constexpr int rounds = 200;

      ::gettimeofday(&start, nullptr);
      for (int round = 0; round < rounds; ++round) {
        reader.read(directory);
      }

      ::gettimeofday(&end, nullptr);
      const auto total = (end.tv_sec - start.tv_sec) * 1000000 + (end.tv_usec - start.tv_usec);
      const auto& last = reader.status();

      std::printf("repeated read: %ld us average over %d; last read hashed %llu files, checked %llu entries, read %llu objects\n", static_cast<long>(total / rounds), rounds, static_cast<unsigned long long>(last.work.files_hashed), static_cast<unsigned long long>(last.work.entries_checked), static_cast<unsigned long long>(last.work.objects_read));
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

  // Each case reads repositories it creates with an isolated git: no user or system config, no
  // hooks, no index rewrites by git status, below a folder of its own.
  template <auto body>
  void withGit() {
    if (std::system("git --version >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    const char* temporary = std::getenv("TMPDIR");
    auto base = std::string{temporary != nullptr && *temporary != '\0' ? temporary : "/tmp"};

    base += "/telar-git-XXXXXX";
    std::vector<char> name(base.begin(), base.end());

    name.push_back('\0');
    check(::mkdtemp(name.data()) != nullptr, "temporary directory");
    root = name.data();
    ::setenv("HOME", root.c_str(), 1);
    ::setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
    ::setenv("GIT_OPTIONAL_LOCKS", "0", 1);
    ::setenv("GIT_TERMINAL_PROMPT", "0", 1);
    ::setenv("LC_ALL", "C", 1);
    for (const auto* variable : {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_CEILING_DIRECTORIES"}) {
      ::unsetenv(variable);
    }

    write(root + "/.gitconfig", "[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n");
    // A skipped or failed expectation still leaves no repository behind.
    try {
      body();
    } catch (...) {
      shell("rm -rf " + quote(root));
      throw;
    }

    shell("rm -rf " + quote(root));
  }

  template <auto body>
  void readsWithGit() {
    withGit<[] {
      Reader reader{system_memory};

      body(reader);
    }>();
  }

  const telar::testing::Mode time_reads{
      "--time",
      [](int argc, char** argv) {
        return argc == 3 ? timeReads(argv[2]) : 2;
      },
  };
  const telar::testing::Case case_plain_branch{"git.plain_branch", readsWithGit<testPlainBranch>};
  const telar::testing::Case case_detached_and_packed_refs{"git.detached_and_packed_refs", readsWithGit<testDetachedAndPackedRefs>};
  const telar::testing::Case case_remote_branches_and_tags{"git.remote_branches_and_tags", readsWithGit<testRemoteBranchesAndTags>};
  const telar::testing::Case case_unborn{"git.unborn", readsWithGit<testUnborn>};
  const telar::testing::Case case_upstream{"git.upstream", readsWithGit<testUpstream>};
  const telar::testing::Case case_worktree{"git.worktree", readsWithGit<testWorktree>};
  const telar::testing::Case case_racy_entries{"git.racy_entries", readsWithGit<testRacyEntries>};
  const telar::testing::Case case_symlinked_directory{"git.symlinked_directory", readsWithGit<testSymlinkedDirectory>};
  const telar::testing::Case case_sha256{"git.sha256", readsWithGit<testSha256>};
  const telar::testing::Case case_conflict{"git.conflict", readsWithGit<testConflict>};
  const telar::testing::Case case_index_versions{"git.index_versions", readsWithGit<testIndexVersions>};
  const telar::testing::Case case_submodule_and_bare{"git.submodule_and_bare", readsWithGit<testSubmoduleAndBare>};
  const telar::testing::Case case_local_upstream{"git.local_upstream", readsWithGit<testLocalUpstream>};
  const telar::testing::Case case_long_history{"git.long_history", readsWithGit<testLongHistory>};
  const telar::testing::Case case_corruption{"git.corruption", withGit<testCorruption>};
  const telar::testing::Case case_hostile{"git.hostile", readsWithGit<testHostile>};
  const telar::testing::Case case_hostile_tree_entries{"git.hostile_tree_entries", readsWithGit<testHostileTreeEntries>};
  const telar::testing::Case case_hostile_pack_delta{"git.hostile_pack_delta", readsWithGit<testHostilePackDelta>};
  const telar::testing::Case case_large_tree_delta{"git.large_tree_delta", readsWithGit<testLargeTreeDelta>};
  const telar::testing::Case case_config_syntax{"git.config_syntax_agrees", readsWithGit<testConfigSyntax>};
  const telar::testing::Case case_reference_names{"git.reference_names", readsWithGit<testReferenceNames>};
  const telar::testing::Case case_worktree_config{"git.worktree_config_extension", readsWithGit<testWorktreeConfigExtension>};
  const telar::testing::Case case_negative_refspec{"git.negative_refspec", readsWithGit<testNegativeRefspec>};
  const telar::testing::Case case_shallow_divergence{"git.shallow_divergence", readsWithGit<testShallowDivergence>};
  const telar::testing::Case case_octopus_commit_graph{"git.octopus_commit_graph", readsWithGit<testOctopusCommitGraph>};
  const telar::testing::Case case_racy_symlink{"git.racy_symlink", readsWithGit<testRacySymlink>};
  const telar::testing::Case case_not_owned_repository{"git.not_owned_repository", readsWithGit<testNotOwnedRepository>};

}
