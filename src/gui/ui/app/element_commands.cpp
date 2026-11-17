#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include <QString>
#include <QStringLiteral>
#include <QVariantMap>
#include <cstddef>
#include <exception>
#include <stdexcept>

import telar.gui.components.configuration;

namespace telar::gui::qt {

  void ApplicationController::initializeElements() {
    // A theme change shares this signal; only a new Lua generation owns new functions.
    connect(this, &ApplicationController::configurationChanged, this, [this] {
      element_slots_.adopt(configuration_source_.configurationGeneration());
    });

    connect(&configuration_source_, &ConfigurationSource::themeChanged, this, [this] {
      element_slots_.invalidate();
    });

    connect(&element_slots_, &ElementSlots::contentChanged, this, [this] {
      // Agent records skip unchanged activity; mod content is a change of its own.
      activity_.invalidate();
      refresh();
    });

    connect(&element_slots_, &ElementSlots::failed, this, [this](const QString& message) {
      status_.fail(std::runtime_error{message.toStdString()});
    });
  }

  void ApplicationController::refreshElementBars() {
    components_.refreshElementBars({
        {QStringLiteral("workspace"), workspaces_.context().value(QStringLiteral("name"))},
        {QStringLiteral("machine"), machines_.context().value(QStringLiteral("label"))},
        {QStringLiteral("tab_count"), tabs_.count()},
        {QStringLiteral("sidebar_visible"), display_.sidebarVisible()},
    });
  }

}
