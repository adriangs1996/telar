#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "link_status_controller.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QString>
#include <optional>
#include <string_view>

import telar.gui.machines.picker;
import telar.gui.application;

namespace telar::gui::qt {

  LinkStatusController::LinkStatusController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  QVariantMap LinkStatusController::state() const {
    const auto& link = store_.connection().link();
    const auto detail = link.failure().value_or(std::string_view{});

    return {{QStringLiteral("visible"), link.phase != MachinePhase::connected}, {QStringLiteral("headline"), toQString(link.headline().view())}, {QStringLiteral("detail"), toQString(detail)}, {QStringLiteral("hasDetail"), link.failure().has_value()}, {QStringLiteral("dimAlpha"), application::terminal::links::LinkStatusGeometry::dim_alpha}};
  }

  QVariantMap LinkStatusController::geometry() const {
    const auto density = display_.density;
    const auto& workbench = store_.session().workbenchGeometry();
    auto area = workbench.pixels(workbench.cellArea());

    area.x += display_.geometry.terminal.x;
    area.y += display_.geometry.terminal.y;
    const auto geometry = application::terminal::links::LinkStatusGeometry::measure(area, display_.chrome, store_.connection().link().failure().has_value());
    const auto local = [&](Rect region) {
      region.x -= area.x;
      region.y -= area.y;

      return toQRectF(region, density);
    };

    return {{QStringLiteral("bounds"), toQRectF(geometry.bounds, density)}, {QStringLiteral("headline"), local(geometry.headline)}, {QStringLiteral("detail"), local(geometry.detail)}};
  }

  void LinkStatusController::publish() {
    emit changed();
  }

  void LinkStatusController::setDisplay(const DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

}
