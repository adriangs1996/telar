#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.gui.features.nvim;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::nvim;

  constexpr std::uint64_t pane_id = 5;

  // The memory a session's state lives in, and the editors of one whose pane 5 is an editor.
  struct Fixture {
    Fixture() {
      announce(state, PaneKindNotice{.pane_id = pane_id, .kind = PaneKind::nvim});
    }

    SystemAllocator upstream;
    telar::MemoryAdapter<SystemAllocator> adapter{upstream};
    telar::Memory& memory = adapter;
    State state{memory};
  };

  // The cells of whole rows as the runtime sends them: `rows` texts from row `first`, each
  // padded to `columns` cells.
  struct Rows {
    Rows(std::uint16_t columns, std::uint16_t first, std::initializer_list<std::string_view> rows) {
      std::vector<Cell> cells;

      for (const auto row : rows) {
        for (std::size_t column = 0; column < columns; ++column) {
          const auto text = column < row.size() ? row.substr(column, 1) : std::string_view{" "};

          cells.push_back({.text = {reinterpret_cast<const Byte*>(text.data()), text.size()}});
        }
      }

      bytes.resize(CellRunCodec::encodedSize(cells));
      span = {.start = static_cast<std::uint32_t>(first) * columns, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, bytes)};
    }

    std::vector<Byte> bytes;
    FrameSpan span;
  };

  std::string textOf(std::span<const CellValue> cells) {
    std::string text;

    for (const auto& cell : cells) {
      text += cell.utf8();
    }

    text.erase(text.find_last_not_of(' ') + 1);
    return text;
  }

  std::string rowText(const Grid& grid, std::size_t row) {
    return textOf(grid.screen.row(row));
  }

  // A grid of four columns and three rows sent whole in frame 1, which then ends.
  void showFirstFrame(State& state, std::uint32_t grid = 1) {
    const Rows rows{4, 0, {"uno", "dos", "tres"}};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = grid, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .full = true, .spans = {&rows.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 1, .cursor_grid = grid, .cursor_row = 1, .cursor_column = 2, .cursor_visible = true, .mode = "normal"}) == Received::presented);
  }

  void frameIsShownWhenItEnds() {
    Fixture fixture;
    auto& state = fixture.state;
    const Rows rows{4, 0, {"uno", "dos", "tres"}};

    check(find(state, pane_id) != nullptr && find(state, pane_id)->grids.empty() && find(state, pane_id + 1) == nullptr, "a pane the runtime called an editor is one, before anything is drawn");
    check(receive(state, NvimGrid{.pane_id = pane_id + 1, .frame_id = 1, .grid = 1, .columns = 4, .rows = 3, .full = true, .spans = {&rows.span, 1}}) == Received::ignored, "a grid of a pane that is no editor");
    showFirstFrame(state);

    const auto& editor = *find(state, pane_id);
    const auto* grid = editor.grid(1);

    check(editor.frame == 1 && editor.revision == 1 && grid != nullptr && grid->placement == NvimPlacement::window, "the frame is the one shown");
    check(rowText(*grid, 0) == "uno" && rowText(*grid, 2) == "tres" && grid->screen.columns() == 4 && grid->screen.rows() == 3, "with the cells it was sent");
    check(editor.cursor.visible && editor.cursor.row == 1 && editor.cursor.column == 2 && editor.mode.view() == "normal", "and the cursor where Neovim has it");
    check(grid->screen.cursor().visible && grid->screen.cursor().x == 2 && grid->screen.cursor().y == 1, "which the grid it is on draws");
  }

  void changesFollowTheFrameShown() {
    Fixture fixture;
    auto& state = fixture.state;

    showFirstFrame(state);
    const auto layout = find(state, pane_id)->layout_revision;
    const auto row_before = find(state, pane_id)->grid(1)->screen.rowRevision(0);
    const Rows changed{4, 1, {"DOS"}};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 2, .grid = 1, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .spans = {&changed.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 2, .base_frame_id = 1, .cursor_grid = 1, .cursor_visible = true}) == Received::presented);

    const auto& editor = *find(state, pane_id);
    const auto& grid = *editor.grid(1);

    check(rowText(grid, 0) == "uno" && rowText(grid, 1) == "DOS" && editor.frame == 2, "the cells that changed, over the ones it had");
    check(grid.screen.rowRevision(0) == row_before && grid.screen.rowRevision(1) != grid.screen.rowRevision(0), "only the rows that changed are drawn again");
    check(editor.layout_revision == layout, "cells alone leave the layout as it was");
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 2, .base_frame_id = 1}) == Received::ignored, "a frame already shown is passed by");
  }

  void scrollMovesTheRowsItHas() {
    Fixture fixture;
    auto& state = fixture.state;

    showFirstFrame(state);
    const Rows last{4, 2, {"four"}};
    const NvimScroll up{.top = 0, .bottom = 3, .left = 0, .right = 4, .rows = 1};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 2, .grid = 1, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .scrolled_lines = 1, .scrolls = {&up, 1}, .spans = {&last.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 2, .base_frame_id = 1}) == Received::presented);

    const auto& grid = *find(state, pane_id)->grid(1);

    check(rowText(grid, 0) == "dos" && rowText(grid, 1) == "tres" && rowText(grid, 2) == "four", "the rows move up and the new one arrives");
    check(grid.scrolled_lines == 1, "and the grid says how far its text moved");
    check(grid.departed.count == 1 && grid.departed.above && grid.departed.moved == 1 && textOf(grid.departed.row(0)) == "uno", "the row that left is kept for a view to slide out");

    const Rows first{4, 0, {"zero"}};
    const NvimScroll down{.top = 0, .bottom = 3, .left = 0, .right = 4, .rows = -2};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 3, .grid = 1, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .scrolls = {&down, 1}, .spans = {&first.span, 1}}) == Received::staged);
    check(rowText(grid, 0) == "zero" && rowText(grid, 2) == "dos", "a scroll down moves them the other way");
    check(grid.departed.count == 2 && !grid.departed.above && grid.departed.moved == -1, "the rows that left at the other end replace the ones kept");
    check(textOf(grid.departed.row(0)) == "tres" && textOf(grid.departed.row(1)) == "four", "nearest the grid first");
    check(grid.departed.stamp(0) != grid.departed.stamp(1), "and each named apart");

    const NvimScroll part{.top = 1, .bottom = 3, .left = 0, .right = 4, .rows = 1};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 3, .grid = 1, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .scrolls = {&part, 1}}) == Received::staged);
    check(grid.departed.count == 0 && grid.departed.moved == -1, "a scroll of part of the grid keeps none, and slides nothing");
  }

  void whatDoesNotFollowAsksForTheScreen() {
    Fixture fixture;
    auto& state = fixture.state;

    showFirstFrame(state);
    const Rows changed{4, 1, {"DOS"}};
    const NvimGrid partial{.pane_id = pane_id, .frame_id = 5, .grid = 1, .columns = 4, .rows = 3, .spans = {&changed.span, 1}};

    check(receive(state, partial) == Received::staged && receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 5, .base_frame_id = 4}) == Received::lost, "a frame that changes one the editor never showed");
    check(receive(state, partial) == Received::ignored && receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 6, .base_frame_id = 5}) == Received::ignored, "the screen is asked for once, and what is not it is passed by");

    const Rows whole{4, 0, {"a", "b", "c"}};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 7, .grid = 1, .columns = 4, .rows = 3, .full = true, .spans = {&whole.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 7}) == Received::presented && rowText(*find(state, pane_id)->grid(1), 1) == "b", "the screen sent whole is shown");

    const NvimGrid unknown{.pane_id = pane_id, .frame_id = 8, .grid = 9, .columns = 4, .rows = 3, .spans = {&changed.span, 1}};
    const NvimGrid resized{.pane_id = pane_id, .frame_id = 8, .grid = 1, .columns = 5, .rows = 3, .spans = {&changed.span, 1}};

    check(receive(state, unknown) == Received::lost, "cells of a grid the editor does not have");
    detach(state);
    check(receive(state, resized) == Received::lost, "cells of a grid of another size");
  }

  void gridsComeAndGo() {
    Fixture fixture;
    auto& state = fixture.state;

    showFirstFrame(state);
    const Rows cells{4, 0, {"menu"}};
    const auto before = find(state, pane_id)->layout_revision;

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 2, .grid = 3, .columns = 4, .rows = 1, .placement = NvimPlacement::floating, .row = 2, .column = 1, .z_index = 50, .full = true, .spans = {&cells.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 2, .base_frame_id = 1}) == Received::presented);
    check(find(state, pane_id)->grids.size() == 2 && find(state, pane_id)->grid(3)->placement == NvimPlacement::floating && find(state, pane_id)->layout_revision > before, "a float is one more grid, and the layout changed");

    const std::uint32_t gone = 3;

    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 3, .base_frame_id = 2, .removed = {&gone, 1}}) == Received::presented && find(state, pane_id)->grid(3) == nullptr, "a grid Neovim closed leaves");

    // A frame that stands alone names every grid there is.
    const Rows whole{4, 0, {"x", "y", "z"}};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 4, .grid = 7, .columns = 4, .rows = 3, .full = true, .spans = {&whole.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 4}) == Received::presented);
    check(find(state, pane_id)->grids.size() == 1 && find(state, pane_id)->grid(7) != nullptr, "the grids it does not name are dropped");
    forget(state, pane_id);
    check(find(state, pane_id) == nullptr, "a pane that closed is no editor");
  }

  void surfacesTakeTheFrame() {
    Fixture fixture;
    auto& state = fixture.state;

    showFirstFrame(state);
    const ds::Array items{NvimMenuItem{.word = "write", .kind = "cmd"}, NvimMenuItem{.word = "wall", .menu = "all"}};
    const ds::Array shown{NvimMessageItem{.id = 1, .kind = NvimMessageKind::error, .text = "E492"}};
    const ds::Array tabs{NvimTab{.handle = 1, .name = "main.cpp"}, NvimTab{.handle = 2, .name = "notes", .modified = true, .diagnostics = 3}};

    check(receive(state, NvimCmdline{.pane_id = pane_id, .frame_id = 2, .visible = true, .level = 1, .first = ':', .position = 2, .text = "wr"}) == Received::staged);
    check(receive(state, NvimPopupMenu{.pane_id = pane_id, .frame_id = 2, .visible = true, .selected = 1, .grid = -1, .total = 2, .items = items, .info = "writes every buffer"}) == Received::staged);
    check(receive(state, NvimMessageList{.pane_id = pane_id, .frame_id = 2, .mode = "-- INSERT --", .messages = shown}) == Received::staged);
    check(receive(state, NvimTabLine{.pane_id = pane_id, .frame_id = 2, .current_tab = 2, .tabs = tabs}) == Received::staged);

    const auto& editor = *find(state, pane_id);
    const std::string_view menu_text{editor.menu.text.data(), editor.menu.text.size()};
    const std::string_view tab_text{editor.tabs.text.data(), editor.tabs.text.size()};
    const std::string_view message_text{editor.messages.text.data(), editor.messages.text.size()};

    check(editor.cmdline.visible && editor.cmdline.first == ':' && editor.cmdline.text.view() == "wr" && editor.cmdline.position == 2, "the command line");
    check(editor.menu.visible && editor.menu.selected == 1 && editor.menu.items.size() == 2 && editor.menu.items[1].word.of(menu_text) == "wall" && editor.menu.items[1].menu.of(menu_text) == "all" && editor.menu.items[0].kind.of(menu_text) == "cmd", "the completion menu");
    check(editor.menu.info.view() == "writes every buffer", "with what its selected item says of itself");
    check(editor.messages.mode.view() == "-- INSERT --" && editor.messages.items.size() == 1 && editor.messages.items[0].kind == NvimMessageKind::error && editor.messages.items[0].text.of(message_text) == "E492", "the messages");
    check(editor.tabs.current_tab == 2 && editor.tabs.tabs.size() == 2 && editor.tabs.tabs[1].name.of(tab_text) == "notes" && editor.tabs.tabs[1].modified && !editor.tabs.tabs[0].modified && editor.tabs.tabs[1].diagnostics == 3, "the tabs, which has changes not written and how many diagnostics");

    // The selection moves: the items the editor has stay.
    check(receive(state, NvimPopupMenu{.pane_id = pane_id, .frame_id = 2, .visible = true, .keeps_items = true, .selected = 0, .grid = -1, .total = 2}) == Received::staged);
    check(editor.menu.selected == 0 && editor.menu.items.size() == 2, "a selection that moved keeps the items");
    check(editor.menu.info.empty(), "and takes the documentation of the item it moved to, which has none");
    check(receive(state, NvimCmdline{.pane_id = pane_id, .frame_id = 1, .visible = false}) == Received::ignored && editor.cmdline.visible, "a surface of a frame already shown changes nothing");
  }

  // A detached pane is attached again with the screen whole, which the runtime numbers by its
  // screen: a frame of the number the editor last applied is taken.
  void detachedEditorTakesTheScreenAgain() {
    Fixture fixture;
    auto& state = fixture.state;
    const Rows rows{4, 0, {"uno", "dos", "tres"}};

    showFirstFrame(state);
    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = 1, .columns = 4, .rows = 3, .full = true, .spans = {&rows.span, 1}}) == Received::ignored, "attached, a frame already shown is passed by");
    detach(state, pane_id);
    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = 1, .columns = 4, .rows = 3, .full = true, .spans = {&rows.span, 1}}) == Received::staged);
    check(receive(state, NvimFrame{.pane_id = pane_id, .frame_id = 1, .cursor_grid = 1, .cursor_visible = true, .mode = "normal"}) == Received::presented, "attached again, it is shown");
  }

  // A message the person saw go stays gone while Neovim shows it, and is new when it comes back.
  void dismissedMessageStaysGone() {
    Fixture fixture;
    auto& state = fixture.state;
    const ds::Array both{NvimMessageItem{.id = 1, .text = "\"init.lua\" 3L, 40B"}, NvimMessageItem{.id = 2, .kind = NvimMessageKind::error, .text = "E492"}};
    const ds::Array last{NvimMessageItem{.id = 2, .kind = NvimMessageKind::error, .text = "E492"}};

    showFirstFrame(state);
    check(receive(state, NvimMessageList{.pane_id = pane_id, .frame_id = 2, .messages = both}) == Received::staged);
    const auto& messages = find(state, pane_id)->messages;
    const auto first = messages.items[0].key;

    check(first != messages.items[1].key, "each message has a key of its own");
    check(dismissMessage(state, pane_id, first) && !dismissMessage(state, pane_id, first), "a message goes once");
    check(!dismissMessage(state, pane_id, 99), "a message not shown does not go");
    check(receive(state, NvimMessageList{.pane_id = pane_id, .frame_id = 3, .messages = both}) == Received::staged);
    check(messages.items[0].key == first && messages.dismissed.size() == 1 && messages.dismissed[0] == first, "sent again, the same message stays gone");
    check(receive(state, NvimMessageList{.pane_id = pane_id, .frame_id = 4, .messages = last}) == Received::staged);
    check(messages.dismissed.empty(), "one Neovim no longer shows is forgotten");
    check(receive(state, NvimMessageList{.pane_id = pane_id, .frame_id = 5, .messages = both}) == Received::staged);
    check(messages.dismissed.empty(), "and is new when it comes back");
  }

  void promptIsAnsweredOnce() {
    Fixture fixture;
    auto& state = fixture.state;
    const ds::Array<std::string_view, 2> choices{"uno", "dos"};

    check(!answer(state, pane_id, true, 0, {}), "nothing is asked yet");
    check(receive(state, NvimPrompt{.pane_id = pane_id, .serial = 1, .prompt_id = 4, .kind = NvimPromptKind::select, .title = "Pick", .choices = choices}) == Received::presented);

    const auto& prompt = find(state, pane_id)->prompt;
    const std::string_view text{prompt.text.data(), prompt.text.size()};

    check(prompt.id == 4 && prompt.kind == NvimPromptKind::select && prompt.title.view() == "Pick" && prompt.choices.size() == 2 && prompt.choices[1].of(text) == "dos", "what Neovim asks");

    const auto reply = answer(state, pane_id, true, 1, {});

    check(reply && reply->prompt_id == 4 && reply->accepted && reply->index == 1 && prompt.id == 0, "the answer names the prompt, which closes");
    check(!answer(state, pane_id, true, 0, {}), "and is given once");
    check(receive(state, NvimPrompt{.pane_id = pane_id, .serial = 1, .prompt_id = 4, .kind = NvimPromptKind::select}) == Received::ignored, "a prompt already seen does not open again");
    check(receive(state, NvimPrompt{.pane_id = pane_id, .serial = 2}) == Received::presented && prompt.id == 0, "the runtime's word that nothing is asked");
  }

  void keysAreWrittenAsNeovimNamesThem() {
    check(notation({.codepoint = 'a'}).view() == "a" && notation({.codepoint = 'A', .shift = true}).view() == "A", "a character typed with nothing but shift is itself");
    check(notation({.codepoint = 0xf1}).view() == "\xc3\xb1", "also past ASCII");
    check(notation({.codepoint = '<'}).view() == "<lt>", "the character that opens a key name goes by its own");
    check(notation({.codepoint = 'w', .control = true}).view() == "<C-w>" && notation({.codepoint = 'p', .control = true, .shift = true}).view() == "<C-S-p>", "what is held with a character");
    check(notation({.codepoint = 's', .super = true}).view() == "<D-s>" && notation({.codepoint = 'x', .alt = true}).view() == "<A-x>", "Command and Option reach Neovim, which a terminal cannot tell it");
    check(notation({.name = "Esc"}).view() == "<Esc>" && notation({.name = "Tab", .shift = true}).view() == "<S-Tab>" && notation({.name = "F5", .control = true, .alt = true}).view() == "<C-A-F5>", "a named key");
    check(notation({.codepoint = ' '}).view() == " " && notation({.codepoint = ' ', .control = true}).view() == "<C-Space>" && notation({.codepoint = ' ', .shift = true}).view() == "<S-Space>", "the space bar, alone and held with something");
    check(notation({.codepoint = '<', .control = true}).view() == "<C-lt>");
  }

  // A row of cells drawn in `style`, one for each character of `text` and one for each icon.
  void paint(std::vector<CellValue>& row, std::string_view text, CellStyle style = {}) {
    while (!text.empty()) {
      const auto lead = static_cast<unsigned char>(text.front());
      const std::size_t size = lead < 0x80 ? 1 : lead < 0xE0 ? 2
                                             : lead < 0xF0   ? 3
                                                             : 4;
      CellValue cell;

      cell.style = style;
      cell.length = static_cast<Byte>(size);
      std::ranges::copy(text.substr(0, size), reinterpret_cast<char*>(cell.text.viewMut().data()));
      row.push_back(cell);
      text.remove_prefix(size);
    }
  }

  CellColor rgb(Byte red, Byte green, Byte blue) {
    return {.kind = CellColor::Kind::rgb, .channels = {red, green, blue}};
  }

  std::string tokenText(const StatusLine& line, std::size_t index) {
    return std::string{line.tokens[index].text.of({line.text.data(), line.text.size()})};
  }

  // The status line is read from the cells Neovim drew: its pills, its words and its icons, on
  // the two sides of its gap, whatever statusline drew it.
  void statusLineIsReadFromItsCells() {
    Fixture fixture;
    const CellStyle line_style{.foreground = rgb(200, 200, 200), .background = rgb(30, 30, 30)};
    const CellStyle mode{.flags = std::to_underlying(CellAttribute::bold), .foreground = rgb(0, 0, 0), .background = rgb(130, 170, 255)};
    const CellStyle branch{.foreground = rgb(255, 255, 255), .background = rgb(60, 60, 80)};
    const CellStyle named{.flags = std::to_underlying(CellAttribute::bold), .foreground = rgb(200, 200, 200), .background = rgb(30, 30, 30)};
    std::vector<CellValue> row;

    paint(row, " NORMAL ", mode);
    paint(row, " \ue0a0 main ", branch);
    paint(row, " \U000f0b26  src/", line_style);
    paint(row, "main.cpp", named);
    paint(row, "                    ", line_style);
    paint(row, " 1:1 ", mode);

    StatusLine line{fixture.memory};

    readStatusLine(row, line);
    check(line.pieces.size() == 4, "a pill for each background of its own, and one stretch on the line's");
    check(line.pieces[0].background && *line.pieces[0].background == mode.background && line.pieces[0].count == 1 && tokenText(line, 0) == "NORMAL", "the mode's pill, without the cells that pad it");
    check(line.pieces[1].background && line.tokens[1].icon && tokenText(line, 2) == "main" && line.tokens[2].gap == 1, "an icon of the Nerd Fonts is a token of its own");
    check(!line.pieces[2].background && !line.pieces[2].right && line.pieces[2].count == 3, "the words on the line's own background");
    check(line.tokens[3].icon && tokenText(line, 4) == "src/" && line.tokens[4].gap == 2 && tokenText(line, 5) == "main.cpp" && line.tokens[5].gap == 0, "words in two styles side by side stay two, with no gap between");
    check(line.pieces[3].right && line.pieces[3].background && tokenText(line, line.pieces[3].first) == "1:1", "what follows the gap is the right side");

    // The line is drawn flat: a word keeps whichever of its color and its background stands
    // apart from the line's.
    check(line.tokens[0].ink == mode.background, "dark letters on the mode's color are written in the mode's color");
    check(line.tokens[2].ink == branch.foreground, "light letters on a background near the line's keep their own color");
    check(line.tokens[4].ink == line_style.foreground, "and a word on the line's own background keeps its own");

    // Neovim's own status line reverses its colors: what it is drawn on is its foreground.
    const CellStyle reversed{.flags = std::to_underlying(CellAttribute::inverse), .foreground = rgb(40, 40, 40), .background = rgb(220, 220, 220)};

    row.clear();
    paint(row, "file.txt [+]          10,1   All", reversed);
    readStatusLine(row, line);
    check(line.pieces.size() == 2 && !line.pieces[0].background && !line.pieces[1].background && line.pieces[1].right, "a line all on one background is words on the line's own");
    check(tokenText(line, 0) == "file.txt" && tokenText(line, 1) == "[+]" && line.tokens[1].gap == 1 && tokenText(line, line.pieces[1].first) == "10,1");
    check(line.tokens[0].ink == reversed.background, "a reversed word is written in its background");

    // A color Neovim leaves to the window cannot be compared, and the word keeps its own.
    const CellStyle unset{.background = rgb(130, 170, 255)};

    row.clear();
    paint(row, "                ", line_style);
    paint(row, " VISUAL ", unset);
    readStatusLine(row, line);
    check(line.tokens.size() == 1 && line.tokens[0].ink == CellColor{}, "a word in the window's own color keeps it");
  }

  // A frame says on which row of the default grid the status line of the whole editor is.
  void frameSaysWhereTheStatusLineIs() {
    Fixture fixture;

    check(receive(fixture.state, NvimFrame{.pane_id = pane_id, .frame_id = 1, .status_line = true, .status_row = 22}) == Received::presented);
    check(find(fixture.state, pane_id)->status_row == std::uint16_t{22});
    check(receive(fixture.state, NvimFrame{.pane_id = pane_id, .frame_id = 2, .base_frame_id = 1}) == Received::presented && !find(fixture.state, pane_id)->status_row, "and when there is none");
  }

  // Cells of the default grid, one text for each, as the runtime sends them from its first row.
  struct Cells {
    explicit Cells(std::initializer_list<std::string_view> texts) {
      std::vector<Cell> cells;

      for (const auto text : texts) {
        cells.push_back({.text = {reinterpret_cast<const Byte*>(text.data()), text.size()}});
      }

      bytes.resize(CellRunCodec::encodedSize(cells));
      span = {.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, bytes)};
    }

    std::vector<Byte> bytes;
    FrameSpan span;
  };

  // Places window `grid` on the default grid, `height` rows from `row` and `width` columns from
  // `column`, in frame 1.
  void placeWindow(State& state, std::uint32_t grid, std::int32_t row, std::int32_t column, std::uint16_t width, std::uint16_t height) {
    const Rows rows{width, 0, {"w"}};

    check(receive(state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = grid, .columns = width, .rows = height, .placement = NvimPlacement::window, .row = row, .column = column, .width = width, .height = height, .full = true, .spans = {&rows.span, 1}}) == Received::staged);
  }

  std::string coveredOf(const Editor& editor, std::size_t row, std::size_t columns) {
    std::vector<Byte> covered(columns, Byte{7});
    std::string marks;

    coverDefaultRow(editor, row, covered);
    for (const auto flag : covered) {
      marks += flag != 0 ? '#' : '.';
    }

    return marks;
  }

  // The default grid keeps what Neovim drew under a window before the window came: none of it is
  // drawn, nor the separators and the status line the window draws itself. What is left is what
  // Neovim draws there for the window to show, a window's own status line.
  void defaultGridIsCoveredWhereTheWindowDrawsItself() {
    Fixture fixture;
    // A window over another on the left with a status line between them, a tall one on the
    // right past a separator, and the status line of the whole editor on the last row.
    const Cells base{
        "a",
        "b",
        "c",
        "│",
        "x",
        "y",
        "z",
        "s",
        "t",
        " ",
        "│",
        "x",
        "y",
        "z",
        "o",
        "l",
        "d",
        "│",
        "o",
        "l",
        "d",
        "N",
        "O",
        "R",
        "M",
        "A",
        "L",
        " ",
    };

    check(receive(fixture.state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = 1, .columns = 7, .rows = 4, .placement = NvimPlacement::window, .full = true, .spans = {&base.span, 1}}) == Received::staged);
    placeWindow(fixture.state, 2, 0, 0, 3, 1);
    placeWindow(fixture.state, 3, 0, 4, 3, 2);
    placeWindow(fixture.state, 4, 2, 0, 7, 1);
    check(receive(fixture.state, NvimFrame{.pane_id = pane_id, .frame_id = 1, .status_line = true, .status_row = 3}) == Received::presented);

    const auto& editor = *find(fixture.state, pane_id);

    check(coveredOf(editor, 0, 7) == "#######", "a row of windows and the separator between them is covered whole");
    check(coveredOf(editor, 1, 7) == "...####", "a window's own status line is drawn from the default grid");
    check(coveredOf(editor, 2, 7) == "#######", "what a window that came later stands over is not drawn");
    check(coveredOf(editor, 3, 7) == "#######", "nor the status line of the whole editor");
  }

  // A window that does not start at the editor's left edge has a separator's column there, and
  // one under a row Neovim rules has that row as its separator.
  void windowSeparatorsAreWhereNeovimDrawsThem() {
    Fixture fixture;
    const Cells base{
        "a",
        "│",
        "b",
        "b",
        "─",
        "─",
        "─",
        "─",
        "c",
        "c",
        "c",
        "c",
    };

    check(receive(fixture.state, NvimGrid{.pane_id = pane_id, .frame_id = 1, .grid = 1, .columns = 4, .rows = 3, .placement = NvimPlacement::window, .full = true, .spans = {&base.span, 1}}) == Received::staged);
    placeWindow(fixture.state, 2, 0, 2, 2, 1);
    placeWindow(fixture.state, 3, 2, 0, 4, 1);
    check(receive(fixture.state, NvimFrame{.pane_id = pane_id, .frame_id = 1}) == Received::presented);

    const auto& editor = *find(fixture.state, pane_id);
    const auto right = separators(editor, *editor.grid(2));
    const auto below = separators(editor, *editor.grid(3));

    check(right.left && right.left->row == 0 && right.left->column == 1 && right.left->rows == 1 && right.left->columns == 1 && !right.above, "the column left of a window is its separator");
    check(below.above && below.above->row == 1 && below.above->column == 0 && below.above->columns == 4 && !below.left, "a ruled row above a window is its separator");
    check(!separators(editor, *editor.grid(1)).left && !separators(editor, *editor.grid(1)).above, "the default grid has none");
  }

  // A query is found in a line as the search of text matches it: regardless of case only while
  // it has no capital letter.
  void queryIsFoundAsTheSearchMatchesIt() {
    check(findInLine("void open(WireRuntime& runtime)", "wire") == std::size_t{10}, "a query without capitals matches any case");
    check(findInLine("void open(wireRuntime& runtime)", "Wire") == ds::none, "one with a capital matches it exactly");
    check(findInLine("a wire, another wire", "wire", 3) == std::size_t{16}, "the next match is found after the one before");
    check(findInLine("a line", "") == ds::none && findInLine("a line", "line", 7) == ds::none && findInLine("ab", "abc") == ds::none, "nothing is found for nothing, past the end or for more than the line");
  }

  const telar::testing::Case case_status{"nvim.status_line_is_read_from_its_cells", statusLineIsReadFromItsCells};
  const telar::testing::Case case_status_row{"nvim.frame_says_where_the_status_line_is", frameSaysWhereTheStatusLineIs};
  const telar::testing::Case case_keys{"nvim.keys_are_written_as_neovim_names_them", keysAreWrittenAsNeovimNamesThem};
  const telar::testing::Case case_frame{"nvim.frame_is_shown_when_it_ends", frameIsShownWhenItEnds};
  const telar::testing::Case case_changes{"nvim.changes_follow_the_frame_shown", changesFollowTheFrameShown};
  const telar::testing::Case case_scroll{"nvim.scroll_moves_the_rows_it_has", scrollMovesTheRowsItHas};
  const telar::testing::Case case_lost{"nvim.what_does_not_follow_asks_for_the_screen", whatDoesNotFollowAsksForTheScreen};
  const telar::testing::Case case_grids{"nvim.grids_come_and_go", gridsComeAndGo};
  const telar::testing::Case case_surfaces{"nvim.surfaces_take_the_frame", surfacesTakeTheFrame};
  const telar::testing::Case case_prompt{"nvim.prompt_is_answered_once", promptIsAnsweredOnce};
  const telar::testing::Case case_detached{"nvim.detached_editor_takes_the_screen_again", detachedEditorTakesTheScreenAgain};
  const telar::testing::Case case_dismissed{"nvim.dismissed_message_stays_gone", dismissedMessageStaysGone};
  const telar::testing::Case case_found{"nvim.query_is_found_as_the_search_matches_it", queryIsFoundAsTheSearchMatchesIt};
  const telar::testing::Case case_covered{"nvim.default_grid_is_covered_where_the_window_draws_itself", defaultGridIsCoveredWhereTheWindowDrawsItself};
  const telar::testing::Case case_separators{"nvim.window_separators_are_where_neovim_draws_them", windowSeparatorsAreWhereNeovimDrawsThem};

}
