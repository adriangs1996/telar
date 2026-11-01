#include "pick_controller.hpp"
#include "application.hpp"
#include "component_surface_state.hpp"
#include "components/invocation.hpp"
#include "configuration_source.hpp"
#include "machine_client.hpp"
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <chrono>
#include <cstddef>
#include <exception>
#include <utility>

namespace telar::gui::qt {

void Application::initializePicks() {
  connect(&configuration_source_, &ConfigurationSource::changed, this, &Application::closeComponentPick);
  connect(this, &Application::machineChanged, this, &Application::closeComponentPick);
  connect(this, &Application::dialogChanged, this, [this] {
    if (!dialog_.isEmpty()) {
      closeComponentPick();
    }
  });
}

PickOwner Application::pickOwner() const {
  const auto &client = clientAt(machines_.active());

  return {.source = client.key, .runtime = client.runtime_generation, .generation = configuration_source_.configurationGeneration()};
}

bool Application::pickOwnerCurrent(const PickOwner &owner) const {
  return componentCommandCurrent(owner.generation, owner.source, owner.runtime);
}

components::Context Application::pickContext() const {
  return componentContext();
}

void Application::pickCommitted() {
  const auto now = ComponentSlotState::Clock::now();
  for (auto &bar : component_surfaces_.bars) {
    bar.next = now;
  }

  if (component_surfaces_.open_panel) {
    component_surfaces_.panel.next = now;
  }

  component_timer_.start(std::chrono::milliseconds{0});
}

void Application::pickFailed(const QString &message) {
  error_ = message;
  emit stateChanged();
}

void Application::openComponentPick(std::size_t index) {
  if (attachment_modal_active_) {
    return;
  }

  if (!dialog_.isEmpty()) {
    execute(Action::cancel);
  }

  if (!pick_controller_.isOpen()) {
    component_pick_return_focus_ = window_ != nullptr ? window_->activeFocusItem() : nullptr;
  }

  interruptBindings();
  pick_controller_.open(index);
}

QVariantMap Application::componentPick() const {
  return pick_controller_.state();
}

void Application::closeComponentPick() {
  const bool open = pick_controller_.isOpen();
  pick_controller_.close();
  if (open) {
    restoreComponentPickFocus();
  } else {
    component_pick_return_focus_.clear();
  }
}

void Application::restoreComponentPickFocus() {
  const auto target = std::exchange(component_pick_return_focus_, {});
  if (component_surfaces_.open_panel && component_surfaces_.generation == configuration_source_.configurationGeneration()) {
    if (target != nullptr && target->window() == window_ && target->isVisible() && target->isEnabled()) {
      target->forceActiveFocus(Qt::OtherFocusReason);
    }

    return;
  }

  restoreTerminalFocus();
}

void Application::filterComponentPick(const QString &query) {
  pick_controller_.filter(query);
}

void Application::chooseComponentPick(int row, const QString &identity) {
  try {
    pick_controller_.choose(row, identity);
    if (!pick_controller_.isOpen()) {
      restoreComponentPickFocus();
    }
  } catch (const std::exception &error) {
    pickFailed(QString::fromUtf8(error.what()));
  }
}

}
