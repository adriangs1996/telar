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
    // A failure that answers no request is none of the explorer's, whatever waits for no answer.
    check(!fail(state, RequestFailed{.request_id = 0, .code = FailureCode::unsupported_pane_kind, .message = "This pane is not a terminal"}));
    check(!find(state, "/srv")->failed && find(state, "/srv")->entries.size() == 2, "and what was listed stays listed");
  }

  // The panes of a machine that are explorers, and the windows its runtime keeps of each.
  void testThePanesThatAreExplorersAreKept() {
    Fixture fixture;
    auto& state = fixture.state;
    const std::array<ExplorerWindow, 1> windows{{{.root = "/srv", .selected = "/srv/site"}}};
    const ExplorerKept kept{.pane_id = 7, .layout = {.windows = windows}};

    check(docked(state, 7) == nullptr && !receive(state, kept), "windows of a pane that is no explorer are not kept");
    dock(state, 7);
    dock(state, 7);
    check(state.docked.size() == 1 && docked(state, 7) != nullptr && docked(state, 7)->kept.empty());
    check(receive(state, kept) && !docked(state, 7)->kept.empty());

    ds::Array<Byte, FileLimits::explorer_windows * sizeof(ExplorerWindow)> scratch{};
    DecodeStorage storage{scratch.viewMut()};
    const auto read = Codec::decode<ExplorerKept>(docked(state, 7)->kept.view(), storage);

    check(read.pane_id == 7 && read.layout.windows.size() == 1 && read.layout.windows[0].root == "/srv" && read.layout.windows[0].selected == "/srv/site", "as the runtime said them");
    undock(state, 7);
    check(docked(state, 7) == nullptr);

    // A new connection says again which panes are explorers.
    dock(state, 8);
    reset(state);
    check(state.docked.empty());
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
    check(directory->entries[2].size == 9);

    // A page the runtime did not finish is asked for again, from where it was: it remembers
    // the sizes it finished, so each time goes further. A few times and no more.
    check(lacks(state, sizes) && measure(state, "/srv").skip == 0, "the same page again");
    for (std::uint64_t request = 3; request < 3 + ExplorerLimits::measure_attempts - 1; ++request) {
      asked(state, sizes, request);
      check(receive(state, DirectorySizes{.request_id = request, .path = "/srv", .sizes = measured.view()}) && lacks(state, sizes));
    }

    // The sizes that gave way to a listing are refused, and asked for again whatever was tried.
    asked(state, sizes, 20);
    check(fail(state, RequestFailed{.request_id = 20, .code = FailureCode::resource_limit, .message = "The sizes gave way to a listing"}) && lacks(state, sizes));
    asked(state, sizes, 21);
    check(receive(state, DirectorySizes{.request_id = 21, .path = "/srv", .sizes = measured.view()}));
    check(!lacks(state, sizes) && find(state, "/srv")->entries[1].size == 12 && !find(state, "/srv")->entries[1].complete, "a tree too large stays as far as it was measured");

    // Read again, it is measured again; and finished, it is asked for no more.
    invalidate(state, {});
    asked(state, listed, 30);
    check(receive(state, DirectoryContents{.request_id = 30, .path = "/srv", .total = 3, .entries = entries.view()}) && lacks(state, sizes));
    asked(state, sizes, 31);

    const ds::Array<DirectorySize, 2> whole{DirectorySize{.name = "big", .bytes = 4096, .complete = true}, DirectorySize{.name = "small", .bytes = 64, .complete = true}};

    check(receive(state, DirectorySizes{.request_id = 31, .path = "/srv", .sizes = whole.view()}) && !lacks(state, sizes) && find(state, "/srv")->entries[1].size == 64);

    // Sizes the runtime refuses each time are asked for a bounded number of times.
    invalidate(state, {});
    asked(state, listed, 40);
    check(receive(state, DirectoryContents{.request_id = 40, .path = "/srv", .total = 3, .entries = entries.view()}));
    for (std::uint64_t request = 41; request < 41 + ExplorerLimits::measure_yields; ++request) {
      check(lacks(state, sizes));
      asked(state, sizes, request);
      check(fail(state, RequestFailed{.request_id = request, .code = FailureCode::permission_denied, .message = "refused"}));
    }

    asked(state, sizes, 90);
    check(fail(state, RequestFailed{.request_id = 90, .code = FailureCode::permission_denied, .message = "refused"}) && !lacks(state, sizes));
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
  const telar::testing::Case case_docked{"cache.the_panes_that_are_explorers_are_kept", testThePanesThatAreExplorersAreKept};
  const telar::testing::Case case_previews{"cache.previews_are_kept_and_forgotten", testPreviewsAreKeptAndForgotten};

}
