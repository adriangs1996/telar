#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "telar_client/serializers/telar_cells.hpp"
#include <algorithm>
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include <limits>
#include "projection.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <QQuickWindow>
#include <QString>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qvariant.h>



import telar.gui.machines.picker;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.transport.runtime_link;

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
