#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.clipboard;
import telar.wire.content;
import telar.gui.foundation.core;
import telar.config.client;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.wire.pane_io;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  namespace prompt = telar::gui::application::prompt;

  template <typename Client>
  void press(Client& client, char key) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = static_cast<char32_t>(key)});
  }

  template <typename Client>
  void control(Client& client, char key) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::character, .character = static_cast<char32_t>(key), .modifiers = {.control = true}});
  }

  template <typename Client>
  void escape(Client& client) {
    prompt::key(client, 1, prompt::KeyPress{.key = prompt::Key::escape});
  }

  // Telar's editor with vim's keys, on a shell at its prompt.
  template <typename Client>
  void editWithVim(Client& client) {
    auto configuration = client.configuration;

    configuration.prompt.mode = PromptMode::telar;
    configuration.prompt.keymap = PromptKeymap::vim;
    application::configuration::configure(client, configuration);
    deliver(client, PaneShell{.pane_id = 1, .shell = IntegratedShell::zsh, .phase = ShellPhase::prompt, .shell_foreground = true, .commands = 2});
  }

  // A screen of `rows` one-column rows, all of them in view, the prompt flagged on
  // `prompt_row` and the cursor on `cursor_row`.
  template <typename Client>
  void deliverScreen(Client& client, std::uint16_t rows, std::uint16_t prompt_row, std::uint16_t cursor_row) {
    constexpr std::size_t encoded_cell_bytes = 16;
    const std::vector<Cell> cells(rows, Cell{.text = byteView(" ")});
    std::vector<Byte> encoded(cells.size() * encoded_cell_bytes);
    const ds::Array spans{FrameSpan{.start = 0, .count = rows, .cells = CellRunCodec::encode(cells, encoded)}};
    std::vector<Byte> flags(rows);

    flags[prompt_row] = static_cast<Byte>(RowFlag::prompt);
    deliver(client, PaneFrame{FrameBody{.pane_id = 1, .frame_id = 1, .cols = 1, .rows = rows, .cursor = {.visible = true, .y = cursor_row}, .scroll = {.total_rows = rows}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
  }

  // Ctrl-O with the view already where the only jump left from goes nowhere, and the jump stays
  // for the next Ctrl-O once the view has moved.
  void jumpBackWithOneJumpStays() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = 0});
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    escape(client);
    press(client, '[');
    press(client, '[');
    check(client.selectedBlock(1) == std::size_t{0}, "[[ selects the only block, the view already on it");
    const auto before = transport.sent.size();

    control(client, 'o');
    check(client.selectedBlock(1) == std::size_t{0} && transport.sent.size() == before, "Ctrl-O there leaves the view and the block as they are");
    control(client, 'i');
    check(client.selectedBlock(1) == std::size_t{0} && transport.sent.size() == before, "and so does Ctrl-I, with nothing ahead");
    press(client, 'g');
    press(client, 'g');
    control(client, 'o');
    check(client.selectedBlock(1) == std::size_t{0}, "gg with the view at the top, then Ctrl-O, stays on the block");
  }

  // The live prompt is found however many rows the prompt and the command typed at it take: the
  // last command's output ends above it, and Y copies only that.
  void tallLivePromptEndsTheLastOutput() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    constexpr std::uint16_t rows = 20;
    constexpr std::uint16_t prompt_row = 4;
    // A prompt of two lines and a command of ten.
    constexpr std::uint16_t cursor_row = prompt_row + 11;

    openFirstPane(client, transport);
    deliverScreen(client, rows, prompt_row, cursor_row);
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::succeeded, .command = "make"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    escape(client);
    control(client, 'u');
    press(client, 'Y');
    const auto copied = transport.last<CopySelection>();

    check(copied.start_y == 1 && copied.end_y == prompt_row - 1, "Y copies the output down to the live prompt, not the prompt and command under it");
  }

  // A block's command goes back to the editor, as it is or with sudo, or runs again; a command
  // the block holds cut short is read whole from its rows and only goes to the editor.
  void reusedCommandGoesToTheEditor() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls -la"},
        CommandBlock{.row = 4, .rows = 3, .lines = 2, .state = CommandBlockState::failed, .status = 1, .command = "for x in a b"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    escape(client);
    client.selectBlock(1, std::size_t{0});
    press(client, 'e');
    check(prompt::line(client, 1)->text() == "ls -la" && !client.selectedBlock(1), "e puts the command in the editor and goes back to it");
    client.selectBlock(1, std::size_t{0});
    press(client, 'E');
    check(prompt::line(client, 1)->text() == "sudo ls -la", "E puts it there with sudo before it");

    // Cut short: its rows are read, and the command they hold waits in the editor.
    const auto before = transport.sent.size();

    client.selectBlock(1, std::size_t{1});
    press(client, 'R');
    const auto read = transport.last<CopySelection>();

    check(read.start_y == 4 && read.end_y == 6 && transport.commandsSince(before).empty(), "R on a command cut short reads its rows and runs nothing");
    deliver(client, PaneClipboard{.pane_id = 1, .bytes = byteView("% for x in a b\ndo echo $x\ndone\n")});
    check(prompt::line(client, 1)->text() == "for x in a b\ndo echo $x\ndone" && transport.commandsSince(before).empty() && std::string_view{client.clipboard()}.empty(), "the whole command waits in the editor, and the clipboard keeps what it held");

    client.selectBlock(1, std::size_t{0});
    press(client, 'R');
    check(transport.commandsSince(before) == std::vector<std::string>{"ls -la"}, "R runs a whole command again");
  }

  // A hundred rows at their live end, with blocks at rows 10, 40 and 70.
  template <typename Client>
  void openBlocks(Client& client, Transport& transport) {
    constexpr std::uint32_t rows = 100;

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll = {.total_rows = rows, .offset = rows - 1};
    deliverSingleCell(client, frame);
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = 0});
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = 10, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls"},
        CommandBlock{.row = 40, .rows = 1, .state = CommandBlockState::failed, .status = 1, .command = "make"},
        CommandBlock{.row = 70, .rows = 1, .state = CommandBlockState::succeeded, .command = "git log"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
  }

  template <typename Client>
  auto top(const Client& client) {
    return client.findPane(1)->screen.scroll().offset;
  }

  template <typename Client>
  void keys(Client& client, std::string_view typed) {
    for (const auto key : typed) {
      press(client, key);
    }
  }

  // m and a letter mark the selected block; ' and the letter select it again from anywhere, and `
  // goes back to the row the view was on. Marks follow their blocks as rows drop from the top and
  // as the rows are numbered anew, and go with a block that leaves the scrollback.
  void marksNameBlocks() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openBlocks(client, transport);
    escape(client);
    control(client, 'u');
    keys(client, "ma[[jmbggmc");
    check(client.selectedBlock(1) == std::size_t{0}, "marking leaves the block selected");
    press(client, 'G');
    keys(client, "'a");
    check(client.selectedBlock(1) == std::size_t{2} && top(client) == 70, "'a selects the block a marks, from the live end");
    keys(client, "`b");
    check(client.selectedBlock(1) == std::size_t{1} && top(client) == 41, "`b goes to the row the view was on when b was set");
    keys(client, "'z");
    check(client.selectedBlock(1) == std::size_t{1} && top(client) == 41, "a mark not set goes nowhere");

    constexpr std::uint32_t dropped = 15;

    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = dropped});
    press(client, 'G');
    keys(client, "`b");
    check(client.selectedBlock(1) == std::size_t{0} && top(client) == 41 - dropped, "the mark follows its block as the rows above it drop");
    keys(client, "'c");
    check(client.selectedBlock(1) == std::size_t{0} && top(client) == 41 - dropped, "the mark of a block that left the scrollback is gone");

    // Numbered anew: the blocks come again at their new rows, and the marks with them.
    constexpr std::uint32_t moved = 5;
    const ds::Array renumbered{
        CommandBlock{.row = 40 - dropped - moved, .rows = 1, .state = CommandBlockState::failed, .status = 1, .command = "make"},
        CommandBlock{.row = 70 - dropped - moved, .rows = 1, .state = CommandBlockState::succeeded, .command = "git log"},
    };

    deliver(client, PaneScrollback{.pane_id = 1, .generation = 2, .trimmed = 0});
    deliver(client, PaneBlocks{.pane_id = 1, .blocks = renumbered});
    press(client, 'G');
    keys(client, "'a");
    check(client.selectedBlock(1) == std::size_t{1} && top(client) == 70 - dropped - moved, "the marks follow their blocks when the rows are numbered anew");
  }

  // `command` runs at row `row`, then ends after `duration_ms`.
  template <typename Client>
  void runAndEnd(Client& client, std::uint32_t row, std::string_view command, std::uint32_t duration_ms, CommandBlockState ended = CommandBlockState::succeeded) {
    const ds::Array running{CommandBlock{.row = row, .rows = 1, .state = CommandBlockState::running, .command = command}};
    const ds::Array finished{CommandBlock{.row = row, .rows = 1, .state = ended, .status = ended == CommandBlockState::failed ? 2 : 0, .duration_ms = duration_ms, .command = command}};

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = running});
    deliver(client, PaneBlocks{.pane_id = 1, .blocks = finished});
  }

  template <typename Client>
  std::size_t notices(const Client& client) {
    return application::notifications::center(client).items().size();
  }

  // A command that ran past the threshold tells of its end while the window is behind another:
  // what it was, how it ended and how long it ran, and a click on the notice shows its pane.
  // A quick one, one the window showed as it ended, or any with the notices off, stays quiet.
  void longCommandTellsOfItsEnd() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    constexpr std::uint32_t long_ms = 45'000;
    constexpr std::uint32_t quick_ms = 2'000;

    openFirstPane(client, transport);
    FrameBody frame;

    frame.pane_id = 1;
    frame.frame_id = 1;
    frame.scroll.total_rows = 1;
    deliverSingleCell(client, frame);
    editWithVim(client);
    client.windowActivated(false);
    runAndEnd(client, 0, "make release", long_ms, CommandBlockState::failed);
    const auto& items = application::notifications::center(client).items();

    check(items.size() == 1 && items[0].title.view() == "Command failed" && items[0].message.view() == "make release · 45s · exit 2", "a long command that ends behind another window tells how it ended and how long it ran");
    check(items[0].target.kind == NotificationTarget::Kind::pane && items[0].target.id == 1, "its notice shows its pane");
    runAndEnd(client, 0, "ls", quick_ms);
    check(notices(client) == 1, "a quick command stays quiet");

    client.windowActivated(true);
    runAndEnd(client, 0, "make test", long_ms);
    check(notices(client) == 1, "a command the window showed as it ended stays quiet");

    client.windowActivated(false);
    auto configuration = client.configuration;

    configuration.long_commands.enabled = false;
    application::configuration::configure(client, configuration);
    runAndEnd(client, 0, "make test", long_ms);
    check(notices(client) == 1, "with the notices off, a long command stays quiet");
  }

  constexpr std::uint16_t filter_columns = 12;

  // The cells of `lines`, each `filter_columns` wide.
  std::vector<Cell> cellsOf(const std::vector<std::string_view>& lines) {
    std::vector<Cell> cells;

    for (const auto line : lines) {
      for (std::size_t column = 0; column < filter_columns; ++column) {
        cells.push_back(Cell{.text = byteView(column < line.size() ? line.substr(column, 1) : std::string_view{" "})});
      }
    }

    return cells;
  }

  // The filter's scrollback: forty rows, the screen holding the last ten with the live prompt on
  // its last row, and a block at row 20 whose output the screen does not hold.
  constexpr std::uint32_t filter_total = 40;
  constexpr std::uint16_t filter_rows = 10;
  constexpr std::uint32_t filter_block_row = 20;
  const std::vector<std::string_view> filter_output{"cc a.c", "warning: x", "cc b.c", "error: y", "cc c.c", "done", "", "", ""};

  template <typename Client>
  void openFilterScrollback(Client& client, Transport& transport) {
    openFirstPane(client, transport);
    deliver(client, PaneScrollback{.pane_id = 1, .generation = 1, .trimmed = 0});
    const auto cells = cellsOf(std::vector<std::string_view>(filter_rows, ""));
    std::vector<Byte> encoded(cells.size() * 16);
    const ds::Array spans{FrameSpan{.start = 0, .count = static_cast<std::uint32_t>(cells.size()), .cells = CellRunCodec::encode(cells, encoded)}};
    std::vector<Byte> flags(filter_rows);

    flags.back() = static_cast<Byte>(RowFlag::prompt);
    deliver(client, PaneFrame{FrameBody{.pane_id = 1, .frame_id = 1, .cols = filter_columns, .rows = filter_rows, .cursor = {.visible = true, .y = filter_rows - 1}, .scroll = {.total_rows = filter_total, .offset = filter_total - filter_rows}, .text_metadata = TextMetadata{.row_flags = flags}, .spans = spans}});
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = filter_block_row, .rows = 1, .state = CommandBlockState::succeeded, .command = "make"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
  }

  // The rows a request of the filter asked for, as the runtime sends them back.
  template <typename Client>
  void answerRows(Client& client, const ReadPaneRows& request) {
    const std::vector<std::string_view> lines(filter_output.begin(), filter_output.begin() + request.count);
    const auto cells = cellsOf(lines);
    std::vector<Byte> encoded(cells.size() * 16);
    const std::vector<Byte> flags(request.count, 0);

    deliver(client, PaneRows{.request_id = request.request_id, .pane_id = 1, .generation = 1, .from = request.from, .cols = filter_columns, .rows = request.count, .text_metadata = TextMetadata{.row_flags = flags}, .cells = CellRunCodec::encode(cells, encoded)});
  }

  // & filters the selected block's output: only the lines that match show, those the screen
  // does not hold asked of the runtime, Y copies what shows, and closing the filter shows it all
  // and takes the view back.
  void filterShowsOnlyTheMatchingLines() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    namespace filter = application::terminal::filter;

    openFilterScrollback(client, transport);
    escape(client);
    control(client, 'u');
    keys(client, "jjj");
    const auto before = top(client);

    press(client, '&');
    check(filter::active(client) && filter::block(client, 1) == std::size_t{0}, "& opens the filter on the selected block");
    check(filter::query(client, {.text = "warning|error", .regex = true}), "a regular expression filters");
    const auto request = transport.last<ReadPaneRows>();

    check(request.from == filter_block_row + 1 && request.count == filter_total - filter_rows - filter_block_row - 1, "the output's rows above the screen are asked for");
    answerRows(client, request);
    const auto& folds = client.findPane(1)->folds;

    check(folds.hides(21) && !folds.hides(22) && folds.hides(23) && !folds.hides(24) && folds.hides(25) && folds.hides(38), "only the lines that match are shown");
    check(filter::status(client).matches == 2 && filter::status(client).complete, "two lines matched, every row read");
    check(top(client) == filter_block_row, "the block's separator comes to the top");

    const auto copies = transport.count(ClientTag::copy_selection);

    press(client, 'Y');
    check(std::string_view{client.clipboard()} == "warning: x\nerror: y" && client.takeClipboardWrite() && transport.count(ClientTag::copy_selection) == copies, "Y copies the lines shown");

    check(filter::query(client, {.text = "error", .context = 1}), "a line of context");
    answerRows(client, transport.last<ReadPaneRows>());
    check(!folds.hides(23) && !folds.hides(24) && !folds.hides(25) && folds.hides(22) && folds.hides(26), "the match shows with a line before and after it");

    filter::close(client);
    check(!filter::active(client) && !folds.hides(21) && !folds.hides(26) && top(client) == before, "closing shows the whole output and takes the view back");
  }

  // A block keeps where, when and as whom its command ran after the message that brought it is
  // gone; the blocks an earlier runtime kept, which have no rows, stay apart from this
  // runtime's, which the keys step through.
  void blocksKeepTheirPlaceAndRestoredOnesStayApart() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openBlocks(client, transport);
    const ds::Array blocks{
        CommandBlock{.state = CommandBlockState::failed, .status = 1, .command = "make deploy", .started_ms = 1'700'000'000'000, .directory = "/srv/old", .host = "build", .user = "ci", .branch = "release", .restored = true},
        CommandBlock{.row = 10, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls", .started_ms = 1'700'000'100'000, .directory = "/home/ada/src/telar", .host = "laptop", .user = "ada", .branch = "main"},
        CommandBlock{.row = 40, .rows = 1, .state = CommandBlockState::succeeded, .command = "git log", .directory = "/home/ada/src/telar", .host = "laptop", .user = "ada", .branch = "main"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    // Another message takes the buffer the blocks were read from.
    deliver(client, PaneCwd{.pane_id = 1, .cwd = "/elsewhere/entirely/with/a/longer/path/than/before"});
    const auto& pane = *client.findPane(1);

    check(pane.blocks.size() == 2 && pane.blocks[0].command == "ls" && pane.blocks[0].directory == "/home/ada/src/telar" && pane.blocks[0].branch == "main" && pane.blocks[0].user == "ada" && pane.blocks[0].host == "laptop" && pane.blocks[0].started_ms == 1'700'000'100'000, "a block keeps its command's place after its message is gone");
    check(pane.restored.size() == 1 && pane.restored[0].command == "make deploy" && pane.restored[0].directory == "/srv/old" && pane.restored[0].branch == "release", "the restored block is kept apart, with its place");
    escape(client);
    control(client, 'u');
    control(client, 'u');
    control(client, 'u');
    check(client.selectedBlock(1) == std::size_t{0} && top(client) == 10, "stepping up stops at this runtime's first block");

    // The restored block's command goes back to the editor; this runtime never saw its rows.
    check(client.reuseRestored(1, 0, application::BlockReuse::edit) && prompt::line(client, 1)->text() == "make deploy", "a restored command goes back to the editor");
  }

  // Output no command printed is a block of its own: no prompt or command rows, its output from
  // its row to the next block's, stepped to, copied and filtered as any output.
  void backgroundOutputIsABlock() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};

    openBlocks(client, transport);
    const ds::Array blocks{
        CommandBlock{.row = 10, .rows = 1, .state = CommandBlockState::succeeded, .command = "sleep 1 &"},
        CommandBlock{.row = 20, .rows = 0, .state = CommandBlockState::background},
        CommandBlock{.row = 25, .rows = 1, .state = CommandBlockState::succeeded, .command = "ls"},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    const auto output = application::Session::blockRows(*client.findPane(1), 1);

    check(output.first == 20 && output.second == 25, "its output runs from its row to the next block's");
    escape(client);
    keys(client, "[[[[");
    check(client.selectedBlock(1) == std::size_t{1}, "the keys step to it");
    press(client, 'Y');
    const auto copied = transport.last<CopySelection>();

    check(copied.start_y == 20 && copied.end_y == 24, "Y copies its output");
    check(!client.reuseBlock({.pane_id = 1, .index = 1}, application::BlockReuse::run), "it has no command to run again");
  }

  // A job's report writes over the prompt row and the shell draws its prompt again below it,
  // unmarked: the background output still ends above the cursor's row.
  void backgroundOutputEndsAboveTheRedrawnPrompt() {
    SystemAllocator memory;
    Transport transport;
    TestSession client{memory, transport};
    constexpr std::uint16_t rows = 10;
    // The prompt flag is left on the row the job's report wrote over; the cursor is two below.
    constexpr std::uint16_t stale_prompt = 4;

    openFirstPane(client, transport);
    deliverScreen(client, rows, stale_prompt, stale_prompt + 2);
    editWithVim(client);
    const ds::Array blocks{
        CommandBlock{.row = 0, .rows = 1, .state = CommandBlockState::succeeded, .command = "sleep 1 &"},
        CommandBlock{.row = stale_prompt, .rows = 0, .state = CommandBlockState::background},
    };

    deliver(client, PaneBlocks{.pane_id = 1, .blocks = blocks});
    const auto output = application::Session::blockRows(*client.findPane(1), 1);

    check(output.first == stale_prompt && output.second == stale_prompt + 2, "the background output runs to the row the prompt is drawn on again");
  }

  const telar::testing::Case case_jump_back_with_one_jump_stays{"block_session.jump_back_with_one_jump_stays", jumpBackWithOneJumpStays};
  const telar::testing::Case case_tall_live_prompt_ends_the_last_output{"block_session.tall_live_prompt_ends_the_last_output", tallLivePromptEndsTheLastOutput};
  const telar::testing::Case case_reused_command_goes_to_the_editor{"block_session.reused_command_goes_to_the_editor", reusedCommandGoesToTheEditor};
  const telar::testing::Case case_marks_name_blocks{"block_session.marks_name_blocks", marksNameBlocks};
  const telar::testing::Case case_long_command_tells_of_its_end{"block_session.long_command_tells_of_its_end", longCommandTellsOfItsEnd};
  const telar::testing::Case case_blocks_keep_their_place_and_restored_ones_stay_apart{"block_session.blocks_keep_their_place_and_restored_ones_stay_apart", blocksKeepTheirPlaceAndRestoredOnesStayApart};
  const telar::testing::Case case_background_output_is_a_block{"block_session.background_output_is_a_block", backgroundOutputIsABlock};
  const telar::testing::Case case_background_output_ends_above_the_redrawn_prompt{"block_session.background_output_ends_above_the_redrawn_prompt", backgroundOutputEndsAboveTheRedrawnPrompt};
  const telar::testing::Case case_filter_shows_only_the_matching_lines{"block_session.filter_shows_only_the_matching_lines", filterShowsOnlyTheMatchingLines};

}
