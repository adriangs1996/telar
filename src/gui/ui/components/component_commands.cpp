#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "component_projection.hpp"
#include "ui/app/application_controller.hpp"
#include <QPointF>
#include <QString>
#include <QtCore/qscopeguard.h>
#include <exception>
#include <optional>
#include <string_view>
#include <utility>

import telar.gui.links.cell_links;

namespace telar::gui::qt {

  void ApplicationController::initializeComponents() {
    connect(this, &ApplicationController::configurationChanged, &components_, &ComponentsController::configure);
    connect(this, &ApplicationController::machineChanged, &components_, &ComponentsController::reset);
    connect(this, &ApplicationController::dialogChanged, this, [this] {
      if (store_.dialog().kind != Dialog::none && components_.panelOpen()) {
        components_.closePanel();
      }
    });
    connect(&components_, &ComponentsController::failed, this, &ApplicationController::reportFailure);
  }

  void ApplicationController::initializePicks() {
    connect(&configuration_source_, &ConfigurationSource::changed, this, &ApplicationController::closeComponentPick);
    connect(this, &ApplicationController::machineChanged, this, &ApplicationController::closeComponentPick);
    connect(this, &ApplicationController::dialogChanged, this, [this] {
      if (store_.dialog().kind != Dialog::none) {
        closeComponentPick();
      }
    });
  }

  void ApplicationController::activateComponent(int source, int node, const QString& generation, const QString& revision, const QPointF& anchor) {
    if (const auto pressed = components_.activation(source, node, generation, revision)) {
      activateComponentAction(pressed->action, pressed->url, pressed->identity, anchor, *pressed->actions);
    }
  }

  void ApplicationController::activateComponentAction(std::optional<BindingAction> action, std::string_view url, const QString& identity, const QPointF& anchor, const ConfigurationSource::Actions& resolved) {
    try {
      const auto named = action && action->kind == BindingActionKind::extended ? configuration_source_.namedAction(*action, &resolved) : std::nullopt;
      if (identity != componentActionIdentity(action, url, named)) {
        return;
      }

      if (action) {
        const auto previous = std::exchange(component_action_anchor_, anchor);
        const auto restore = qScopeGuard([&] {
          component_action_anchor_ = previous;
        });

        static_cast<void>(runBinding(*action, &resolved));
      } else if (!url.empty()) {
        if (const auto target = LinkTarget::fromUri(url)) {
          static_cast<void>(openLink(*target));
        }
      }
    } catch (const std::exception& error) {
      fail(error);
    }
  }

  void ApplicationController::openComponentPick(std::size_t index) {
    if (attachments_.modalOpen()) {
      return;
    }

    if (store_.dialog().kind != Dialog::none) {
      execute(Action::cancel);
    }

    if (!components_.pickOpen()) {
      component_pick_return_focus_ = window_ != nullptr ? window_->activeFocusItem() : nullptr;
    }

    interruptBindings();
    components_.openPick(index);
  }

  void ApplicationController::closeComponentPick() {
    const bool open = components_.pickOpen();

    components_.closePick();
    if (open) {
      restoreComponentPickFocus();
    } else {
      component_pick_return_focus_.clear();
    }
  }

  // The panel the pick was opened over takes the keyboard back; without one, the terminal does.
  void ApplicationController::restoreComponentPickFocus() {
    const auto target = std::exchange(component_pick_return_focus_, {});

    if (components_.panelCurrent()) {
      if (target != nullptr && target->window() == window_ && target->isVisible() && target->isEnabled()) {
        target->forceActiveFocus(Qt::OtherFocusReason);
      }

      return;
    }

    restoreTerminalFocus();
  }

  void ApplicationController::chooseComponentPick(int row, const QString& identity) {
    try {
      components_.choosePick(row, identity);
      if (!components_.pickOpen()) {
        restoreComponentPickFocus();
      }
    } catch (const std::exception& error) {
      reportFailure(QString::fromUtf8(error.what()));
    }
  }

}
