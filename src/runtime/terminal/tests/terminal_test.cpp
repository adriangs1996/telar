#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <ghostty/vt.h>
#include <sys/mman.h>

import std;
import telar.base.memory.allocators;
import telar.runtime.terminal.control;
import telar.runtime.terminal.grid;
import telar.testing;
import telar.runtime.terminal.text_reader;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.runtime.terminal.ghostty;
import telar.base.text.utf8;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  std::string drain(Terminal& terminal) {
    std::string result;

    while (!terminal.responses().empty()) {
      const auto pending = terminal.responses();

      result.append(reinterpret_cast<const char*>(pending.data()), pending.size());
      terminal.consumeResponses(pending.size());
    }

    return result;
  }

  bool validUtf8(std::string_view text) {
    try {
      validateUtf8(text);
      return true;
    } catch (const EncodingError&) {
      return false;
    }
  }

  // A title the pane sets reaches clients as bounded UTF-8 text with no controls: DEL and C0
  // bytes are dropped, and a long title is cut between code points.
  void testTitleSanitized() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Terminal terminal{adapter, TerminalSize{80, 24, 0, 0}};
    std::string title{"a\x7f"
                      "b\x01"};

    for (std::size_t index = 0; index < 100; ++index) {
      title.append("\xe7\x95\x8c");
    }

    terminal.feed(bytes("\x1b]2;" + title + "\x1b\\"));
    terminal.refresh();
    const auto shown = terminal.effects.title();

    check(shown.starts_with("ab\xe7\x95\x8c") && shown.size() <= 256 && validUtf8(shown));
    check(std::ranges::none_of(shown, [](char byte) {
      return static_cast<Byte>(byte) < 0x20 || byte == 0x7f;
    }));
  }

  // A title report answers into the program's input, so it carries no control, 8-bit ones
  // (U+0080-U+009F) included: a title holding CSI cannot inject a sequence through it.
  void testTitleReportStripsControls() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Terminal terminal{adapter, TerminalSize{80, 24, 0, 0}};

    terminal.controlPolicy().title_report = true;
    terminal.feed(bytes("\x1b]2;a\xc2\x9b"
                        "31m\x7f\xc2\x85"
                        "b\xc2\xa0"
                        "c\x1b\\\x1b[21t"));
    check(drain(terminal) == "\x1b]la31mb\xc2\xa0"
                             "c\x1b\\");
  }

  void testTerminalStorage() {
    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 0, 0}};
    std::string history;

    for (std::size_t row = 0; row < 4096; ++row) {
      history += "retained terminal output\r\n";
    }

    terminal.feed(bytes(history));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows > terminal.screen.rows);

    terminal.feed(bytes("\x1b[?1049h"));
    std::size_t both_screen_bytes = 0;
    const auto allocations = budget.allocations();

    checkGhostty(ghostty_terminal_page_bytes(terminal.handle(), &both_screen_bytes));
    check(budget.allocations() == allocations);
    GhosttyTerminalScreen active{};

    checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &active));
    check(active == GHOSTTY_TERMINAL_SCREEN_ALTERNATE);
#if TELAR_DIAGNOSTICS
    const auto snapshot = terminal.storageMetrics();

    check(snapshot.page_bytes == both_screen_bytes && snapshot.screen_bytes == 80 * 24 * sizeof(ScreenCell));
#endif

    terminal.feed(bytes("\x1b[?1049l\x1b[3J"));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows == terminal.screen.rows);
    terminal.resize(TerminalSize{120, 40, 0, 0});
#if TELAR_DIAGNOSTICS
    check(terminal.storageMetrics().screen_bytes == 120 * 40 * sizeof(ScreenCell));
