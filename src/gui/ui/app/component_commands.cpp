#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include <QPointF>
#include <QtCore/qscopeguard.h>
#include <exception>
#include <utility>

import telar.gui.links.cell_links;

namespace telar::gui::qt {

  void ApplicationController::initializeComponents() {
    connect(this, &ApplicationController::configurationChanged, &components_, &ComponentsController::configure);
    connect(&machines_, &MachinesCoordinator::changed, &components_, &ComponentsController::reset);
    connect(&dialogs_, &Dialogs::changed, this, [this] {
      if (store_.dialog().kind != Dialog::none && components_.panelOpen()) {
        components_.closePanel();
      }
    });

    connect(&components_, &ComponentsController::failed, &status_, &WindowStatus::report);
    connect(&components_, &ComponentsController::bindingRequested, this, [this](const BindingAction& action, const ConfigurationSource::Actions& actions, QPointF anchor) {
      try {
        const auto previous = std::exchange(component_action_anchor_, anchor);
        const auto restore = qScopeGuard([&] {
          component_action_anchor_ = previous;
        });

        static_cast<void>(runBinding(action, &actions));
      } catch (const std::exception& error) {
        status_.fail(error);
      }
    });

    connect(&components_, &ComponentsController::linkRequested, this, [this](const LinkTarget& target) {
      static_cast<void>(links_.open(target));
    });

    connect(&components_, &ComponentsController::focusRestoreRequested, this, &ApplicationController::restoreTerminalFocus);
  }

  void ApplicationController::initializePicks() {
    connect(&configuration_source_, &ConfigurationSource::changed, &components_, &ComponentsController::closePick);
    connect(&machines_, &MachinesCoordinator::changed, &components_, &ComponentsController::closePick);
    connect(&dialogs_, &Dialogs::changed, this, [this] {
      if (store_.dialog().kind != Dialog::none) {
        components_.closePick();
      }
    });
  }

  void ApplicationController::openComponentPick(std::size_t index) {
    if (attachments_.modalOpen()) {
      return;
    }

    if (store_.dialog().kind != Dialog::none) {
      execute(window_actions::Action::cancel);
    }

    components_.rememberPickFocus();
    interruptBindings();
    components_.openPick(index);
  }

}
