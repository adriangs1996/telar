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
import telar.wire.nvim;
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
  // Another machine the window keeps: what `~` is there, only its runtime says.
  constexpr explorer::Host far{.machine = 2, .name = "box", .home = {}, .local = false};
  constexpr std::string_view root = "/work/project";

  explorer::KeyChord key(char character) {
    explorer::KeyChord chord{.key = explorer::KeyChord::Key::character};

    chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(static_cast<unsigned char>(character)));
    return chord;
  }

  explorer::KeyChord control(char character) {
    auto chord = key(character);

    chord.modifiers = static_cast<unsigned>(explorer::KeyChord::Modifier::control);
    return chord;
  }

  // A window that keeps two machines, as ui drives the explorer on it: the session of the one it
  // shows, whose first pane is in a directory, with the explorer open there; and the session of
  // another one, which is linked or away.
  struct Fixture {
    Fixture() {
      openFirstPane(client, transport);
      openFirstPane(box, box_transport);
      deliver(client, PaneCwd{.pane_id = 1, .cwd = root});
      application::workbench::focusPane(client, 1);
      check(explorer::available(client) && explorer::available(box), "a runtime that answers for files opens the explorer");
      observe();
      {
        const auto around = explorer::around(scene);

        explorer::open(view, client.explorer, explorer::contextOf(around, host.machine), host.machine);
      }

      static_cast<void>(refresh());
    }

    // What the explorer reads around the files: the panes that show, and the two machines.
    void observe() {
      explorer::clear(scene);
      explorer::observe(scene, client, host.machine);
      explorer::observe(scene, host, client);
      if (linked) {
        explorer::observe(scene, far, box);
      } else {
        explorer::observe(scene, far);
      }
    }

    [[nodiscard]] std::uint64_t here() const {
      return view.windows[view.current]->machine;
    }

    [[nodiscard]] TestSession<SystemAllocator>& session(std::uint64_t machine) {
      return machine == far.machine ? box : client;
    }

    [[nodiscard]] const TestSession<SystemAllocator>& session(std::uint64_t machine) const {
      return machine == far.machine ? box : client;
    }

    // The sessions kept what their runtimes answered: the windows of each machine take it in.
    bool refresh() {
      observe();

      const auto around = explorer::around(scene);
      const auto before = view.revision;

      static_cast<void>(explorer::refresh(client, view, explorer::contextOf(around, host.machine)));
      if (linked) {
        static_cast<void>(explorer::refresh(box, view, explorer::contextOf(around, far.machine)));
      } else {
        explorer::absorb(view, away, explorer::contextOf(around, far.machine), far.machine);
      }

      return view.revision != before;
    }

    // What an action asks: of the panes, which are of the session that shows, and of each runtime.
    explorer::Effect finish(const explorer::Action& action) {
      const auto around = explorer::around(scene);
      bool sent = explorer::send(client, view, explorer::contextOf(around, host.machine), action);

      if (linked) {
        sent = explorer::send(box, view, explorer::contextOf(around, far.machine), action) && sent;
      }

      const auto effect = sent ? explorer::deliver(client, view, explorer::contextOf(around, host.machine), action) : explorer::Effect::none;

      static_cast<void>(refresh());
      return effect;
    }

    explorer::Effect press(char character) {
      return strike(key(character));
    }

    explorer::Effect strike(explorer::KeyChord chord) {
      observe();

      const auto around = explorer::around(scene);
      const auto action = explorer::press(view, session(here()).explorer, explorer::contextOf(around, here()), chord);

      return finish(action);
    }

    explorer::Effect submit(std::string_view text) {
      observe();

      const auto around = explorer::around(scene);
      const auto action = explorer::submit(view, session(here()).explorer, explorer::contextOf(around, here()), text);

      return finish(action);
    }

    // `:` and a command, as typed.
    explorer::Effect run(std::string_view command) {
      static_cast<void>(press(':'));
      return submit(command);
    }

    void typed(std::string_view text) {
      observe();

      const auto around = explorer::around(scene);

      explorer::typed(view, session(here()).explorer, explorer::contextOf(around, here()), text);
      static_cast<void>(refresh());
    }

    void complete(std::string_view line) {
      observe();

      const auto around = explorer::around(scene);

      explorer::complete(view, session(here()).explorer, explorer::contextOf(around, here()), line);
      static_cast<void>(refresh());
    }

    void cancel() {
      observe();

      const auto around = explorer::around(scene);

      explorer::cancel(view, session(here()).explorer, explorer::contextOf(around, here()));
      static_cast<void>(refresh());
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
      check(refresh(), "what the runtime listed shows");
    }

    // The runtime of the machine that shows answers what else its window asked: no repository,
    // nothing to measure.
    void settle() {
      check(deliver(client, RepositoryChanges{.request_id = transport.last<QueryChanges>().request_id, .path = root}) == application::Change::explorer);
      check(deliver(client, DirectorySizes{.request_id = transport.last<MeasureDirectory>().request_id, .path = root}) == application::Change::explorer);
      static_cast<void>(refresh());
    }

    // A second window, on the other machine: its runtime says its home, and lists it.
    void splitToBox() {
      static_cast<void>(run("vs box:~"));
      check(deliver(box, HomeLocated{.request_id = box_transport.last<LocateHome>().request_id, .path = "/home/ops"}) == application::Change::explorer);
      static_cast<void>(refresh());

      const auto listing = box_transport.last<ListDirectory>();
      const ds::Array<DirectoryEntry, 1> entries{{{.name = "deploy.sh", .kind = FileKind::file, .size = 300, .identity = {.inode = 9, .modified_seconds = 15}}}};

      check(listing.path == "/home/ops");
      check(deliver(box, DirectoryContents{.request_id = listing.request_id, .path = "/home/ops", .total = 1, .entries = entries.view()}) == application::Change::explorer);
      check(deliver(box, RepositoryChanges{.request_id = box_transport.last<QueryChanges>().request_id, .path = "/home/ops"}) == application::Change::explorer);
      static_cast<void>(refresh());
    }

    [[nodiscard]] explorer::RowLook row(std::size_t index) const {
      return row(0, index);
    }

    [[nodiscard]] explorer::RowLook row(std::size_t window, std::size_t index) const {
      const auto around = explorer::around(scene);
      const auto machine = view.windows[window]->machine;

      return explorer::look(view, linked || machine == host.machine ? session(machine).explorer : away, explorer::contextOf(around, machine), {.window = window, .row = index});
    }

    [[nodiscard]] explorer::HeaderLook header(std::size_t window) const {
      const auto around = explorer::around(scene);
      const auto machine = view.windows[window]->machine;

      return explorer::header(view, session(machine).explorer, explorer::contextOf(around, machine), window);
    }

    [[nodiscard]] explorer::StatusLook status() const {
      const auto around = explorer::around(scene);

      return explorer::status(view, session(here()).explorer, explorer::contextOf(around, here()), view.current);
    }

    SystemAllocator memory;
    Transport transport;
    Transport box_transport;
    TestSession<SystemAllocator> client{memory, transport};
    TestSession<SystemAllocator> box{memory, box_transport};
    explorer::View view{client.memory};
    explorer::Scene scene{client.memory};
    // The cache of a machine with no session: it holds nothing.
    explorer::State away{client.memory};
    bool linked = true;
  };

  void theWindowAsksForWhatItShowsAndKeepsTheAnswers() {
    Fixture fixture;
    auto& transport = fixture.transport;

    check(transport.count(ClientTag::list_directory) == 1 && transport.count(ClientTag::query_changes) == 1, "the directory and what git says of it are asked for at once");
    check(transport.count(ClientTag::locate_home) == 1, "and the home of the account, once");
    fixture.list();
    check(fixture.row(0).name.view() == "src" && fixture.row(0).directory && fixture.row(1).name.view() == "README.md");
    check(transport.last<MeasureDirectory>().path == root, "its directories are measured once they are listed");

    // git answers: the file changed.
    const ds::Array<FileChange, 1> changes{{{.path = "README.md", .unstaged = FileState::modified, .added = 2, .removed = 1}}};

    check(deliver(fixture.client, RepositoryChanges{.request_id = transport.last<QueryChanges>().request_id, .path = root, .root = root, .branch = "main", .changes = changes.view()}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.row(1).unstaged == FileState::modified && fixture.header(0).branch.view() == "main");

    // The selection moves to the file: its preview is asked for, and its answer builds no row again.
    static_cast<void>(fixture.press('j'));

    const auto inspect = transport.last<InspectFile>();
    const auto built = fixture.view.windows[0]->built;

    check(inspect.path == "/work/project/README.md");
    check(deliver(fixture.client, FileInspection{.request_id = inspect.request_id, .path = inspect.path, .size = 120, .text = "# Read me\n"}) == application::Change::explorer);
    check(fixture.refresh(), "the preview shows");
    check(fixture.view.windows[0]->built == built && explorer::previewText(fixture.view, fixture.client.explorer) == "# Read me\n");
    check(!fixture.refresh(), "with nothing new the window is left as it is");
    check(fixture.box_transport.count(ClientTag::locate_home) == 0 && fixture.box_transport.count(ClientTag::list_directory) == 0, "a machine with no window is asked for nothing");
  }

  void aDirectoryTheRuntimeRefusesIsNotAskedForAgain() {
    Fixture fixture;
    auto& transport = fixture.transport;
    const auto listing = transport.last<ListDirectory>();

    check(deliver(fixture.client, RequestFailed{.request_id = listing.request_id, .code = FailureCode::invalid_request, .message = "This account may not read the directory"}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.row(0).kind == explorer::RowKind::note, "the window says so where the entries would be");
    static_cast<void>(fixture.refresh());
    check(transport.count(ClientTag::list_directory) == 1);
  }

  void aPlanIsSentWholeAndTakenBack() {
    Fixture fixture;
    auto& transport = fixture.transport;

    fixture.list();
    fixture.settle();
    // The preview of the file the selection moves to.
    static_cast<void>(fixture.press('j'));
    check(deliver(fixture.client, FileInspection{.request_id = transport.last<InspectFile>().request_id, .path = "/work/project/README.md", .size = 120}) == application::Change::explorer);
    static_cast<void>(fixture.refresh());
    static_cast<void>(fixture.press('d'));
    static_cast<void>(fixture.press('d'));
    check(fixture.row(1).removed && transport.count(ClientTag::change_files) == 0, "a change typed asks the runtime for nothing");
    static_cast<void>(fixture.run("w"));
    check(fixture.view.mode == explorer::Mode::plan && transport.count(ClientTag::change_files) == 0, "nor does the plan, until it is accepted");
    static_cast<void>(fixture.press('y'));

    const auto sent = transport.last<ChangeFiles>();
    const auto listings = transport.count(ClientTag::list_directory);

    check(!sent.overwrite && sent.operations.size() == 1 && sent.operations[0].kind == FileOperationKind::trash && sent.operations[0].source == "/work/project/README.md");
    check(sent.operations[0].identity.inode == 3 && sent.operations[0].identity.modified_seconds == 10, "with the file the listing named, for the runtime to check it is still that one");
    check(fixture.box_transport.count(ClientTag::change_files) == 0, "a machine the plan does not touch is sent nothing");

    const ds::Array<FileResult, 1> results{{{.outcome = FileOutcome::done, .path = "/work/project/README.md"}}};

    check(deliver(fixture.client, FilesChanged{.request_id = sent.request_id, .undoable = true, .results = results.view()}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.view.edits.empty() && transport.count(ClientTag::list_directory) == listings + 1, "the changes are written, and the directory is read again");
    static_cast<void>(fixture.press('u'));
    check(transport.count(ClientTag::undo_file_changes) == 1 && fixture.box_transport.count(ClientTag::undo_file_changes) == 0, "u with nothing typed takes the plan back, where it was written");
  }

  void aFilterAsksTheRuntimeForThePathsBelowTheRoot() {
    Fixture fixture;
    auto& transport = fixture.transport;

    fixture.list();
    // The runtime answers what else the window asked, so it may ask for more.
    fixture.settle();
    static_cast<void>(fixture.press('/'));
    check(transport.count(ClientTag::find_paths) == 0, "an empty filter asks for nothing");
    fixture.typed("read");

    const auto first = transport.last<FindPaths>();

    check(first.root == root && first.query == "read" && first.kind == PathKindFilter::any && first.limit == FindPaths::maximum_limit && !first.refresh, "with the window's root, and for files and directories");
    fixture.typed("read");
    check(transport.count(ClientTag::find_paths) == 1, "the same text is not asked for twice");
    fixture.typed("readm");

    const auto second = transport.last<FindPaths>();

    check(transport.count(ClientTag::find_paths) == 2 && second.query == "readm" && second.request_id != first.request_id, "a letter more replaces the query in flight");

    const ds::Array<PathMatch, 1> found{{{.path = "README.md", .kind = PathKind::file, .change = PathChange::modified}}};

    check(deliver(fixture.client, PathResults{.request_id = first.request_id, .root = root, .scanned = 2, .complete = true, .matches = found.view()}) != application::Change::explorer, "the answer to the older query is not the explorer's");
    static_cast<void>(fixture.refresh());
    check(fixture.row(0).kind == explorer::RowKind::note, "and nothing of it shows");
    check(deliver(fixture.client, PathResults{.request_id = second.request_id, .root = root, .scanned = 2, .complete = false, .matches = found.view()}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.row(0).kind == explorer::RowKind::match && fixture.row(0).name.view() == "README.md" && fixture.row(0).unstaged == FileState::modified);
    check(fixture.status().filter.view() == "/readm 1 …", "what it found so far, while the runtime still searches");
    check(deliver(fixture.client, PathResults{.request_id = second.request_id, .root = root, .scanned = 2, .complete = true, .matches = found.view()}) == application::Change::explorer);
    check(fixture.refresh() && fixture.status().filter.view() == "/readm 1");

    // `<Tab>` on a directory the window does not hold asks the runtime for it.
    fixture.cancel();
    static_cast<void>(fixture.press(':'));

    const auto listings = transport.count(ClientTag::list_directory);

    fixture.complete("e src/c");
    check(transport.count(ClientTag::list_directory) == listings + 1 && transport.last<ListDirectory>().path == "/work/project/src");
  }

  void aWindowOnAnotherMachineAsksThatMachineAlone() {
    Fixture fixture;
    auto& transport = fixture.transport;
    auto& box_transport = fixture.box_transport;

    fixture.list();
    fixture.settle();

    const auto listings = transport.count(ClientTag::list_directory);

    static_cast<void>(fixture.run("vs box:~"));
    check(fixture.view.windows.size() == 2 && fixture.here() == far.machine && fixture.view.windows[1]->loading, "the window waits to know where ~ is there");
    check(box_transport.count(ClientTag::locate_home) == 1 && box_transport.count(ClientTag::list_directory) == 0, "its runtime is asked for its home first, and for nothing below it yet");
    check(deliver(fixture.box, HomeLocated{.request_id = box_transport.last<LocateHome>().request_id, .path = "/home/ops"}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.view.windows[1]->root.view() == "/home/ops" && box_transport.last<ListDirectory>().path == "/home/ops" && box_transport.last<QueryChanges>().path == "/home/ops");
    check(transport.count(ClientTag::list_directory) == listings, "the machine that shows is asked for nothing of it");

    const ds::Array<DirectoryEntry, 1> entries{{{.name = "deploy.sh", .kind = FileKind::file, .size = 300, .identity = {.inode = 9, .modified_seconds = 15}}}};

    check(deliver(fixture.box, DirectoryContents{.request_id = box_transport.last<ListDirectory>().request_id, .path = "/home/ops", .total = 1, .entries = entries.view()}) == application::Change::explorer);
    check(fixture.refresh());
    check(fixture.row(1, 0).name.view() == "deploy.sh" && fixture.row(0, 0).name.view() == "src", "each window lists its own machine");
    check(fixture.header(1).machine.view() == "box" && !fixture.header(1).local && fixture.header(0).machine.view() == "macbook" && fixture.header(0).local);

    // A machine that is away says so, and is sent nothing.
    const auto sent = box_transport.sent.size();

    fixture.linked = false;
    check(fixture.refresh() && fixture.row(1, 0).kind == explorer::RowKind::note && fixture.row(1, 0).name.view() == "this machine is not connected");
    check(box_transport.sent.size() == sent);
  }

  void onePlanIsSentToEachMachineItTouches() {
    Fixture fixture;
    auto& transport = fixture.transport;
    auto& box_transport = fixture.box_transport;

    fixture.list();
    fixture.settle();
    fixture.splitToBox();

    // A file removed on each machine, and one plan for both.
    static_cast<void>(fixture.press('d'));
    static_cast<void>(fixture.press('d'));
    check(deliver(fixture.box, FileInspection{.request_id = box_transport.last<InspectFile>().request_id, .path = "/home/ops/deploy.sh", .size = 300}) == application::Change::explorer);
    static_cast<void>(fixture.refresh());
    static_cast<void>(fixture.strike(control('w')));
    static_cast<void>(fixture.press('h'));
    check(fixture.here() == host.machine);
    static_cast<void>(fixture.press('j'));
    check(deliver(fixture.client, FileInspection{.request_id = transport.last<InspectFile>().request_id, .path = "/work/project/README.md", .size = 120}) == application::Change::explorer);
    static_cast<void>(fixture.refresh());
    static_cast<void>(fixture.press('d'));
    static_cast<void>(fixture.press('d'));
    static_cast<void>(fixture.run("w"));
    check(fixture.view.mode == explorer::Mode::plan && fixture.view.plan.size() == 2 && fixture.view.plan[0].machine != fixture.view.plan[1].machine);
    static_cast<void>(fixture.press('y'));

    const auto near = transport.last<ChangeFiles>();
    const auto remote = box_transport.last<ChangeFiles>();

    check(near.operations.size() == 1 && near.operations[0].source == "/work/project/README.md");
    check(remote.operations.size() == 1 && remote.operations[0].source == "/home/ops/deploy.sh" && remote.operations[0].identity.inode == 9, "each runtime is sent the operations on its own files");

    const ds::Array<FileResult, 1> results{{{.outcome = FileOutcome::done}}};

    check(deliver(fixture.client, FilesChanged{.request_id = near.request_id, .undoable = true, .results = results.view()}) == application::Change::explorer);
    static_cast<void>(fixture.refresh());
    check(fixture.view.writing && fixture.view.message.view() == ":w · 1 applied by the runtime · 1 machine still to answer");
    check(deliver(fixture.box, FilesChanged{.request_id = remote.request_id, .undoable = true, .results = results.view()}) == application::Change::explorer);
    static_cast<void>(fixture.refresh());
    check(!fixture.view.writing && fixture.view.edits.empty() && fixture.view.message.view() == ":w · 2 applied by the runtime · u takes it back", "one line counts what both did");
    static_cast<void>(fixture.press('u'));
    check(transport.count(ClientTag::undo_file_changes) == 1 && box_transport.count(ClientTag::undo_file_changes) == 1, "u takes it back on every machine it touched");
  }

  void aFileOfAnotherMachineIsHandedOnlyThere() {
    Fixture fixture;
    auto& transport = fixture.transport;
    auto& box_transport = fixture.box_transport;

    fixture.list();
    fixture.settle();
    fixture.splitToBox();

    const auto typed = transport.sent.size();

    static_cast<void>(fixture.strike({.key = explorer::KeyChord::Key::enter}));
    check(fixture.view.message.view() == "It is on box and the focused pane on macbook: gf opens it there, yy copies where it is");
    static_cast<void>(fixture.press('@'));
    check(transport.sent.size() == typed && fixture.view.open, "a path of another machine is not typed at a pane of this one, nor mentioned there");
    static_cast<void>(fixture.press('y'));
    check(fixture.press('y') == explorer::Effect::copy && fixture.view.text.view() == "box:/home/ops/deploy.sh", "yy copies where it is");

    // gf opens it in an editor of its machine, from the pane focused there.
    static_cast<void>(fixture.run("pin"));
    static_cast<void>(fixture.press('g'));
    static_cast<void>(fixture.press('f'));
    check(box_transport.count(ClientTag::create_nvim_pane) == 1 && box_transport.last<CreateNvimPane>().files.size() == 1 && box_transport.last<CreateNvimPane>().files[0] == "/home/ops/deploy.sh");
    check(transport.count(ClientTag::create_nvim_pane) == 0 && transport.count(ClientTag::nvim_open) == 0 && fixture.view.open, "and in none of the machine that shows");

    // While that machine can open no editor, here with a pane still to be made, it says so.
    static_cast<void>(fixture.press('g'));
    check(fixture.press('f') == explorer::Effect::none && box_transport.count(ClientTag::create_nvim_pane) == 1);
    check(fixture.view.message.view() == "No editor opens on box: its runtime has none, or no tab to put it in");
  }

  const telar::testing::Case case_asks{"explorer_session.the_window_asks_for_what_it_shows_and_keeps_the_answers", theWindowAsksForWhatItShowsAndKeepsTheAnswers};
  const telar::testing::Case case_filter{"explorer_session.a_filter_asks_the_runtime_for_the_paths_below_the_root", aFilterAsksTheRuntimeForThePathsBelowTheRoot};
  const telar::testing::Case case_refused{"explorer_session.a_directory_the_runtime_refuses_is_not_asked_for_again", aDirectoryTheRuntimeRefusesIsNotAskedForAgain};
  const telar::testing::Case case_plan{"explorer_session.a_plan_is_sent_whole_and_taken_back", aPlanIsSentWholeAndTakenBack};
  const telar::testing::Case case_far{"explorer_session.a_window_on_another_machine_asks_that_machine_alone", aWindowOnAnotherMachineAsksThatMachineAlone};
  const telar::testing::Case case_plans{"explorer_session.one_plan_is_sent_to_each_machine_it_touches", onePlanIsSentToEachMachineItTouches};
  const telar::testing::Case case_hand{"explorer_session.a_file_of_another_machine_is_handed_only_there", aFileOfAnotherMachineIsHandedOnlyThere};

}
