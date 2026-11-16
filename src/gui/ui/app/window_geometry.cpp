#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/fonts/typography_projection.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <utility>
#include <variant>

import telar.gui.layout.geometry;
import telar.gui.core.metrics;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection_geometry;

namespace telar::gui::qt {

  DisplayMetrics ApplicationController::displayMetrics(qreal density) const {
    return DisplayMetrics::resolve(configuration(), viewport_, cell_metrics_, density);
  }

  void ApplicationController::measureDisplay() {
    const auto display = displayMetrics(window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio());

    palette_.setDisplay(display);
    paths_.setDisplay(display);
    machine_prompt_.setDisplay(display);
    peek_.setDisplay(display);
    link_status_.setDisplay(display);
    attachments_.setDisplay(display);
    notifications_.setDisplay(display, terminal_grid_);
    machine_chrome_.setDisplay(display);
    sidebar_.setDisplay(display);
  }

  qreal ApplicationController::chromeRatio() const {
    return 1;
  }

  qreal ApplicationController::chromeTextScale() const {
    return configuration().chrome_scale;
  }

  QVariantMap ApplicationController::windowGeometry() const {
    const auto& font = configuration().font;
    const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto display = displayMetrics(density);
    const auto& geometry = display.geometry;
    const auto& chrome = display.chrome;
    auto typography = chromeTypographyRecord(display, font);

    typography.insert(QStringLiteral("grid"), QVariantMap{
                                                  {QStringLiteral("cellWidth"), terminal_grid_.cell_width_px / terminal_grid_.scale},
                                                  {QStringLiteral("cellHeight"), terminal_grid_.cell_height_px / terminal_grid_.scale},
                                                  {QStringLiteral("pixelHeight"), cell_metrics_.pixels / terminal_grid_.scale},
                                                  {QStringLiteral("baseline"), cell_metrics_.baseline},
                                                  {QStringLiteral("family"), toQString(font.family.view())},
                                                  {QStringLiteral("style"), toQString(font.style.view())},
                                              });

    return {
        {QStringLiteral("navigation"), toQRectF(geometry.navigation, density)},
        {QStringLiteral("sidebar"), toQRectF(geometry.sidebar, density)},
        {QStringLiteral("terminal"), toQRectF(geometry.terminal, density)},
        {QStringLiteral("status"), toQRectF(geometry.status, density)},
        {QStringLiteral("rail"), geometry.rail},
        {QStringLiteral("paneHeader"), chrome.pane_header / density},
        {QStringLiteral("paneBorder"), ChromeMetrics::logical_pane_border},
        {QStringLiteral("typography"), std::move(typography)},
    };
  }

  HistoryModalMetrics ApplicationController::historyMetrics() const {
    const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
    const auto display = displayMetrics(density);

    return {
        .viewport = {.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)},
        .chrome = display.chrome,
        .cell_height = static_cast<float>(terminal_grid_.cell_height_px),
    };
  }

  void ApplicationController::synchronizeWorkbenchGeometry() {
    const auto display = displayMetrics(terminal_grid_.scale);
    const auto& configuration = this->configuration();
    const auto& geometry = display.geometry;
    auto grid = terminal_grid_;

    grid.scale = 1;

    const WorkbenchGeometry workbench{
        .area = {.width = geometry.terminal.width, .height = geometry.terminal.height},
        .grid = grid,
        .layout_metrics = {
            .gap = static_cast<std::uint8_t>(configuration.pane_gaps),
            .header = static_cast<std::uint8_t>(std::clamp(std::ceil(display.chrome.pane_header / static_cast<float>(grid.cell_height_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint8_t>::max()))),
        },
    };

    const auto columns = std::clamp(std::floor(geometry.terminal.width / static_cast<float>(grid.cell_width_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max()));

    for (auto& client : store_.clients()) {
      if (client) {
        (*client)->session.setWorkbenchGeometry(workbench);
        (*client)->session.setHostColumns(static_cast<std::uint16_t>(columns));
      }
    }
  }

}
