#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_cells.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <stdexcept>
#include <initializer_list>
#include "projection.hpp"
#include "sidebar_projection.hpp"
#include "typography_projection.hpp"
#include "machine_client.hpp"
#include "resident_fonts.hpp"
#include "window_font_catalog.hpp"
#include "../core/memory.hpp"
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <utility>



import telar.gui.application.sound_playback;
import telar.gui.application.workspace_replica;
import telar.gui.fonts.face;
import telar.gui.fonts.row_text_layout;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.core.metrics;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection_geometry;

namespace telar::gui::qt {

DisplayMetrics Application::displayMetrics(qreal density) const {
  return DisplayMetrics::resolve(configuration(), viewport_, cell_metrics_, density);
}

bool Application::machineListCollapsed() const noexcept {
  return machine_list_collapsed_;
}

int Application::machineCount() const noexcept {
  return static_cast<int>(machines_.count());
}

// The active machine is named in the top bar; the sidebar lists the others.
SidebarMachines Application::sidebarMachines() const noexcept {
  const auto count = machines_.count();

  return {.shown = count > 1, .rows = count > 1 && !machine_list_collapsed_ ? count - 1 : 0};
}

void Application::toggleMachineList() {
  machine_list_collapsed_ = !machine_list_collapsed_;
  sidebar_machines_ = sidebarMachines();
  emit sidebarGeometryChanged();
}

QVariantMap Application::machineContext() const {
  return {
      {QStringLiteral("label"), toQString(machines_.row(machines_.active()).label.view())},
      {QStringLiteral("attention"), machines_.attentionElsewhere()},
  };
}

qreal Application::chromeRatio() const {
  return 1;
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

  auto result = sidebarRegionsRecord(area, display, static_cast<std::size_t>(workspaces_.rowCount()), sidebarMachines());
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
      .layout_metrics = {
          .gap = static_cast<std::uint8_t>(configuration.pane_gaps),
          .header = static_cast<std::uint8_t>(std::clamp(std::ceil(display.chrome.pane_header / static_cast<float>(grid.cell_height_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint8_t>::max()))),
      },
  };

  const auto columns = std::clamp(std::floor(geometry.terminal.width / static_cast<float>(grid.cell_width_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max()));
  for (auto &client : clients_) {
    if (client) {
      (*client)->session.setWorkbenchGeometry(workbench);
      (*client)->session.setHostColumns(static_cast<std::uint16_t>(columns));
    }
  }
}

void Application::fitSidebarWhenReady() {
  if (!configuration().sidebar_width_auto) {
    sidebar_fit_pending_ = false;
    return;
  }

  const auto &client = clients_[machines_.active()];
  if (!sidebar_fit_pending_ || window_ == nullptr || !client || !(*client)->session.ready()) {
    return;
  }

  sidebar_fit_pending_ = false;
  fitSidebar();
}

void Application::fitSidebar() {
  if (window_ != nullptr) {
    setSidebarWidth(sidebarNaturalWidth());
  }
}

// The logical width that shows the longest card and machine row whole, at most a third of
// the window. The cards are measured from their records, so the ones scrolled out count too.
float Application::sidebarNaturalWidth() const {
  const auto density = window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const auto &chrome = display.chrome;
  auto &catalog = WindowFontCatalog::forWindow(*window_);
  const auto fonts = ResidentFonts::shared(catalog.collection());
  const auto measure = [&](const QString &text, auto pixels, bool emphasized) {
    if (text.isEmpty()) {
      return 0.0F;
    }

    const auto utf8 = text.toUtf8();
    const std::string_view view{utf8.constData(), static_cast<std::size_t>(utf8.size())};
    const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;
    catalog.request(view, role);

    return static_cast<float>(fonts::TextLayout<SystemAllocator>::measure(*fonts, view, {.pixel_height = pixels, .preferred = role}));
  };

  const auto card = AgentCardGeometry::derive(chrome);
  const auto padding = 2 * card.px(AgentCardGeometry::horizontal_padding);
  const auto gap = card.px(AgentCardGeometry::gap);
  const auto tile = chrome.px(AgentCardGeometry::tile_width);
  const auto status_side = std::round(static_cast<float>(chrome.title) * AgentCardGeometry::icon_size_ratio);
  // A status whose clock is drawn later reserves a short age.
  const auto age = QStringLiteral("59m");
  float card_width = 0;
  for (int row = 0; row < agents_.rowCount(); ++row) {
    const auto record = agents_.data(agents_.index(row), ListModel::record_role).toMap();
    const auto ports = record.value(QStringLiteral("ports")).toString();
    const auto status = record.value(QStringLiteral("status")).toString();
    const auto title = padding + tile + gap + measure(record.value(QStringLiteral("title")).toString(), chrome.body, true) + (ports.isEmpty() ? 0 : gap + measure(ports, chrome.small, false) + chrome.px(2 * AgentCardGeometry::horizontal_padding));
    const auto detail = padding + measure(record.value(QStringLiteral("project")).toString(), chrome.small, false) + gap + status_side + gap + measure(status.isEmpty() ? age : status, chrome.small, false);
    card_width = std::max({card_width, title, detail});
  }

  float machines_width = 0;
  for (std::size_t index = 0; index < clients_.size() && !machine_list_collapsed_; ++index) {
    const auto slot = static_cast<Machines::Slot>(index);
    if (slot == machines_.active() || !machines_.shown(slot)) {
      continue;
    }

    const auto &client = clients_[index];
    const bool stacked = client && std::ranges::any_of((*client)->session.agents(), [](const auto &agent) {
      return AgentOrder::stacked(agent.status);
    });
    machines_width = std::max(machines_width, MachineChromeGeometry::listNaturalWidth(chrome, measure(toQString(machines_.row(slot).label.view()), chrome.body, false), stacked));
  }

  const auto scale = display.viewport.scale;
  const auto content = std::max(card.listWidth(card_width), machines_width) + (2 * chrome.px(SidebarGeometry::margin));
  const auto third = static_cast<float>(display.viewport.width) / scale / 3;

  return std::clamp(std::ceil(content / scale), Configuration::minimum_sidebar_width, std::max(Configuration::minimum_sidebar_width, third));
}

}
