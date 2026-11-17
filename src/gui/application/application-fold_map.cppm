module;
#include "terminal/fold_map.hpp"

export module telar.gui.application:fold_map;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar::gui::application {
  using telar::gui::FoldMap;
}
