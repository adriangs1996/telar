#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/terminal_size.hpp"
#include "application.hpp"
#include "projection.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <QQuickWindow>
#include <QString>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qvariant.h>
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>

import telar.gui.machines.picker;
import telar.gui.presentation.suggestion_geometry;

namespace telar::gui::qt {

  QVariantMap Application::runtimeLinkState() const {
    const auto& link = connection().link();
    const auto detail = link.failure().value_or(std::string_view{});

    return {{QStringLiteral("visible"), link.phase != MachinePhase::connected}, {QStringLiteral("headline"), toQString(link.headline().view())}, {QStringLiteral("detail"), toQString(detail)}, {QStringLiteral("hasDetail"), link.failure().has_value()}, {QStringLiteral("dimAlpha"), LinkStatusGeometry::dim_alpha}};
  }

  QVariantMap Application::runtimeLinkGeometry() const {
    const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto display = displayMetrics(density);
    const auto& workbench = session().workbenchGeometry();
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
