#pragma once

#include "../graphics/kitty_cursor.hpp"
#include "ghostty_handle.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

class GraphicsCursor {
public:
  void feed(GhosttyTerminal terminal, std::span<const Byte> bytes, TerminalSize size) {
    auto remaining = bytes;
    while (const auto command = scanner_.next(remaining)) {
      ghostty_terminal_vt_write(terminal, remaining.data(), command->end);
      if (const auto cells = cursor_.observe(*command, size.cell_width_px, size.cell_height_px)) {
        advance(terminal, *cells, size);
      }
      remaining = remaining.subspan(command->end);
    }
    ghostty_terminal_vt_write(terminal, remaining.data(), remaining.size());
  }

private:
  static void advance(GhosttyTerminal terminal, DisplayCells cells, TerminalSize size) {
    std::uint16_t x, y, top, bottom, left, right;
    const GhosttyTerminalData keys[] = {GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
    void *values[] = {&x, &y, &top, &bottom, &left, &right};
    checkGhostty(ghostty_terminal_get_multi(terminal, std::size(keys), keys, values, nullptr));

    const auto target_x = static_cast<std::uint64_t>(x) + cells.columns;
    const bool wraps = target_x >= size.cols;
    const auto requested_rows = static_cast<std::uint64_t>(cells.rows - 1) + wraps;
    const bool inside = y >= top && y <= bottom && x >= left && x <= right;
    const auto rows_before_scroll = inside ? bottom - y : 0;
    const auto rows = std::min<std::uint64_t>(requested_rows, rows_before_scroll + size.rows);
    for (std::uint64_t row = 0; row < rows; ++row) {
      if (ghostty_terminal_index(terminal) != GHOSTTY_SUCCESS) {
        break;
      }
    }

    const bool pending_wrap = false;
    const auto column = static_cast<std::uint16_t>(wraps ? 0 : target_x);
    checkGhostty(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CURSOR_PENDING_WRAP, &pending_wrap));
    checkGhostty(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CURSOR_X, &column));
  }

  KittyCommandScanner scanner_;
  KittyCursor cursor_;
};

}
