#include "explorer_fixture.hpp"

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;

  struct Fixture {
    SystemAllocator upstream;
    telar::MemoryAdapter<SystemAllocator> adapter{upstream};
    telar::Memory& memory = adapter;
    State state{memory};
  };

  std::vector<DirectoryEntry> page(std::vector<std::string>& names, std::size_t first, std::size_t count) {
    std::vector<DirectoryEntry> entries;

    for (std::size_t index = 0; index < count; ++index) {
      names.push_back("file" + std::to_string(first + index));
    }

    for (std::size_t index = names.size() - count; index < names.size(); ++index) {
      entries.push_back({.name = names[index], .kind = FileKind::file, .size = 1});
    }

    return entries;
  }

  void testADirectoryIsReadAPageAtATime() {
    Fixture fixture;
    auto& state = fixture.state;
    const Need listed{.kind = NeedKind::listing, .path = "/srv"};
    std::vector<std::string> names;

    check(lacks(state, listed) && listing(state, "/srv").skip == 0 && find(state, "/srv") == nullptr);
    asked(state, listed, 1);
    check(!lacks(state, listed) && state.in_flight == 1, "what was asked for is not asked for again");

    names.reserve(2 * FileLimits::maximum_entries);
    check(!receive(state, DirectoryContents{.request_id = 9, .path = "/srv", .total = 600}), "an answer nobody waits for is not kept");
    check(receive(state, DirectoryContents{.request_id = 1, .path = "/srv", .total = 600, .entries = page(names, 0, FileLimits::maximum_entries)}));

    const auto* directory = find(state, "/srv");

    check(directory != nullptr && directory->entries.size() == FileLimits::maximum_entries && !directory->whole() && state.in_flight == 0);
    check(lacks(state, listed) && listing(state, "/srv").skip == FileLimits::maximum_entries, "the next page starts where the last one ended");
    asked(state, listed, 2);
    check(receive(state, DirectoryContents{.request_id = 2, .path = "/srv", .skip = FileLimits::maximum_entries, .total = 600, .entries = page(names, FileLimits::maximum_entries, 88)}));
    check(directory->whole() && directory->entries.size() == 600 && directory->name(directory->entries[599]) == "file599" && !lacks(state, listed));

    // What changed on disk is read again from its first page, which replaces what was kept.
    invalidate(state, "/srv");
    check(lacks(state, listed) && listing(state, "/srv").skip == 0);
    asked(state, listed, 3);
    names.clear();
    check(receive(state, DirectoryContents{.request_id = 3, .path = "/srv", .total = 2, .entries = page(names, 0, 2)}));
    check(directory->entries.size() == 2 && directory->whole());

    // A directory the runtime refuses is not asked for over and over.
    const Need gone{.kind = NeedKind::listing, .path = "/gone"};

    asked(state, gone, 4);
    check(fail(state, RequestFailed{.request_id = 4, .code = FailureCode::invalid_request, .message = "no"}));
    check(!lacks(state, gone) && find(state, "/gone")->failed);
    check(!fail(state, RequestFailed{.request_id = 77, .code = FailureCode::invalid_request, .message = "not ours"}));
  }

  void testSizesFillTheDirectoriesOfAListing() {
    Fixture fixture;
    auto& state = fixture.state;
    const Need listed{.kind = NeedKind::listing, .path = "/srv"};
    const Need sizes{.kind = NeedKind::sizes, .path = "/srv"};
    const ds::Array<DirectoryEntry, 3> entries{DirectoryEntry{.name = "big", .kind = FileKind::directory, .directory = true}, DirectoryEntry{.name = "small", .kind = FileKind::directory, .directory = true}, DirectoryEntry{.name = "file", .kind = FileKind::file, .size = 9}};

    check(!lacks(state, sizes), "a directory not listed yet has nothing to measure");
    asked(state, listed, 1);
    check(receive(state, DirectoryContents{.request_id = 1, .path = "/srv", .total = 3, .entries = entries.view()}));
    check(lacks(state, sizes) && measure(state, "/srv").skip == 0);
    asked(state, sizes, 2);

    const ds::Array<DirectorySize, 2> measured{DirectorySize{.name = "big", .bytes = 4096, .complete = true}, DirectorySize{.name = "small", .bytes = 12, .complete = false}};

    check(receive(state, DirectorySizes{.request_id = 2, .path = "/srv", .sizes = measured.view()}));

    const auto* directory = find(state, "/srv");

    check(directory->entries[0].size == 4096 && directory->entries[0].measured && directory->entries[0].complete);
    check(directory->entries[1].size == 12 && !directory->entries[1].complete, "one the runtime ran out of time in says so");
    check(directory->entries[2].size == 9 && !lacks(state, sizes));
  }

  void testGitSaysHowAPathStands() {
    Fixture fixture;
    auto& state = fixture.state;
    const Need changes{.kind = NeedKind::changes, .path = "/repo/docs"};
    const ds::Array<FileChange, 6> listed{
        FileChange{.path = "docs/usage.md", .unstaged = FileState::modified, .added = 3, .removed = 1},
        FileChange{.path = "docs.old", .unstaged = FileState::deleted},
        FileChange{.path = "docs/deep/new.md", .staged = FileState::added},
        FileChange{.path = "out/", .unstaged = FileState::ignored},
        FileChange{.path = "notes/", .unstaged = FileState::untracked},
        FileChange{.path = "a.txt", .staged = FileState::modified, .unstaged = FileState::modified},
    };

    check(lacks(state, changes));
    asked(state, changes, 1);
    check(receive(state, RepositoryChanges{.request_id = 1, .path = "/repo/docs", .root = "/repo", .branch = "trunk", .changes = listed.view()}));
    check(!lacks(state, changes) && lacks(state, Need{.kind = NeedKind::changes, .path = "/other"}), "another root asks again");

    const auto& repository = state.repository;

    check(repository.staged == 2 && repository.unstaged == 3 && repository.untracked == 1);
    check(standing(repository, "/repo/docs/usage.md", false).unstaged == FileState::modified && standing(repository, "/repo/docs/usage.md", false).added == 3);
    check(standing(repository, "/repo/docs", true).below == 2, "a directory counts the changed paths below it, and no sibling that starts with its name");
    check(standing(repository, "/repo/docs/deep", true).below == 1 && standing(repository, "/repo/src", true).below == 0);
    check(standing(repository, "/repo/out", true).ignored && standing(repository, "/repo/out/dev/telar", false).ignored, "what is below an ignored directory is ignored");
    check(standing(repository, "/repo/notes/todo", false).unstaged == FileState::untracked && !standing(repository, "/repo/notes/todo", false).ignored);
    check(standing(repository, "/elsewhere/file", false).unstaged == FileState::unchanged && standing(repository, "/repo", true).below == 0, "outside the repository git says nothing");
  }

  void testPreviewsAreKeptAndForgotten() {
    Fixture fixture;
    auto& state = fixture.state;
    const Need wanted{.kind = NeedKind::inspection, .path = "/srv/a.md"};

    check(lacks(state, wanted) && inspected(state, "/srv/a.md") == nullptr);
    asked(state, wanted, 1);
    check(!lacks(state, wanted) && inspected(state, "/srv/a.md") == nullptr, "asked for, and not answered yet");
    check(receive(state, FileInspection{.request_id = 1, .path = "/srv/a.md", .size = 4, .text = "text"}));
    check(inspected(state, "/srv/a.md") != nullptr && inspected(state, "/srv/a.md")->text.view() == "text");

    // More previews than the window keeps: the one read longest ago goes.
    for (std::uint64_t index = 0; index < ExplorerLimits::inspections; ++index) {
      const auto path = "/srv/file" + std::to_string(index);
      const Need next{.kind = NeedKind::inspection, .path = path};

      asked(state, next, 10 + index);
      check(receive(state, FileInspection{.request_id = 10 + index, .path = path}));
    }

    check(state.inspections.size() == ExplorerLimits::inspections && inspected(state, "/srv/a.md") == nullptr && lacks(state, wanted));

    // A plan the runtime applied makes everything kept stale.
    applying(state, 50, false);
    check(receive(state, FilesChanged{.request_id = 50, .undoable = true}));
    check(state.inspections.empty() && state.undoable && state.settled == 1);
  }

  const telar::testing::Case case_pages{"cache.a_directory_is_read_a_page_at_a_time", testADirectoryIsReadAPageAtATime};
  const telar::testing::Case case_sizes{"cache.sizes_fill_the_directories_of_a_listing", testSizesFillTheDirectoriesOfAListing};
  const telar::testing::Case case_standing{"cache.git_says_how_a_path_stands", testGitSaysHowAPathStands};
  const telar::testing::Case case_previews{"cache.previews_are_kept_and_forgotten", testPreviewsAreKeptAndForgotten};

}
