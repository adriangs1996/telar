module;
#include "terminal/cell_position.hpp"
#include "terminal/screen.hpp"

export module telar.gui.foundation.terminal:screen;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui::inline foundation::inline terminal {
  using telar::gui::CellPosition;
  using telar::gui::CellValue;
  using telar::gui::FrameApplication;
  using telar::gui::Screen;
}
