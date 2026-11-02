#include "application.hpp"
#include "machines/machine_row.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/link_status_geometry.hpp"
#include "projection.hpp"
#include "transport/runtime_link.hpp"
#include <QQuickWindow>
#include <QString>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qvariant.h>

namespace telar::gui::qt {

QVariantMap Application::runtimeLinkState() const {
  const auto &link = connection().link();
  const auto detail = link.failure().value_or(std::string_view{});

  return {{QStringLiteral("visible"), link.phase != MachinePhase::connected}, {QStringLiteral("headline"), toQString(link.headline().view())}, {QStringLiteral("detail"), toQString(detail)}, {QStringLiteral("hasDetail"), link.failure().has_value()}, {QStringLiteral("dimAlpha"), LinkStatusGeometry::dim_alpha}};
}

QVariantMap Application::runtimeLinkGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &workbench = session().workbenchGeometry();
  auto area = workbench.pixels(workbench.cellArea());
  area.x += display.geometry.terminal.x;
  area.y += display.geometry.terminal.y;
  const auto geometry = LinkStatusGeometry::measure(area, display.chrome, connection().link().failure().has_value());
  const auto local = [&](Rect region) {
    region.x -= area.x;
    region.y -= area.y;

    return toQRectF(region, density);
  };

  return {{QStringLiteral("bounds"), toQRectF(geometry.bounds, density)}, {QStringLiteral("headline"), local(geometry.headline)}, {QStringLiteral("detail"), local(geometry.detail)}};
}

}
