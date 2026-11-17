#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "window_display.hpp"
#include "core/terminal_size.hpp"
#include "platform/window.hpp"
#include "ui/foundation/fonts/typography_projection.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <utility>

import telar.gui.layout.geometry;
import telar.gui.core.metrics;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection_geometry;

namespace telar::gui::qt {

  WindowDisplay::WindowDisplay(Store& store, ConfigurationSource& configuration, QObject* parent)
      : QObject(parent),
        store_(store),
        configuration_(configuration) {}

  void WindowDisplay::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  qreal WindowDisplay::density() const {
    return window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  }

  const Configuration& WindowDisplay::configuration() const noexcept {
    return store_.session().configuration();
  }

  const CellMetrics& WindowDisplay::cell() const noexcept {
    return cell_metrics_;
  }

  const TerminalGrid& WindowDisplay::grid() const noexcept {
    return terminal_grid_;
  }

  ResolvedFont WindowDisplay::resolveFont(qreal scale) {
    return configuration_.resolveFont(configuration().font, scale);
  }

  void WindowDisplay::publish() {
    layoutWorkbench();
    emit changed();
  }

  DisplayMetrics WindowDisplay::metrics(qreal density) const {
    return DisplayMetrics::resolve(configuration(), viewport_, cell_metrics_, density);
  }

  qreal WindowDisplay::chromeRatio() const {
    return 1;
  }

  qreal WindowDisplay::chromeTextScale() const {
    return configuration().chrome_scale;
  }

  QVariantMap WindowDisplay::geometry() const {
    const auto& font = configuration().font;
    const auto density = this->density();
    const auto display = metrics(density);
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

  HistoryModalMetrics WindowDisplay::historyMetrics() const {
    const auto density = this->density();
    const auto display = metrics(density);

    return {
        .viewport = {.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)},
        .chrome = display.chrome,
        .cell_height = static_cast<float>(terminal_grid_.cell_height_px),
    };
  }

  void WindowDisplay::layoutWorkbench() {
    const auto display = metrics(terminal_grid_.scale);
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

  void WindowDisplay::setSidebarWidth(qreal width) {
    store_.session().setSidebarWidth(static_cast<float>(std::clamp(width, qreal{Configuration::minimum_sidebar_width}, qreal{Configuration::maximum_sidebar_width})));
    publish();
  }

  void WindowDisplay::measureFont() {
    const auto scale = density();
    const auto resolved = resolveFont(scale);
    const auto& font = resolved.font;

    cell_metrics_.width = static_cast<float>(font.cell.width());
    cell_metrics_.height = static_cast<float>(font.cell.height());
    cell_metrics_.baseline = static_cast<float>(font.baseline);
    cell_metrics_.pixels = resolved.grid.pixel_height;
    terminal_grid_ = {.cell_width_px = resolved.grid.width, .cell_height_px = resolved.grid.height, .scale = scale};
  }

  bool WindowDisplay::resize(qreal width, qreal height) {
    constexpr qreal maximum_dimension = std::numeric_limits<std::uint16_t>::max();

    if (!std::isfinite(width) || !std::isfinite(height)) {
      return false;
    }

    const Viewport next{.width = static_cast<std::uint32_t>(std::clamp(width, 0.0, maximum_dimension)), .height = static_cast<std::uint32_t>(std::clamp(height, 0.0, maximum_dimension)), .scale = 1};
    if (viewport_ != next) {
      store_.session().invalidateView();
      viewport_ = next;

      return true;
    }

    return false;
  }

  bool WindowDisplay::sidebarVisible() const {
    return store_.session().configuration().sidebar_visible;
  }

  qreal WindowDisplay::sidebarWidth() const {
    return store_.session().configuration().sidebar_width;
  }

  bool WindowDisplay::workspaceListCollapsed() const {
    return store_.session().workspaceListCollapsed();
  }

  qreal WindowDisplay::windowControls() const {
    return window_ == nullptr ? 0 : platform::windowControls(*window_);
  }

}