#endif
  }

  // `clear` erases the scrollback before the screen; Ghostty would move a screen ending in a prompt
  // back into it. ^L at a prompt, without ED 3, still keeps the screen in the scrollback.
  void testClearAtPrompt() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{40, 5, 0, 0}};
    std::string history;

    for (std::size_t row = 0; row < 20; ++row) {
      history += "output\r\n";
    }

    terminal.feed(bytes(history + "\x1b]133;A\x07$ \x1b]133;B\x07clear\r\n\x1b]133;C\x07"));
    terminal.feed(bytes("\x1b[3J\x1b[H\x1b[2J"));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows == terminal.screen.rows);

    terminal.feed(bytes("\x1b]133;A\x07$ \x1b]133;B\x07\x1b[H\x1b[2J"));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows > terminal.screen.rows);

    terminal.feed(bytes("\x1b[3Jprinted\r\n\x1b]133;A\x07$ \x1b]133;B\x07\x1b[H\x1b[2J"));
    terminal.refresh();
    check(terminal.screen.scroll.total_rows > terminal.screen.rows);
  }

  // The text a `PaneRows` reply holds on its row `index`, trailing spaces trimmed.
  std::string replyRow(const PaneRows& reply, std::size_t index) {
    std::string text;
    auto reader = reply.reader();
    std::size_t cell = 0;

    while (const auto next = reader.next()) {
      if (cell / reply.cols == index) {
        text.append(reinterpret_cast<const char*>(next->text.data()), next->text.size());
      }

      ++cell;
    }

    while (!text.empty() && text.back() == ' ') {
      text.pop_back();
    }

    return text;
  }

  // Rows keep their stable number, the rows dropped above them plus their row, while the
  // scrollback drops its oldest; a resize renumbers them under a new generation.
  void testScrollbackOrigin() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{40, 5, 0, 0}};
    const std::size_t limit = 1;

    checkGhostty(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit));
    const auto generation = terminal.scrollbackGeneration();

    check(terminal.followScrollback() == 0 && terminal.scrollbackTrimmed() == 0);

    std::size_t printed = 0;
    std::uint64_t dropped = 0;

    for (std::size_t batch = 0; batch < 4000 && terminal.scrollbackTrimmed() < 600; ++batch) {
      std::string lines;

      for (std::size_t line = 0; line < 8; ++line) {
        lines += "line " + std::to_string(printed++) + "\r\n";
      }

      terminal.feed(bytes(lines));
      dropped += terminal.followScrollback();
    }

    check(terminal.scrollbackTrimmed() > 0 && dropped == terminal.scrollbackTrimmed() && terminal.scrollbackGeneration() == generation);

    // Stable row N holds the line printed N-th.
    ScrollbackRows rows{memory};
    const auto trimmed = terminal.scrollbackTrimmed();
    const auto stable = trimmed + 3;
    const auto reply = rows.read(terminal, ReadPaneRows{.request_id = 1, .pane_id = 1, .from = stable, .count = 2});

    check(reply.from == stable && reply.rows == 2 && reply.cols == 40 && reply.trimmed == trimmed);
    check(replyRow(reply, 0) == "line " + std::to_string(stable) && replyRow(reply, 1) == "line " + std::to_string(stable + 1));
    Codec::validate(reply);

    // Rows already dropped are skipped; rows past the end are none.
    const auto clipped = rows.read(terminal, ReadPaneRows{.request_id = 2, .pane_id = 1, .from = trimmed - 1, .count = 3});

    check(clipped.from == trimmed && clipped.rows == 2 && replyRow(clipped, 0) == "line " + std::to_string(trimmed));
    const auto beyond = rows.read(terminal, ReadPaneRows{.request_id = 3, .pane_id = 1, .from = trimmed + 1'000'000, .count = 4});

    check(beyond.rows == 0 && !beyond.text_metadata && beyond.cells.empty());
    Codec::validate(beyond);

    // Rows on the live screen, nearer the bottom than a screen, come from the last full view.
    terminal.refresh();
    const auto last = trimmed + terminal.screen.scroll.total_rows - 2;
    const auto tail = rows.read(terminal, ReadPaneRows{.request_id = 4, .pane_id = 1, .from = last, .count = 5});

    check(tail.from == last && tail.rows == 2 && replyRow(tail, 0) == "line " + std::to_string(printed - 1));

    terminal.resize(TerminalSize{30, 5, 0, 0});
    check(terminal.scrollbackGeneration() == generation + 1 && terminal.followScrollback() == 0);
  }

  void testTerminal() {
    {
      SystemAllocator system;
      MemoryAdapter adapter{system};
      ConcurrentMemory& memory = adapter;
      Terminal terminal{memory, TerminalSize{80, 24, 9, 18}};

      for (const auto input : {"\x1b[?5522h", "\x1b[?5522l", "\x1b[?5522h", "\x1b"
                                                                            "c"}) {
        terminal.feed(bytes(input));
        terminal.refresh();
        check(terminal.screen.input_modes.paste_events == terminal.pasteEvents());
        check(terminal.pasteEvents() == std::string_view{input}.ends_with('h'));
      }
    }

    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      Terminal terminal{memory, TerminalSize{.cols = 40, .rows = 5, .cell_width_px = 0, .cell_height_px = 0}};

      terminal.feed(bytes("Hello \x1b[1;31mred\x1b[0m\r\n\xe7\x95\x8c e\xcc\x81"));
      terminal.refresh();
      const auto& screen = terminal.screen;

      check(screen.cells[0].text[0] == 'H');
      check(screen.cells[6].style.foreground.kind == CellColor::Kind::indexed);
      check(screen.cells[6].style.foreground.channels[0] == 1);
      check(screen.cells[6].style.flags == static_cast<std::uint16_t>(CellAttribute::bold));
      check(screen.cells[40].width == CellWidth::wide);
      check(screen.cells[41].width == CellWidth::continuation);
      check(screen.cells[43].length == 3);
      check(screen.cells[43].text[0] == 'e');
      check(screen.cells[43].text[1] == 0xcc);
      check(screen.cells[43].text[2] == 0x81);

      terminal.feed(bytes("\x1b[6n"));
      check(!terminal.responses().empty());
      check(terminal.responses()[0] == 0x1b);
      terminal.consumeResponses(terminal.responses().size());
      terminal.refresh();

      const auto allocations = budget.allocations();

      for (int iteration = 0; iteration < 100; ++iteration) {
        terminal.feed(bytes("\x1b[1;1HX"));
        terminal.refresh();
      }

      check(budget.allocations() == allocations);
      terminal.feed(bytes("\x1b]2;safe\x07\x1b]7;file://localhost/tmp/hello%20world\x07\x1b]52;c;aGVsbG8=\x07"));
      check(terminal.effects.title() == "safe");
      check(terminal.effects.cwd() == "/tmp/hello world");
      check(terminal.effects.clipboard.empty());
      check(!terminal.clipboardControl().route());
      terminal.feed(bytes("\x1b]9;4;1;42\x07"));
      check(terminal.effects.progress_state == PaneProgressState::set && terminal.effects.progress_percent == 42);
      const auto progress_revision = terminal.effects.progress_revision;

      terminal.feed(bytes("\x1b]9;4;1;42\x07"));
      check(terminal.effects.progress_revision == progress_revision);
      terminal.feed(bytes("\x1b]9;4;3\x07"));
      check(terminal.effects.progress_state == PaneProgressState::indeterminate && !terminal.effects.progress_percent);
      terminal.feed(bytes("\x1b]9;4;2;75\x07"));
      check(terminal.effects.progress_state == PaneProgressState::error && terminal.effects.progress_percent == 75);
      terminal.feed(bytes("\x1b]9;4;0\x07"));
      check(terminal.effects.progress_state == PaneProgressState::remove && !terminal.effects.progress_percent);
      terminal.resize(TerminalSize{.cols = 80, .rows = 24, .cell_width_px = 0, .cell_height_px = 0});
      terminal.refresh();
      check(terminal.screen.cells.size() == 80 * 24);
      const auto revision = terminal.screen.revision;

      terminal.resize(TerminalSize{80, 24, 0, 0});
      terminal.refresh();
      check(terminal.screen.revision == revision);
      terminal.resize(TerminalSize{80, 24, 8, 16});
      check(terminal.hasSize(TerminalSize{80, 24, 8, 16}));
      terminal.refresh();
      check(terminal.screen.revision > revision);
    }

    check(budget.liveBytes() == 0);

    std::uint64_t seed = 1;

    for (int iteration = 0; iteration < 10000; ++iteration) {
      seed = seed * 6364136223846793005ULL + 1;
      GhosttyStyleId style_id{};
      GhosttyCellWide width{};

      checkGhostty(ghostty_cell_get(seed, GHOSTTY_CELL_DATA_STYLE_ID, &style_id));
      checkGhostty(ghostty_cell_get(seed, GHOSTTY_CELL_DATA_WIDE, &width));
      check(style_id == cell_layout::style_id(seed));
      check(static_cast<std::uint64_t>(width) == cell_layout::wide(seed));
    }
  }

  // OSC 7 names the directory new panes and captured commands start in. A URI without a
  // path, a relative path, an oversized path or a bad escape leaves the last one in place:
  // `%00` in particular would hand C APIs a shorter, different directory.
  void testCwdRejectsMalformedUri() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Terminal terminal{adapter, TerminalSize{80, 24, 0, 0}};
    const std::string rejected[]{
        "file://host",
        "relative/directory",
        "file://localhost/" + std::string(4100, 'a'),
        "file://localhost/tmp/a%2",
        "file://localhost/tmp/%zz",
        "file://localhost/tmp/%1z",
        "file://localhost/tmp/a%00b",
    };

    for (const auto& uri : rejected) {
      terminal.feed(bytes("\x1b]7;file://localhost/tmp/start\x1b\\"));
      check(terminal.effects.cwd() == "/tmp/start");
      terminal.feed(bytes("\x1b]7;" + uri + "\x1b\\"));
      telar::testing::expect(terminal.effects.cwd() == "/tmp/start", uri.substr(0, 40));
    }
  }

  CellColor rgb(Byte red, Byte green, Byte blue) {
    return CellColor{.kind = CellColor::Kind::rgb, .channels = {red, green, blue}};
  }

  // The frame a client draws carries each cell's colours as the pane set them: direct RGB,
  // palette entries the pane redefined, the defaults it redefined, and the background of
  // erased cells. Text past the Basic Multilingual Plane keeps all four bytes.
  void testCellProjectionColors() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    constexpr TerminalSize size{10, 4, 0, 0};

    {
      Terminal terminal{adapter, size};

      terminal.feed(bytes("\x1b[38;2;1;2;3;48;2;4;5;6mA\x1b[0m\r\n"
                          "\x1b[48;5;9m\x1b[K\x1b[0m\r\n"
                          "\x1b[48;2;7;8;9m\x1b[K\x1b[0m\r\n"
                          "\xf0\x9f\x98\x80"));
      terminal.refresh();
      const auto& cells = terminal.screen.cells;

      check(cells[0].style.foreground == rgb(1, 2, 3) && cells[0].style.background == rgb(4, 5, 6));
      check(cells[10].style.background == CellColor{.kind = CellColor::Kind::indexed, .channels = {9, 0, 0}});
      check(cells[19].style.background == CellColor{.kind = CellColor::Kind::indexed, .channels = {9, 0, 0}});
      check(cells[20].style.background == rgb(7, 8, 9) && cells[29].style.background == rgb(7, 8, 9));
      check(cells[30].width == CellWidth::wide && cells[30].length == 4);
      check(std::ranges::equal(std::span{cells[30].text}.first(4), bytes("\xf0\x9f\x98\x80")));
      check(cells[31].width == CellWidth::continuation);
    }

    {
      Terminal terminal{adapter, TerminalSize{10, 4, 0, 0}};

      // A wide character that does not fit the last column moves to the next row.
      terminal.feed(bytes("xxxxxxxxx\xe7\x95\x8c"));
      terminal.refresh();
      const auto& cells = terminal.screen.cells;

      check(cells[9].length == 1 && cells[9].text[0] == ' ');
      check(cells[10].width == CellWidth::wide && cells[10].length == 3);
      check(std::ranges::equal(std::span{cells[10].text}.first(3), bytes("\xe7\x95\x8c")));
    }

    {
      Terminal terminal{adapter, size};

      terminal.feed(bytes("\x1b]4;1;rgb:ff/00/00\x1b\\\x1b]10;rgb:11/22/33\x1b\\\x1b]11;rgb:44/55/66\x1b\\\x1b[31mR\x1b[0mD"));
      terminal.refresh();
      const auto& cells = terminal.screen.cells;

      check(cells[0].style.foreground == rgb(0xff, 0, 0));
      check(cells[1].style.foreground == rgb(0x11, 0x22, 0x33) && cells[1].style.background == rgb(0x44, 0x55, 0x66));
    }

    Terminal terminal{adapter, size};

    terminal.feed(bytes("\x1b[?5hD"));
    terminal.refresh();
    check(terminal.screen.cells[0].style.foreground.kind == CellColor::Kind::rgb);
    check(terminal.screen.cells[0].style.background.kind == CellColor::Kind::rgb);
  }

  // The default colours a pane changes apply to the whole screen, rows already drawn
  // included: reverse video (DECSCNM, a visual bell) and OSC 10/11 recolour every cell
  // that uses them, not only the rows the pane writes next.
  void testDefaultColorsRepaint() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    constexpr TerminalSize size{10, 4, 0, 0};

    for (const std::string_view change : {"\x1b[?5h", "\x1b]10;rgb:11/22/33\x1b\\\x1b]11;rgb:44/55/66\x1b\\"}) {
      Terminal terminal{adapter, size};

      terminal.feed(bytes("D\r\n"));
      terminal.refresh();
      check(terminal.screen.cells[0].style.foreground.kind == CellColor::Kind::default_color);
      terminal.feed(bytes(change));
      terminal.refresh();
      telar::testing::expect(terminal.screen.cells[0].style.foreground.kind == CellColor::Kind::rgb, change.substr(2, 3));
      telar::testing::expect(terminal.screen.cells[0].style.background.kind == CellColor::Kind::rgb, change.substr(2, 3));
    }
  }

  const telar::testing::Case case_terminal{"terminal.terminal", testTerminal};
  const telar::testing::Case case_terminal_storage{"terminal.terminal_storage", testTerminalStorage};
  const telar::testing::Case case_clear_at_prompt{"terminal.clear_at_prompt", testClearAtPrompt};
  const telar::testing::Case case_scrollback_origin{"terminal.scrollback_origin", testScrollbackOrigin};
  const telar::testing::Case case_title_sanitized{"terminal.title_sanitized", testTitleSanitized};
  const telar::testing::Case case_title_report_strips_controls{"terminal.title_report_strips_controls", testTitleReportStripsControls};
  const telar::testing::Case case_cwd_rejects_malformed_uri{"terminal.cwd_rejects_malformed_uri", testCwdRejectsMalformedUri};
  const telar::testing::Case case_cell_projection_colors{"terminal.cell_projection_colors", testCellProjectionColors};
  const telar::testing::Case case_default_colors_repaint{"terminal.default_colors_repaint", testDefaultColorsRepaint};

}
