#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "cell_layout.hpp"
#include <cstring>
#include <cstddef>
#include <cstdint>
#include "telar_base/diagnostics/config.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <cassert>
#include <ghostty/vt.h>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.config;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;
import telar.runtime.tests.check;
import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

static void testTerminalStorage() {
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  Terminal terminal{memory, TerminalSize{80, 24, 0, 0}};
  std::size_t initial_bytes = 0;
  check(ghostty_terminal_page_bytes(nullptr, &initial_bytes) == GHOSTTY_INVALID_VALUE);
  check(ghostty_terminal_page_bytes(terminal.handle(), nullptr) == GHOSTTY_INVALID_VALUE);
  checkGhostty(ghostty_terminal_page_bytes(terminal.handle(), &initial_bytes));
  check(initial_bytes > 0);

  std::string history;
  for (std::size_t row = 0; row < 4096; ++row) {
    history += "retained terminal output\r\n";
  }
  terminal.feed(bytes(history));
  terminal.refresh();
  check(terminal.screen.scroll.total_rows > terminal.screen.rows);
  std::size_t retained_bytes = 0;
  checkGhostty(ghostty_terminal_page_bytes(terminal.handle(), &retained_bytes));
  check(retained_bytes > initial_bytes);

  terminal.feed(bytes("\x1b[?1049h"));
  std::size_t both_screen_bytes = 0;
  const auto allocations = memory.allocations();
  checkGhostty(ghostty_terminal_page_bytes(terminal.handle(), &both_screen_bytes));
  check(both_screen_bytes > retained_bytes && memory.allocations() == allocations);
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
  std::size_t cleared_bytes = 0;
  checkGhostty(ghostty_terminal_page_bytes(terminal.handle(), &cleared_bytes));
  check(cleared_bytes < both_screen_bytes && cleared_bytes > 0);
  terminal.resize(TerminalSize{120, 40, 0, 0});
#if TELAR_DIAGNOSTICS
  check(terminal.storageMetrics().screen_bytes == 120 * 40 * sizeof(ScreenCell));
#endif
}

void testTerminal() {
  testTerminalStorage();
  {
    SystemAllocator memory;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}};
    for (const auto input : {"\x1b[?5522h", "\x1b[?5522l", "\x1b[?5522h", "\x1b" "c"}) {
      terminal.feed(bytes(input));
      terminal.refresh();
      check(terminal.screen.input_modes.paste_events == terminal.pasteEvents());
      check(terminal.pasteEvents() == std::string_view{input}.ends_with('h'));
    }
  }
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};

  {
    Terminal terminal{memory, TerminalSize{.cols = 40,
                                           .rows = 5,
                                           .cell_width_px = 0,
                                           .cell_height_px = 0}};
    terminal.feed(bytes("Hello \x1b[1;31mred\x1b[0m\r\n\xe7\x95\x8c e\xcc\x81"));
    terminal.refresh();
    const auto &screen = terminal.screen;
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

    const auto allocations = memory.allocations();
    for (int iteration = 0; iteration < 100; ++iteration) {
      terminal.feed(bytes("\x1b[1;1HX"));
      terminal.refresh();
    }

    check(memory.allocations() == allocations);
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
    terminal.resize(TerminalSize{.cols = 80,
                                 .rows = 24,
                                 .cell_width_px = 0,
                                 .cell_height_px = 0});
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

  check(memory.liveBytes() == 0);

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
