#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/allocator.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.gui.foundation.terminal;
import telar.wire.layout;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  constexpr std::uint64_t editor_pane = 2;

  // One row of cells as the runtime sends it, padded to `columns`.
  struct Row {
    Row(std::uint16_t columns, std::uint16_t row, std::string_view text) {
      std::vector<Cell> cells;

      for (std::size_t column = 0; column < columns; ++column) {
        const auto character = column < text.size() ? text.substr(column, 1) : std::string_view{" "};

        cells.push_back({.text = {reinterpret_cast<const Byte*>(character.data()), character.size()}});
      }

      bytes.resize(CellRunCodec::encodedSize(cells));
      span = {.start = static_cast<std::uint32_t>(row) * columns, .count = columns, .cells = CellRunCodec::encode(cells, bytes)};
    }

    std::vector<Byte> bytes;
    FrameSpan span;
  };

  // A session with a terminal, which then asks for an editor beside it and is answered.
  template <typename Client>
  void openEditor(Client& client, Transport& transport) {
    openFirstPane(client, transport);
    check(application::nvim::available(client), "a runtime that speaks the editor's messages runs editors");
    check(application::workbench::splitEditor(client, ClientLayoutAxis::horizontal), "the focused pane splits for an editor");

    const auto request = transport.last<CreateNvimPane>();

    check(!request.new_tab && request.location.tab_id == client.findPane(1)->location.tab_id, "beside the pane it splits");
    deliver(client, PaneKindNotice{.pane_id = editor_pane, .kind = PaneKind::nvim});
    deliver(client, PaneOpened{.request_id = request.request_id, .pane_id = editor_pane, .location = request.location, .created = true});
  }

  void editorOpensBesideAndIsDrawn() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    check(application::nvim::editor(client, 1) == nullptr);
    openEditor(client, transport);

    const auto* pane = client.findPane(editor_pane);

    check(pane != nullptr && pane->attached && application::nvim::editor(client, editor_pane) != nullptr && application::nvim::editor(client, 1) == nullptr, "the pane the runtime announced is an editor, and the terminal is not");

    const Row row{8, 0, "telar"};

    check(deliver(client, NvimGrid{.pane_id = editor_pane, .frame_id = 1, .grid = 1, .columns = 8, .rows = 1, .full = true, .spans = {&row.span, 1}}) == application::Change::none, "a grid waits for its frame to end");
    check(deliver(client, NvimFrame{.pane_id = editor_pane, .frame_id = 1, .cursor_grid = 1, .cursor_column = 5, .cursor_visible = true, .mode = "normal"}) == application::Change::editor, "a frame that ends is shown");
    check(client.changedPane() == editor_pane && transport.last<FrameAck>().pane_id == editor_pane && transport.last<FrameAck>().frame_id == 1, "and the runtime hears it was applied");

    const auto* editor = application::nvim::editor(client, editor_pane);

    check(editor->frame == 1 && editor->grid(1) != nullptr && editor->grid(1)->screen.row(0)[4].utf8() == "r" && editor->cursor.column == 5);
  }

  void whatAPersonDoesReachesNeovim() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openEditor(client, transport);
    application::nvim::type(client, editor_pane, "<C-w>v");
    check(textView(transport.last<NvimInput>().keys) == "<C-w>v" && transport.last<NvimInput>().pane_id == editor_pane, "keys go in Neovim's notation");
    application::nvim::paste(client, editor_pane, "two\nlines");
    check(textView(transport.last<NvimPaste>().text) == "two\nlines");
    application::nvim::point(client, {.pane_id = editor_pane, .grid = 3, .row = 2, .column = 7, .button = NvimMouseButton::left, .action = NvimMouseAction::press});
    check(transport.last<NvimMouse>().grid == 3 && transport.last<NvimMouse>().column == 7);
    application::nvim::focus(client, editor_pane, false);
    check(!transport.last<NvimFocus>().focused);
    application::nvim::show(client, editor_pane, {.path = "/tmp/a.txt", .line = 3, .column = 1});
    check(transport.last<NvimOpen>().path == "/tmp/a.txt" && transport.last<NvimOpen>().line == 3);

    const auto resizes = transport.count(ClientTag::pane_resize);

    application::nvim::resize(client, editor_pane, {.cols = 90, .rows = 30, .cell_width_px = 8, .cell_height_px = 16});
    application::nvim::resize(client, editor_pane, {.cols = 90, .rows = 30, .cell_width_px = 8, .cell_height_px = 16});
    check(transport.count(ClientTag::pane_resize) == resizes + 1 && transport.last<PaneResize>().size.cols == 90, "a size is sent once");

    // Nothing is sent to a terminal as if it were an editor.
    const auto inputs = transport.count(ClientTag::nvim_input);

    application::nvim::type(client, 1, "x");
    check(transport.count(ClientTag::nvim_input) == inputs, "keys for an editor never reach a terminal");
  }

  void lostFrameAsksForTheScreenOnce() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openEditor(client, transport);
    const auto snapshots = transport.count(ClientTag::request_snapshot);

    check(deliver(client, NvimFrame{.pane_id = editor_pane, .frame_id = 9, .base_frame_id = 8}) == application::Change::none, "a frame that changes one never shown is not drawn");
    check(deliver(client, NvimFrame{.pane_id = editor_pane, .frame_id = 10, .base_frame_id = 9}) == application::Change::none);
    check(transport.count(ClientTag::request_snapshot) == snapshots + 1 && transport.last<RequestSnapshot>().pane_id == editor_pane, "the screen is asked for whole, once");
  }

  void promptIsAnsweredThroughTheSession() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openEditor(client, transport);
    const ds::Array<std::string_view, 2> choices{"uno", "dos"};

    check(deliver(client, NvimPrompt{.pane_id = editor_pane, .serial = 1, .prompt_id = 6, .kind = NvimPromptKind::select, .title = "Pick", .choices = choices}) == application::Change::editor, "a prompt is something to show");
    check(application::nvim::editor(client, editor_pane)->prompt.id == 6);
    application::nvim::answer(client, editor_pane, true, 1);

    const auto reply = transport.last<NvimPromptReply>();

    check(reply.prompt_id == 6 && reply.accepted && reply.index == 1 && application::nvim::editor(client, editor_pane)->prompt.id == 0, "the answer names the prompt, which closes");
    application::nvim::answer(client, editor_pane, true, 0);
    check(transport.count(ClientTag::nvim_prompt_reply) == 1, "and is sent once");
  }

  void editorTabIsATabLikeAnyOther() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    const auto tabs = client.tabs.size();

    check(application::workbench::createEditorTab(client) == application::TabCreationOutcome::requested);
    const auto request = transport.last<CreateNvimPane>();

    check(request.new_tab && request.location.workspace.id == client.findPane(1)->location.workspace.id);
    deliver(client, PaneKindNotice{.pane_id = editor_pane, .kind = PaneKind::nvim});
    deliver(client, TabCreated{.request_id = request.request_id, .location = {.workspace = request.location.workspace, .tab_id = 77}, .position = 1, .root_pane_id = editor_pane, .pane_generation = 1});
    check(client.tabs.size() == tabs + 1 && client.findPane(editor_pane) != nullptr && client.findPane(editor_pane)->attached && application::nvim::editor(client, editor_pane) != nullptr, "the tab's pane is an editor the session is attached to");
  }

  const telar::testing::Case case_opens{"nvim_session.editor_opens_beside_and_is_drawn", editorOpensBesideAndIsDrawn};
  const telar::testing::Case case_input{"nvim_session.what_a_person_does_reaches_neovim", whatAPersonDoesReachesNeovim};
  const telar::testing::Case case_lost{"nvim_session.lost_frame_asks_for_the_screen_once", lostFrameAsksForTheScreenOnce};
  const telar::testing::Case case_prompt{"nvim_session.prompt_is_answered_through_the_session", promptIsAnsweredThroughTheSession};
  const telar::testing::Case case_tab{"nvim_session.editor_tab_is_a_tab_like_any_other", editorTabIsATabLikeAnyOther};

}
