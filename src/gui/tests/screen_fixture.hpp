#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QtCore/qchar.h>
#include <cstddef>
#include <cstdint>
#include <span>

#pragma once

import telar.gui.foundation.terminal;
import telar.gui.application;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace telar::gui::test {

  enum class ScreenTextLayout : std::uint8_t {
    physical,
    logical,
  };

  inline application::terminal::links::LinkGrid screenGrid(const Screen<Memory>& screen) {
    return {.cells = screen.cells(), .columns = screen.columns(), .rows = screen.rows(), .scroll = screen.scroll(), .row_flags = screen.rowFlags()};
  }

  inline QString screenText(const Screen<Memory>& screen, ScreenTextLayout layout = ScreenTextLayout::physical) {
    QString text;
    const auto grid = screenGrid(screen);

    for (std::size_t row = 0; row < screen.rows(); ++row) {
      const auto cells = screen.row(row);
      const auto padding = layout == ScreenTextLayout::logical && (screen.rowFlags(row) & static_cast<telar::Byte>(telar::RowFlag::wide_padding)) != 0;

      for (const auto& cell : cells.first(cells.size() - static_cast<std::size_t>(padding))) {
        text += qt::toQString(cell.utf8());
      }

      const auto end = (row + 1) * screen.columns();
      if (layout == ScreenTextLayout::physical || end == 0 || !grid.next(end - 1)) {
        text += QLatin1Char('\n');
      }
    }

    return text;
  }

}
