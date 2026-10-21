#pragma once

#include "../../telar_client/serializers/telar_frame.hpp"
#include <array>
#include <vector>

namespace workbench {
  struct TerminalCell {
    static constexpr std::size_t text_capacity = 16;
    telar::CellStyle style;
    telar::CellWidth width = telar::CellWidth::single;
    std::array<char, text_capacity> text{};
    std::uint8_t length = 0;
  };

  // Owns decoded cells; no views into transport storage survive apply().
  struct TerminalScreen {
    std::uint64_t frame = 0;
    std::uint64_t revision = 0;
    std::uint16_t columns = 0, rows = 0;
    telar::Cursor cursor;
    telar::Mouse mouse;
    telar::InputModes modes;
    telar::Scroll scroll;
    std::vector<TerminalCell> cells;
    std::vector<std::uint64_t> revisions;
    std::vector<telar::Byte> row_flags;
    bool connected = false;

    bool apply(const telar::PaneFrame &value);
    void discard();
  };
} // namespace workbench
