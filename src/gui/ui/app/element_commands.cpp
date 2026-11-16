#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/components/element_slots.hpp"
#include "ui/config/configuration_source.hpp"
#include <QString>
#include <QStringLiteral>
#include <QVariantMap>
#include <cstddef>
#include <exception>
#include <stdexcept>

import telar.gui.components.configuration;
import telar.gui.links.cell_links;

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
      fail(std::runtime_error{message.toStdString()});
    });
  }

  void ApplicationController::refreshElementBars() {
    components_.refreshElementBars({
        {QStringLiteral("workspace"), workspaces_.context().value(QStringLiteral("name"))},
        {QStringLiteral("machine"), machineContext().value(QStringLiteral("label"))},
        {QStringLiteral("tab_count"), tabs_.count()},
        {QStringLiteral("sidebar_visible"), sidebarVisible()},
    });
  }

  void ApplicationController::activateElement(const QString& slot, const QString& key, const QString& revision, int element) {
    const auto* instance = element_slots_.find(slot, key);
    if (instance == nullptr || !instance->rendered || QString::number(instance->revision) != revision || element < 0 || static_cast<std::size_t>(element) >= instance->rendered->elements.size()) {
      return;
    }

    // Hold the content: a render may replace the instance while the click runs.
    const auto rendered = instance->rendered;
    const auto& node = rendered->elements[static_cast<std::size_t>(element)];

    try {
      if (node.callback != components::Element::none) {
        const auto hold = key_bindings_.hold();

        configuration_source_.invokeElement(instance->id, node.callback, components_.context(), instance->item, [this, hold](LuaOutcome<ConfigurationSource::Effects> outcome) {
          luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
            applyEffects(**outcome.value);
          });

          // The function may have changed state any slot reads.
          element_slots_.invalidate();
        });
      } else if (node.action != components::Element::none && node.action < rendered->bindings.size()) {
        static_cast<void>(runBinding(rendered->bindings[node.action], &rendered->actions));
      } else if (const auto url = rendered->view(node.url); !url.empty()) {
        if (const auto target = LinkTarget::fromUri(url)) {
          static_cast<void>(links_.open(*target));
        }
      }
    } catch (const std::exception& error) {
      fail(error);
    }
  }

}
