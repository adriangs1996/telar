#include <csignal>
#include <sys/types.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.platform.process;
import telar.runtime.core.model.client_layouts;
import telar.runtime.core.model.slot_store;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A model with one terminal in it, running `cat`, which waits until it is told to end, and
  // on request an editor beside it: `cat` on pipes, which stands for a Neovim that says nothing.
  struct OneTerminal {
    static constexpr std::uint64_t pane_id = 7;
    static constexpr std::uint64_t editor_id = 8;

    explicit OneTerminal(ConcurrentMemory& memory, bool with_editor = false)
        : model(memory) {
      const ds::Array<std::string_view, 1> arguments{"/bin/cat"};
      Command command{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

      model.panes.insert(pane_id, ds::makeBox<TerminalPane>(memory, memory, pane_id, TabLocation{}, command, PaneLaunch{size, model.media_budget, model.graphics_limits}));
      if (with_editor) {
        Command embedded{memory, Launch{.cwd = "/tmp", .arguments = arguments}};

        model.panes.insert(editor_id, ds::makeBox<NvimPane>(memory, memory, editor_id, TabLocation{}, embedded, size));
      }
    }

    static constexpr TerminalSize size{.cols = 20, .rows = 4, .cell_width_px = 8, .cell_height_px = 16};
    RuntimeModel model;
  };

  FailureCode refusal(PaneStore& panes, std::uint64_t identity) {
    try {
      requireTerminal(panes, identity);
    } catch (const RequestError& error) {
      return error.code();
    }

    return FailureCode::internal;
  }

  FailureCode editorRefusal(PaneStore& panes, std::uint64_t identity) {
    try {
      requireNvim(panes, identity);
    } catch (const RequestError& error) {
      return error.code();
    }

    return FailureCode::internal;
  }

  // What a visit was handed: the terminal or the editor the pane is.
  struct Visited {
    void operator()(TerminalPane& pane) {
      terminal = &pane;
    }

    void operator()(NvimPane& pane) {
      editor = &pane;
    }

    TerminalPane* terminal = nullptr;
    NvimPane* editor = nullptr;
  };

  // Code that holds a pane by what every kind shares reaches a kind's own state only by naming
  // the kind, and gets the pane as that kind when it is one.
  void paneIsReachedAsItsKind() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    OneTerminal fixture{memory};
    auto* pane = fixture.model.panes.find(OneTerminal::pane_id);

    check(pane != nullptr && pane->kind == PaneKind::terminal, "the store finds the pane by what every kind shares");
    check(pane->process_id > 0 && pane->extent == OneTerminal::size, "its process and its size are the pane's, whatever its kind");

    auto* terminal = pane->asMut<TerminalPane>();

    check(terminal != nullptr && terminal->id == OneTerminal::pane_id, "the pane as the kind it is");
    check(asTerminal(pane) == terminal && asTerminal(static_cast<Pane*>(nullptr)) == nullptr, "no pane is no terminal");
    check(&requireTerminal(fixture.model.panes, OneTerminal::pane_id) == terminal && &requireTerminal(*pane) == terminal, "a request for a terminal gets it");
    Visited visited;

    visitPane(*pane, visited);
    check(visited.terminal == terminal && visited.editor == nullptr && std::as_const(*pane).as<TerminalPane>() == terminal, "a visit is handed the pane as its kind");
    check(terminal->terminal.screen().cols == OneTerminal::size.cols, "the terminal's own state");
    check(programTitle(*pane).text.empty() && programTitle(*pane).revision == terminal->terminal.effects().title_revision, "what its program titled it");
  }

  void missingPaneIsRefused() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    OneTerminal fixture{memory};

    check(refusal(fixture.model.panes, OneTerminal::pane_id + 1) == FailureCode::pane_not_found, "an id that names no pane");
    check(asTerminal(fixture.model.panes.find(OneTerminal::pane_id + 1)) == nullptr);
  }

  // The four ways a request for a kind meets a pane: each kind's request gets its own pane and
  // is refused the other's, with the failure that says the pane is of another kind.
  void requestForAnotherKindIsRefused() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    OneTerminal fixture{memory, true};
    auto& panes = fixture.model.panes;
    auto* editor = panes.find(OneTerminal::editor_id);

    check(editor != nullptr && editor->kind == PaneKind::nvim && editor->process_id > 0 && editor->extent == OneTerminal::size, "an editor is a pane like any other in the store");
    check(&requireTerminal(panes, OneTerminal::pane_id) == panes.find(OneTerminal::pane_id), "a terminal's request of a terminal");
    check(&requireNvim(panes, OneTerminal::editor_id) == editor, "an editor's request of an editor");
    check(refusal(panes, OneTerminal::editor_id) == FailureCode::unsupported_pane_kind, "a terminal's request of an editor");
    check(editorRefusal(panes, OneTerminal::pane_id) == FailureCode::unsupported_pane_kind, "an editor's request of a terminal");
    check(editorRefusal(panes, OneTerminal::editor_id + 1) == FailureCode::pane_not_found, "an id that names no pane is not a pane of another kind");
    check(asTerminal(editor) == nullptr && asNvim(panes.find(OneTerminal::pane_id)) == nullptr && asNvim(editor) != nullptr);

    Visited visited;

    visitPane(*editor, visited);
    check(visited.editor == asNvim(editor) && visited.terminal == nullptr, "a visit hands an editor over as an editor");

    // The store frees each pane as the kind it is: the test's memory fails one freed as another.
    signalProcess(*editor, SIGKILL);
    panes.erase(OneTerminal::editor_id);
    check(panes.find(OneTerminal::editor_id) == nullptr && panes.size() == 1);
  }

  // Closing, signalling and reaping go through the pane, and its kind does them. The store
  // frees the pane as the kind it is: the test's memory fails a pane freed as another size.
  void processIsDrivenThroughThePane() {
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    OneTerminal fixture{memory};
    auto& pane = *fixture.model.panes.find(OneTerminal::pane_id);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};

    check(!reapProcess(pane), "a running process has no exit status");
    requestClose(pane);
    check(pane.close_requested, "the pane was asked to close");
    signalProcess(pane, SIGKILL);

    while (!pane.exit_status) {
      check(std::chrono::steady_clock::now() < deadline, "the process ends");
      pane.exit_status = reapProcess(pane);
      std::this_thread::yield();
    }

    check(pane.exitCode().hasValue(), "its exit is the pane's");
    fixture.model.panes.erase(OneTerminal::pane_id);
    check(fixture.model.panes.find(OneTerminal::pane_id) == nullptr && fixture.model.panes.size() == 0, "the pane is gone");
  }

  const telar::testing::Case case_kind{"pane_kinds.pane_is_reached_as_its_kind", paneIsReachedAsItsKind};
  const telar::testing::Case case_missing{"pane_kinds.missing_pane_is_refused", missingPaneIsRefused};
  const telar::testing::Case case_refused{"pane_kinds.request_for_another_kind_is_refused", requestForAnotherKindIsRefused};
  const telar::testing::Case case_process{"pane_kinds.process_is_driven_through_the_pane", processIsDrivenThroughThePane};

}
