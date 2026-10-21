#include "terminal_screen.hpp"
#include <algorithm>

namespace workbench {
  void TerminalScreen::discard() {
    frame = 0;
    columns = rows = 0;
    connected = false;
    cursor = {};
    scroll = {};
    std::vector<TerminalCell>().swap(cells);
    std::vector<std::uint64_t>().swap(revisions);
    std::vector<telar::Byte>().swap(row_flags);
    ++revision;
  }

  bool TerminalScreen::apply(const telar::PaneFrame &value) {
    if (value.base_frame_id != 0 &&
        (value.base_frame_id != frame || columns != value.cols || rows != value.rows)) {
      return false;
    }

    columns = value.cols;
    rows = value.rows;
    cells.resize(static_cast<std::size_t>(columns) * rows);
    revisions.resize(rows);
    row_flags.resize(rows);
    ++revision;

    for (const auto &span : value.spans) {
      auto reader = span.reader();
      auto index = span.start;

      while (const auto cell = reader.next()) {
        auto &owned = cells[index];
        owned.style = cell->style;
        owned.width = cell->width;
        owned.length = static_cast<std::uint8_t>(cell->text.size());
        std::copy(cell->text.begin(), cell->text.end(), owned.text.begin());
        revisions[index / columns] = revision;
        ++index;
      }
    }

    if (value.text_metadata) {
      std::copy(value.text_metadata->row_flags.begin(),
                value.text_metadata->row_flags.end(),
                row_flags.begin());
    }

    frame = value.frame_id;
    cursor = value.cursor;
    mouse = value.mouse;
    modes = value.input_modes;
    scroll = value.scroll;
    connected = true;
    return true;
  }
} // namespace workbench
