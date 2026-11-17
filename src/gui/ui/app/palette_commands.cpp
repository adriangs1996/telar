#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"

import telar.gui.machines.picker;
import telar.gui.palette.navigation_label;

namespace telar::gui::qt {

  void ApplicationController::initializePalette() {
    connect(&palette_, &PaletteController::showRequested, this, [this] {
      showDialog(Dialog::palette);
    });

    connect(&palette_, &PaletteController::closeRequested, this, [this] {
      showDialog(Dialog::none);
    });

    connect(&palette_, &PaletteController::failed, &status_, &WindowStatus::report);
    connect(&palette_, &PaletteController::machineRequested, this, [this](MachinePickerTarget target, bool alternate) {
      applyInteraction([&] {
        chooseMachine(target, alternate);
      });
    });

    connect(&palette_, &PaletteController::actionRequested, this, [this](PaletteAction chosen) {
      const auto action = static_cast<window_actions::Action>(chosen.value);

      applyInteraction([&] {
        showDialog(Dialog::none);
        if (!executeNavigation(action, {}) && !executePane(action, 0)) {
          executeWindowAction(action);
        }
      });
    });
  }

  void ApplicationController::showPalette(PaletteMode mode) {
    palette_.open(mode);
    showDialog(Dialog::palette);
  }

}
