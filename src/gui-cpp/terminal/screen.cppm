module;
#include "cell_position.hpp"
#include "screen.hpp"

export module telar.gui.terminal.screen;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui {
using telar::gui::CellPosition;
using telar::gui::CellValue;
using telar::gui::FrameApplication;
using telar::gui::Screen;
}

