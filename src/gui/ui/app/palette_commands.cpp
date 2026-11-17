#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"

import telar.gui.machines.picker;

namespace telar::gui::qt {

  void ApplicationController::initializePalette() {
    connect(&palette_, &PaletteController::showRequested, this, [this] {
      dialogs_.show(Dialog::palette);
    });

    connect(&palette_, &PaletteController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });

    connect(&palette_, &PaletteController::failed, &status_, &WindowStatus::report);
    connect(&palette_, &PaletteController::machineRequested, this, [this](MachinePickerTarget target, bool alternate) {
      commands_.interact([&] {
        roster_.choose(target, alternate);
      });
    });

    connect(&palette_, &PaletteController::actionRequested, this, [this](PaletteAction chosen) {
      const auto action = static_cast<window_actions::Action>(chosen.value);

      commands_.interact([&] {
        dialogs_.show(Dialog::none);
        commands_.perform(action);
      });
    });
  }

}
