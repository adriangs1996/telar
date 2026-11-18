#include <ghostty/vt.h>

import std;
import telar.base.memory.allocators;
import telar.runtime.terminal.ghostty;
import telar.runtime.terminal.kitty;
import telar.runtime.terminal.text_reader;
import telar.vocabulary;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr TerminalSize size{80, 24, 9, 18};

  std::span<const Byte> bytes(std::string_view value) {
    return {reinterpret_cast<const Byte*>(value.data()), value.size()};
  }

  // A terminal whose cursor follows the images a program places, as a terminal that
  // does not draw them must so the text after an image lands where it would.
  struct CursorTerminal {
    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter{system};
    Terminal terminal{adapter, size, TerminalPurpose::separate_media};
    GraphicsCursor cursor;

    void feed(std::string_view input) {
      cursor.feed(terminal.handle(), bytes(input), size);
    }

    std::pair<std::uint16_t, std::uint16_t> position() {
      std::uint16_t x = 0;
      std::uint16_t y = 0;

      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_X, &x));
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y));
      return {x, y};
    }
  };

  using Position = std::pair<std::uint16_t, std::uint16_t>;

  // A delete ends a chunked upload: its last chunk then places nothing. Deleting every
  // image (`d=A`) forgets their sizes, so placing one of them later places nothing, while
  // deleting placements only (`d=a`) keeps them. An image sized by rows alone takes the
  // columns its aspect ratio gives it.
  void deleteAndRowsOnly() {
    constexpr std::string_view first_chunk = "\x1b_Ga=T,f=24,s=9,v=18,i=7,m=1;AAAA\x1b\\";
    constexpr std::string_view last_chunk = "\x1b_Gm=0;AAAA\x1b\\";

    {
      CursorTerminal pane;

      pane.feed(std::string{first_chunk} + std::string{last_chunk});
      check(pane.position() == Position{1, 0});
    }

    {
      CursorTerminal pane;

      pane.feed(std::string{first_chunk} + "\x1b_Ga=d,d=i,i=7\x1b\\" + std::string{last_chunk});
      check(pane.position() == Position{0, 0});
    }

    {
      CursorTerminal pane;

      pane.feed("\x1b_Ga=t,f=24,s=9,v=18,i=5;AAAA\x1b\\\x1b_Ga=p,i=5\x1b\\");
      check(pane.position() == Position{1, 0});
      pane.feed("\x1b_Ga=d,d=a\x1b\\\x1b_Ga=p,i=5\x1b\\");
      check(pane.position() == Position{2, 0});
      pane.feed("\x1b_Ga=d,d=A\x1b\\\x1b_Ga=p,i=5\x1b\\");
      check(pane.position() == Position{2, 0});
    }

    // 3 rows of 18 px make the 20x36 image 54 px high and 30 px wide: 4 columns.
    CursorTerminal pane;

    pane.feed("\x1b_Ga=T,f=24,s=20,v=36,i=3,r=3;AAAA\x1b\\");
    check(pane.position() == Position{4, 2});
  }

  const telar::testing::Case case_delete_and_rows_only{"kitty_cursor.delete_and_rows_only", deleteAndRowsOnly};

}
