#include "application.hpp"
#include "application/workbench_geometry.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/metrics.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/history_modal_geometry.hpp"
#include "projection.hpp"
#include "sidebar_projection.hpp"
#include "typography_projection.hpp"
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <utility>

namespace telar::gui::qt {

DisplayMetrics Application::displayMetrics(qreal density) const {
  return DisplayMetrics::resolve(configuration(), viewport_, cell_metrics_, density);
}

QVariantMap Application::machineContext() const {
  return {
      {QStringLiteral("label"), toQString(machines_.row(machines_.active()).label.view())},
      {QStringLiteral("attention"), machines_.attentionElsewhere()},
  };
}

qreal Application::chromeRatio() const {
  return configuration().font.size / ChromeMetrics::reference_font_size;
}

qreal Application::chromeTextScale() const {
  return configuration().chrome_scale;
}

QVariantMap Application::windowGeometry() const {
  const auto &font = configuration().font;
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &geometry = display.geometry;
  const auto &chrome = display.chrome;
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

QVariantMap Application::sidebarGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &geometry = display.geometry;

  const Rect area{
      .width = geometry.sidebar.width,
      .height = geometry.sidebar.height,
  };

  auto result = sidebarRegionsRecord(area, display, static_cast<std::size_t>(workspaces_.rowCount()), machines_.count() > 1);
  result.insert(QStringLiteral("typography"), chromeTypographyRecord(display, configuration().font));

  return result;
}

HistoryModalMetrics Application::historyMetrics() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);

  return {
      .viewport = {.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)},
      .chrome = display.chrome,
      .cell_height = static_cast<float>(terminal_grid_.cell_height_px),
  };
}

QVariantMap Application::historyGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto metrics = historyMetrics();
  const auto geometry = HistoryModalGeometry::measure(metrics, session().historyBrowser().state().inspecting);
  const auto local = [&](Rect area) {
    area.x -= geometry.bounds.x;
    area.y -= geometry.bounds.y;

    return toQRectF(area, density);
  };

  return {
      {QStringLiteral("bounds"), toQRectF(geometry.bounds, density)},
      {QStringLiteral("header"), local(geometry.header)},
      {QStringLiteral("results"), local(geometry.results)},
      {QStringLiteral("inspection"), local(geometry.inspection)},
      {QStringLiteral("search"), local(geometry.search)},
      {QStringLiteral("footer"), local(geometry.footer)},
      {QStringLiteral("inspectionContent"), local(geometry.inspectionContent(metrics.chrome))},
      {QStringLiteral("inspectionActions"), local(geometry.inspectionActions(metrics.chrome))},
      {QStringLiteral("rowHeight"), geometry.row_height / density},
      {QStringLiteral("groupHeight"), geometry.group_height / density},
      {QStringLiteral("compact"), geometry.compact},
      {QStringLiteral("density"), density},
  };
}

void Application::synchronizeWorkbenchGeometry() {
  const auto display = displayMetrics(terminal_grid_.scale);
  const auto &configuration = this->configuration();
  const auto &geometry = display.geometry;
  auto grid = terminal_grid_;
  grid.scale = 1;

  const WorkbenchGeometry workbench{
      .area = {.width = geometry.terminal.width, .height = geometry.terminal.height},
      .grid = grid,
      .layout_metrics = {.gap = static_cast<std::uint8_t>(configuration.pane_gaps)},
  };

  const auto columns = std::clamp(std::floor(geometry.terminal.width / static_cast<float>(grid.cell_width_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max()));
  for (auto &client : clients_) {
    if (client) {
      (*client)->session.setWorkbenchGeometry(workbench);
      (*client)->session.setHostColumns(static_cast<std::uint16_t>(columns));
    }
  }
}

}
