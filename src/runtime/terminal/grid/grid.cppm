module;

export module telar.runtime.terminal.grid;

import std;
import telar.ghostty.vt;
import telar.runtime.terminal.control;
import telar.runtime.terminal.ghostty;

// The fields of a packed GhosttyCell, generated from the libghostty-vt manifest.
export namespace telar::runtime::cell_layout {

#include "cell_layout.inc"

}

export namespace telar::runtime {

  // Whether a cell shows a character: a codepoint or a grapheme, not empty space.
  [[tbc::hot_path]] inline bool cellHasText(GhosttyCell cell) noexcept {
    const auto content = cell_layout::content_tag(cell);

    return (content == GHOSTTY_CELL_CONTENT_CODEPOINT || content == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME) && cell_layout::codepoint(cell) != 0;
  }

  // The grid reference of a point of the terminal's screen, viewport or history.
  [[tbc::hot_path]] inline GhosttyGridRef gridReference(GhosttyTerminal terminal, GhosttyPointTag tag, GhosttyPointCoordinate coordinate) {
    auto result = ghosttySized<GhosttyGridRef>();

    checkGhostty(ghostty_terminal_grid_ref(terminal, GhosttyPoint{.tag = tag, .value = {.coordinate = coordinate}}, &result));
    return result;
  }

  // The rows the terminal holds, its scrollback included.
  [[tbc::hot_path]] inline std::size_t totalRows(GhosttyTerminal terminal) {
    std::size_t rows = 0;

    checkGhostty(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows));
    return rows;
  }

}
