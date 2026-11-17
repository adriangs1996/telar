#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include <cstdint>
#include <exception>
#include <variant>

import telar.gui.config.plugin_effects;

namespace telar::gui::qt {

  void ApplicationController::initializePlugins() {
    connect(&plugins_, &PluginRunner::finished, this, [this](const PluginEffects& effects) {
      try {
        status_.clear();
        commands_.applyPluginEffects(effects);
        refresh();
      } catch (const std::exception& error) {
        status_.fail(error);
      }
    });
    connect(&plugins_, &PluginRunner::failed, &status_, &WindowStatus::report);
  }

}
