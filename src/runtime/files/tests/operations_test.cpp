#include <cstdlib>
#include <sys/stat.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.platform.fs;
import telar.runtime.files.entry;
import telar.runtime.files.operations;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Result {
    FileOutcome outcome;
    std::string path;
  };

  struct Changed {
    std::vector<Result> results;
    bool undoable = false;
  };

  // A home of its own for each case, so the trash a change fills is the case's.
  struct Home {
    TemporaryDirectory directory{"/tmp/telar-home-XXXXXX"};
    std::string root{directory.path()};

    Home() {
      ::setenv("HOME", root.c_str(), 1);                      // NOLINT(concurrency-mt-unsafe): a test case runs alone in its process
      ::setenv("XDG_DATA_HOME", (root + "/data").c_str(), 1); // NOLINT(concurrency-mt-unsafe): a test case runs alone in its process
      std::filesystem::create_directories(root + "/work");
    }

    [[nodiscard]] std::string work(std::string_view name) const {
      return root + "/work/" + std::string{name};
    }

    // What the account's trash holds, on macOS and under the XDG layout.
    [[nodiscard]] std::vector<std::string> trashed() const {
      std::vector<std::string> names;

      for (const auto& directory : {root + "/.Trash", root + "/data/Trash/files"}) {
        if (std::filesystem::exists(directory)) {
          for (const auto& entry : std::filesystem::directory_iterator{directory}) {
            names.push_back(entry.path().filename().string());
          }
        }
      }

      std::ranges::sort(names);
      return names;
    }
  };

  Changed decode(const EncodedReply<ConcurrentMemory>& reply, std::uint64_t request) {
    std::vector<Byte> scratch(256 * 1024);
    DecodeStorage storage{scratch};
    const auto changed = Codec::decode<FilesChanged>(reply.payload(), storage);
    Changed result{.undoable = changed.undoable};

    check(changed.request_id == request);
    for (const auto& item : changed.results) {
      result.results.push_back({item.outcome, std::string{item.path}});
    }

    return result;
  }

  Changed change(FileChanger& changer, ConcurrentMemory& memory, std::vector<FileOperation> operations, bool overwrite = false) {
    const std::atomic<bool> cancelled{false};
    EncodedReply reply{memory};

    changer.change(ChangeFiles{.request_id = 3, .overwrite = overwrite, .operations = operations}, cancelled, reply);
    return decode(reply, 3);
  }

  Changed undo(FileChanger& changer, ConcurrentMemory& memory) {
    EncodedReply reply{memory};

    changer.undo(UndoFileChanges{.request_id = 5}, reply);
    return decode(reply, 5);
  }

  void write(const std::string& path, std::string_view text) {
    std::ofstream{path} << text;
  }

  std::string read(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, std::istreambuf_iterator<char>{}};
  }

  FileIdentity identity(const std::string& path) {
    struct stat status{};

    check(::lstat(path.c_str(), &status) == 0);
    return identityOf(status);
  }

  void testAPlanCreatesMovesCopiesAndTrashes() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const Home home;
    FileChanger changer{memory};

    write(home.work("a.txt"), "alpha");
    write(home.work("b.txt"), "beta");
    std::filesystem::create_directories(home.work("tree/inner"));
    write(home.work("tree/inner/leaf"), "leaf");
    std::filesystem::create_symlink("inner/leaf", home.work("tree/link"));

    const auto a = home.work("a.txt");
    const auto b = home.work("b.txt");
    const auto tree = home.work("tree");
    const auto made = home.work("made");
    const auto empty = home.work("made/empty.txt");
    const auto renamed = home.work("made/renamed.txt");
    const auto copy = home.work("made/tree");
    const auto changed = change(changer, memory, {
                                                     {.kind = FileOperationKind::create_directory, .target = made},
                                                     {.kind = FileOperationKind::create_file, .target = empty},
                                                     {.kind = FileOperationKind::move, .source = a, .target = renamed, .identity = identity(a)},
                                                     {.kind = FileOperationKind::copy, .source = tree, .target = copy},
                                                     {.kind = FileOperationKind::trash, .source = b},
                                                 });

    check(changed.results.size() == 5 && changed.undoable);
    check(std::ranges::all_of(changed.results, [](const Result& result) {
      return result.outcome == FileOutcome::done;
    }),
        "every operation of the plan was applied");
    check(std::filesystem::is_directory(made) && std::filesystem::is_empty(empty), "a directory and an empty file");
    check(!std::filesystem::exists(a) && read(renamed) == "alpha", "a file moved under its new name");
    check(read(copy + "/inner/leaf") == "leaf" && read(tree + "/inner/leaf") == "leaf", "a directory copied with what is below it, its source left");
    check(std::filesystem::is_symlink(copy + "/link") && std::filesystem::read_symlink(copy + "/link") == "inner/leaf", "a link copied as a link");
    check(!std::filesystem::exists(b) && home.trashed() == std::vector<std::string>{"b.txt"}, "a deleted file is in the trash, not gone");

    const auto undone = undo(changer, memory);

    check(undone.results.size() == 5 && !undone.undoable);
    check(std::ranges::all_of(undone.results, [](const Result& result) {
      return result.outcome == FileOutcome::done;
    }),
        "every step was taken back");
    check(read(a) == "alpha" && read(b) == "beta" && !std::filesystem::exists(made), "and the files are where they were");
    check(undo(changer, memory).results.empty(), "what was taken back is not taken back twice");
  }

  void testAFileChangedSinceItWasListedIsLeftAlone() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const Home home;
    FileChanger changer{memory};
    const auto file = home.work("edited.txt");

    write(file, "as listed");

    auto listed = identity(file);

    // Another program replaced the file since: the same name, another inode.
    std::filesystem::remove(file);
    write(home.work("other"), "x");
    write(file, "as an agent left it");
    listed.modified_nanoseconds = listed.modified_nanoseconds == 0 ? 1 : 0;

    const auto changed = change(changer, memory, {
                                                     {.kind = FileOperationKind::move, .source = file, .target = home.work("renamed.txt"), .identity = listed},
                                                     {.kind = FileOperationKind::trash, .source = file, .identity = listed},
                                                     {.kind = FileOperationKind::trash, .source = home.work("gone.txt")},
                                                     {.kind = FileOperationKind::trash, .source = "relative.txt"},
                                                     {.kind = FileOperationKind::move, .source = home.work("other"), .target = home.work("up/../escaped")},
                                                 });

    check(changed.results[0].outcome == FileOutcome::stale && changed.results[1].outcome == FileOutcome::stale, "a file that is not the one listed is neither moved nor deleted");
    check(read(file) == "as an agent left it" && home.trashed().empty());
    check(changed.results[2].outcome == FileOutcome::missing, "a file that is gone says so");
    check(changed.results[3].outcome == FileOutcome::refused && changed.results[4].outcome == FileOutcome::refused, "a path that is not absolute, or that climbs, is refused");
    check(!changed.undoable, "nothing was changed, so there is nothing to take back");
  }

  void testATargetThatExistsIsKeptOrGoesToTheTrash() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const Home home;
    FileChanger changer{memory};
    const auto source = home.work("new.md");
    const auto target = home.work("notes.md");

    write(source, "new");
    write(target, "old");

    const auto beside = change(changer, memory, {{.kind = FileOperationKind::copy, .source = source, .target = target}});

    check(beside.results[0].outcome == FileOutcome::renamed && beside.results[0].path == home.work("notes-1.md"), "without overwrite the copy takes a free name beside the target");
    check(read(target) == "old" && read(home.work("notes-1.md")) == "new");

    const auto over = change(changer, memory, {{.kind = FileOperationKind::move, .source = source, .target = target}}, true);

    check(over.results[0].outcome == FileOutcome::done && over.results[0].path == target && read(target) == "new", "with overwrite it takes the target's name");
    check(home.trashed() == std::vector<std::string>{"notes.md"}, "and what was there is in the trash");

    const auto undone = undo(changer, memory);

    check(undone.results.size() == 2 && read(target) == "old" && read(source) == "new", "taking it back returns both");

    const auto inside = change(changer, memory, {{.kind = FileOperationKind::move, .source = home.work(""), .target = home.work("inner/work")}});

    check(inside.results[0].outcome == FileOutcome::refused, "a directory does not go inside itself");

    // Onto itself a file neither moves nor is copied over: it stays as it is, whatever asked.
    const auto onto = change(changer, memory, {{.kind = FileOperationKind::move, .source = source, .target = source}, {.kind = FileOperationKind::copy, .source = source, .target = source}}, true);

    check(onto.results.size() == 2 && onto.results[0].outcome == FileOutcome::done && onto.results[1].outcome == FileOutcome::done && read(source) == "new", "and one put onto itself is left where it is");
    check(home.trashed() == std::vector<std::string>{}, "with nothing sent to the trash for it");
  }

  void testTheNameBesideATarget() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    ds::String<ConcurrentMemory> candidate{memory};

    besideName(candidate, "/a/notes.md", 1);
    check(candidate.view() == "/a/notes-1.md");
    besideName(candidate, "/a/archive.tar.gz", 12);
    check(candidate.view() == "/a/archive.tar-12.gz", "before its last extension");
    besideName(candidate, "/a/.env", 2);
    check(candidate.view() == "/a/.env-2", "a name that only starts with a dot has none");
    besideName(candidate, "/a/folder/", 3);
    check(candidate.view() == "/a/folder-3");
  }

  void testALinkIsMadeAsItIsSaidAndTakenBack() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const Home home;
    FileChanger changer{memory};
    const auto link = home.work("current");

    write(home.work("notes.txt"), "notes\n");

    // What it says is written as it is, whether it resolves or not.
    auto changed = change(changer, memory, {{.kind = FileOperationKind::link, .source = "notes.txt", .target = link}, {.kind = FileOperationKind::link, .source = "/nowhere/at/all", .target = home.work("broken")}});

    check(changed.results.size() == 2 && changed.results[0].outcome == FileOutcome::done && changed.results[0].path == link && changed.undoable);
    check(std::filesystem::is_symlink(link) && std::filesystem::read_symlink(link) == "notes.txt" && read(link) == "notes\n", "a relative text stays relative");
    check(std::filesystem::read_symlink(home.work("broken")) == "/nowhere/at/all");
    check(undo(changer, memory).results.size() == 2 && !std::filesystem::is_symlink(link) && !std::filesystem::is_symlink(home.work("broken")) && read(home.work("notes.txt")) == "notes\n", "u takes the links back, and nothing of what they pointed to");

    // A name that is taken is not written over, nor written through when it is itself a link.
    std::filesystem::create_symlink("notes.txt", link);
    changed = change(changer, memory, {{.kind = FileOperationKind::link, .source = "elsewhere", .target = link}});
    check(changed.results[0].outcome == FileOutcome::renamed && changed.results[0].path == home.work("current-1") && std::filesystem::read_symlink(link) == "notes.txt" && std::filesystem::read_symlink(home.work("current-1")) == "elsewhere" && read(home.work("notes.txt")) == "notes\n", "it takes a name beside the one that is taken");
    changed = change(changer, memory, {{.kind = FileOperationKind::link, .source = "", .target = home.work("empty")}});
    check(changed.results[0].outcome != FileOutcome::done && !std::filesystem::is_symlink(home.work("empty")), "a link that says nothing is not made");
  }

  const telar::testing::Case case_plan{"operations.a_plan_creates_moves_copies_and_trashes", testAPlanCreatesMovesCopiesAndTrashes};
  const telar::testing::Case case_link{"operations.a_link_is_made_as_it_is_said_and_taken_back", testALinkIsMadeAsItIsSaidAndTakenBack};
  const telar::testing::Case case_stale{"operations.a_file_changed_since_it_was_listed_is_left_alone", testAFileChangedSinceItWasListedIsLeftAlone};
  const telar::testing::Case case_exists{"operations.a_target_that_exists_is_kept_or_goes_to_the_trash", testATargetThatExistsIsKeptOrGoesToTheTrash};
  const telar::testing::Case case_beside{"operations.the_name_beside_a_target", testTheNameBesideATarget};

}
