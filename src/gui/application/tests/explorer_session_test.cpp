#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.keys;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  namespace explorer = application::explorer;

  constexpr explorer::Host host{.machine = 1, .name = "macbook", .home = "/home/dev", .local = true};
  constexpr std::string_view root = "/work/project";

  explorer::KeyChord key(char character) {
    explorer::KeyChord chord{.key = explorer::KeyChord::Key::character};

    chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(static_cast<unsigned char>(character)));
    return chord;
  }

  // A session whose first pane is in a directory, and the explorer open on it.
  struct Fixture {
    Fixture() {
      openFirstPane(client, transport);
      deliver(client, PaneCwd{.pane_id = 1, .cwd = root});
      application::workbench::focusPane(client, 1);
      check(explorer::available(client) && explorer::open(client, view, host), "a runtime that answers for files opens the explorer");
    }

    // The runtime lists the directory: one below it, and a file.
    void list() {
      const auto listing = transport.last<ListDirectory>();
      const ds::Array<DirectoryEntry, 2> entries{{
          {.name = "src", .kind = FileKind::directory, .directory = true, .identity = {.inode = 2, .modified_seconds = 5}},
          {.name = "README.md", .kind = FileKind::file, .size = 120, .identity = {.inode = 3, .modified_seconds = 10}},
      }};

      check(listing.path == root && listing.skip == 0);
      check(deliver(client, DirectoryContents{.request_id = listing.request_id, .path = root, .total = 2, .entries = entries.view()}) == application::Change::explorer);
      check(explorer::refresh(client, view, host), "what the runtime listed shows");
    }

    [[nodiscard]] explorer::RowLook row(std::size_t index) const {
      return explorer::look(client, view, host, {.window = 0, .row = index});
    }

    SystemAllocator memory;
    Transport transport;
    TestSession<SystemAllocator> client{memory, transport};
    explorer::View view{client.memory};
  };

  void theWindowAsksForWhatItShowsAndKeepsTheAnswers() {
    Fixture fixture;
    auto& transport = fixture.transport;

    check(transport.count(ClientTag::list_directory) == 1 && transport.count(ClientTag::query_changes) == 1, "the directory and what git says of it are asked for at once");
    fixture.list();
    check(fixture.row(0).name.view() == "src" && fixture.row(0).directory && fixture.row(1).name.view() == "README.md");
    check(transport.last<MeasureDirectory>().path == root, "its directories are measured once they are listed");

    // git answers: the file changed.
    const ds::Array<FileChange, 1> changes{{{.path = "README.md", .unstaged = FileState::modified, .added = 2, .removed = 1}}};

    check(deliver(fixture.client, RepositoryChanges{.request_id = transport.last<QueryChanges>().request_id, .path = root, .root = root, .branch = "main", .changes = changes.view()}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host));
    check(fixture.row(1).unstaged == FileState::modified && explorer::header(fixture.client, fixture.view, host, 0).branch.view() == "main");

    // The selection moves to the file: its preview is asked for, and its answer builds no row again.
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('j')));

    const auto inspect = transport.last<InspectFile>();
    const auto built = fixture.view.built;

    check(inspect.path == "/work/project/README.md");
    check(deliver(fixture.client, FileInspection{.request_id = inspect.request_id, .path = inspect.path, .size = 120, .text = "# Read me\n"}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host), "the preview shows");
    check(fixture.view.built == built && explorer::previewText(fixture.client, fixture.view) == "# Read me\n");
    check(!explorer::refresh(fixture.client, fixture.view, host), "with nothing new the window is left as it is");
  }

  void aDirectoryTheRuntimeRefusesIsNotAskedForAgain() {
    Fixture fixture;
    auto& transport = fixture.transport;
    const auto listing = transport.last<ListDirectory>();

    check(deliver(fixture.client, RequestFailed{.request_id = listing.request_id, .code = FailureCode::invalid_request, .message = "This account may not read the directory"}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host));
    check(fixture.row(0).kind == explorer::RowKind::note, "the window says so where the entries would be");
    static_cast<void>(explorer::refresh(fixture.client, fixture.view, host));
    check(transport.count(ClientTag::list_directory) == 1);
  }

  void aPlanIsSentWholeAndTakenBack() {
    Fixture fixture;
    auto& transport = fixture.transport;

    fixture.list();
    // The runtime answers what else the window asked: no repository, nothing to measure, and the
    // preview of the file the selection moves to.
    check(deliver(fixture.client, RepositoryChanges{.request_id = transport.last<QueryChanges>().request_id, .path = root}) == application::Change::explorer);
    check(deliver(fixture.client, DirectorySizes{.request_id = transport.last<MeasureDirectory>().request_id, .path = root}) == application::Change::explorer);
    static_cast<void>(explorer::refresh(fixture.client, fixture.view, host));
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('j')));
    check(deliver(fixture.client, FileInspection{.request_id = transport.last<InspectFile>().request_id, .path = "/work/project/README.md", .size = 120}) == application::Change::explorer);
    static_cast<void>(explorer::refresh(fixture.client, fixture.view, host));
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('d')));
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('d')));
    check(fixture.row(1).removed && transport.count(ClientTag::change_files) == 0, "a change typed asks the runtime for nothing");
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key(':')));
    static_cast<void>(explorer::submit(fixture.client, fixture.view, host, "w"));
    check(fixture.view.mode == explorer::Mode::plan && transport.count(ClientTag::change_files) == 0, "nor does the plan, until it is accepted");
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('y')));

    const auto sent = transport.last<ChangeFiles>();
    const auto listings = transport.count(ClientTag::list_directory);

    check(!sent.overwrite && sent.operations.size() == 1 && sent.operations[0].kind == FileOperationKind::trash && sent.operations[0].source == "/work/project/README.md");
    check(sent.operations[0].identity.inode == 3 && sent.operations[0].identity.modified_seconds == 10, "with the file the listing named, for the runtime to check it is still that one");

    const ds::Array<FileResult, 1> results{{{.outcome = FileOutcome::done, .path = "/work/project/README.md"}}};

    check(deliver(fixture.client, FilesChanged{.request_id = sent.request_id, .undoable = true, .results = results.view()}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host));
    check(fixture.view.edits.empty() && transport.count(ClientTag::list_directory) == listings + 1, "the changes are written, and the directory is read again");
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('u')));
    check(transport.count(ClientTag::undo_file_changes) == 1, "u with nothing typed takes the plan back");
  }

  void aFilterAsksTheRuntimeForThePathsBelowTheRoot() {
    Fixture fixture;
    auto& transport = fixture.transport;

    fixture.list();
    // The runtime answers what else the window asked, so it may ask for more.
    check(deliver(fixture.client, RepositoryChanges{.request_id = transport.last<QueryChanges>().request_id, .path = root}) == application::Change::explorer);
    check(deliver(fixture.client, DirectorySizes{.request_id = transport.last<MeasureDirectory>().request_id, .path = root}) == application::Change::explorer);
    static_cast<void>(explorer::refresh(fixture.client, fixture.view, host));
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key('/')));
    check(transport.count(ClientTag::find_paths) == 0, "an empty filter asks for nothing");
    explorer::typed(fixture.client, fixture.view, host, "read");

    const auto first = transport.last<FindPaths>();

    check(first.root == root && first.query == "read" && first.kind == PathKindFilter::any && first.limit == FindPaths::maximum_limit && !first.refresh, "with the window's root, and for files and directories");
    explorer::typed(fixture.client, fixture.view, host, "read");
    check(transport.count(ClientTag::find_paths) == 1, "the same text is not asked for twice");
    explorer::typed(fixture.client, fixture.view, host, "readm");

    const auto second = transport.last<FindPaths>();

    check(transport.count(ClientTag::find_paths) == 2 && second.query == "readm" && second.request_id != first.request_id, "a letter more replaces the query in flight");

    const ds::Array<PathMatch, 1> found{{{.path = "README.md", .kind = PathKind::file, .change = PathChange::modified}}};

    check(deliver(fixture.client, PathResults{.request_id = first.request_id, .root = root, .scanned = 2, .complete = true, .matches = found.view()}) != application::Change::explorer, "the answer to the older query is not the explorer's");
    static_cast<void>(explorer::refresh(fixture.client, fixture.view, host));
    check(fixture.row(0).kind == explorer::RowKind::note, "and nothing of it shows");
    check(deliver(fixture.client, PathResults{.request_id = second.request_id, .root = root, .scanned = 2, .complete = false, .matches = found.view()}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host));
    check(fixture.row(0).kind == explorer::RowKind::match && fixture.row(0).name.view() == "README.md" && fixture.row(0).unstaged == FileState::modified);
    check(explorer::status(fixture.client, fixture.view, host, 0).filter.view() == "/readm 1 …", "what it found so far, while the runtime still searches");
    check(deliver(fixture.client, PathResults{.request_id = second.request_id, .root = root, .scanned = 2, .complete = true, .matches = found.view()}) == application::Change::explorer);
    check(explorer::refresh(fixture.client, fixture.view, host) && explorer::status(fixture.client, fixture.view, host, 0).filter.view() == "/readm 1");

    // `<Tab>` on a directory the window does not hold asks the runtime for it.
    explorer::cancel(fixture.client, fixture.view, host);
    static_cast<void>(explorer::press(fixture.client, fixture.view, host, key(':')));

    const auto listings = transport.count(ClientTag::list_directory);

    explorer::complete(fixture.client, fixture.view, host, "e src/c");
    check(transport.count(ClientTag::list_directory) == listings + 1 && transport.last<ListDirectory>().path == "/work/project/src");
  }

  const telar::testing::Case case_asks{"explorer_session.the_window_asks_for_what_it_shows_and_keeps_the_answers", theWindowAsksForWhatItShowsAndKeepsTheAnswers};
  const telar::testing::Case case_filter{"explorer_session.a_filter_asks_the_runtime_for_the_paths_below_the_root", aFilterAsksTheRuntimeForThePathsBelowTheRoot};
  const telar::testing::Case case_refused{"explorer_session.a_directory_the_runtime_refuses_is_not_asked_for_again", aDirectoryTheRuntimeRefusesIsNotAskedForAgain};
  const telar::testing::Case case_plan{"explorer_session.a_plan_is_sent_whole_and_taken_back", aPlanIsSentWholeAndTakenBack};

}
