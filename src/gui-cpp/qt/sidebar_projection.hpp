#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "list_model.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include <limits>
#include <stdexcept>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <utility>
#include <span>
#include <variant>
#include "../terminal/screen.hpp"
#include "projection.hpp"
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>

#pragma once



import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.notification_stack;

namespace telar::gui::qt {

inline QVariantMap agentCardGeometryRecord(const DisplayMetrics &display, float list_width) {
  const auto &chrome = display.chrome;
  const auto density = display.density;
  const auto geometry = AgentCardGeometry::derive(chrome);
  const Rect bounds{.width = geometry.cardWidth(list_width), .height = geometry.height()};

  return {
      {QStringLiteral("width"), bounds.width / density},
      {QStringLiteral("height"), bounds.height / density},
      {QStringLiteral("compactHeight"), geometry.compactHeight() / density},
      {QStringLiteral("agentHeight"), geometry.agentHeight() / density},
      {QStringLiteral("agentTitleRow"), geometry.title_row / density},
      {QStringLiteral("agentDetailY"), (geometry.px(AgentCardGeometry::vertical_padding) + geometry.title_row + geometry.px(AgentCardGeometry::title_gap)) / density},
      {QStringLiteral("agentDetailRow"), geometry.small_row / density},
      {QStringLiteral("padding"), geometry.px(AgentCardGeometry::horizontal_padding) / density},
      {QStringLiteral("tileWidth"), chrome.px(AgentCardGeometry::tile_width) / density},
      {QStringLiteral("tileHeight"), chrome.px(AgentCardGeometry::tile_height) / density},
      {QStringLiteral("compactPadding"), geometry.px(AgentCardGeometry::compact_vertical_padding) / density},
      {QStringLiteral("taskIndent"), geometry.px(AgentCardGeometry::task_indent) / density},
      {QStringLiteral("planCellWidth"), geometry.px(TaskCardLabels::plan_cell_width) / density},
      {QStringLiteral("planCellGap"), geometry.px(TaskCardLabels::plan_cell_gap) / density},
      {QStringLiteral("planCellHeight"), geometry.px(TaskCardLabels::plan_cell_height) / density},
      {QStringLiteral("context"), toQRectF(geometry.row(bounds, AgentCardGeometry::Row::context), density)},
      {QStringLiteral("title"), toQRectF(geometry.row(bounds, AgentCardGeometry::Row::title), density)},
      {QStringLiteral("detail"), toQRectF(geometry.row(bounds, AgentCardGeometry::Row::detail), density)},
      {QStringLiteral("radius"), geometry.px(AgentCardGeometry::radius) / density},
      {QStringLiteral("gap"), geometry.px(AgentCardGeometry::gap) / density},
      {QStringLiteral("projectLabelGap"), geometry.px(AgentCardGeometry::project_label_gap) / density},
      {QStringLiteral("minimumProjectLabel"), geometry.px(AgentCardGeometry::project_label_minimum) / density},
      {QStringLiteral("statusGap"), geometry.px(AgentCardGeometry::gap) / density},
      {QStringLiteral("statusSide"), std::round(static_cast<float>(chrome.title) * AgentCardGeometry::icon_size_ratio) / density},
      {QStringLiteral("projectSide"), std::round(static_cast<float>(chrome.small) * AgentCardGeometry::icon_size_ratio) / density},
      {QStringLiteral("providerSide"), std::round(chrome.px(AgentCardGeometry::mark_side)) / density},
      {QStringLiteral("providerAlpha"), AgentCardGeometry::provider_alpha},
      {QStringLiteral("spacing"), geometry.px(AgentCardGeometry::spacing) / density},
      {QStringLiteral("groupGap"), geometry.px(AgentCardGeometry::group_gap) / density},
      {QStringLiteral("scrollbarWidth"), chrome.px(AgentCardGeometry::scrollbar_width) / density},
  };
}

inline QVariantMap sidebarRegionsRecord(Rect area, const DisplayMetrics &display, std::size_t count, SidebarMachines machines = {}) {
  const auto &chrome = display.chrome;
  const auto density = display.density;
  const auto geometry = SidebarGeometry::measure(area, chrome, count, machines);

  return {
      {QStringLiteral("machinesHeader"), toQRectF(geometry.machines_header, density)},
      {QStringLiteral("machines"), toQRectF(geometry.machines, density)},
      {QStringLiteral("projectsHeader"), toQRectF(geometry.projects_header, density)},
      {QStringLiteral("projects"), toQRectF(geometry.projects, density)},
      {QStringLiteral("activityHeader"), toQRectF(geometry.activity_header, density)},
      {QStringLiteral("activity"), toQRectF(geometry.activity, density)},
      {QStringLiteral("workspaceHeight"), SidebarGeometry::workspaceHeight(chrome) / density},
      {QStringLiteral("cards"), agentCardGeometryRecord(display, geometry.activity.width)},
      {QStringLiteral("activitySeparatorY"), (std::floor(geometry.activity_header.y + (geometry.activity_header.height / 2)) - geometry.activity_header.y) / density},
  };
}

inline QVariantMap workspaceRailRecord(const ListModel &workspaces, Rect area, const DisplayMetrics &display, int selected) {
  const auto &chrome = display.chrome;
  const auto density = display.density;
  const auto geometry = WorkspaceRailGeometry::measure(area, chrome.ratio, {.count = static_cast<std::size_t>(workspaces.rowCount()), .active = static_cast<std::size_t>(std::max(0, selected))});
  QVariantList marks;
  auto bounds = geometry.firstMark();
  for (std::size_t position = 0; position < geometry.window.count; ++position) {
    if (bounds.empty()) {
      break;
    }

    const auto index = static_cast<int>(geometry.window.first + position);
    marks.append(QVariantMap{
        {QStringLiteral("bounds"), toQRectF(bounds, density)},
        {QStringLiteral("record"), workspaces.data(workspaces.index(index), ListModel::record_role)},
    });
    bounds = geometry.nextMark(bounds);
  }

  QVariantMap result{
      {QStringLiteral("marks"), marks},
      {QStringLiteral("previousBounds"), toQRectF(geometry.previous, density)},
      {QStringLiteral("nextBounds"), toQRectF(geometry.next, density)},
      {QStringLiteral("previousCount"), static_cast<qulonglong>(geometry.window.first)},
      {QStringLiteral("nextCount"), static_cast<qulonglong>(geometry.window.total - geometry.window.first - geometry.window.count)},
  };
  if (const auto previous = geometry.window.previous(); previous && !geometry.previous.empty()) {
    result.insert(QStringLiteral("previousKey"), workspaces.data(workspaces.index(static_cast<int>(*previous)), ListModel::record_role).toMap().value(QStringLiteral("key")));
  }

  if (const auto next = geometry.window.next(); next && !geometry.next.empty()) {
    result.insert(QStringLiteral("nextKey"), workspaces.data(workspaces.index(static_cast<int>(*next)), ListModel::record_role).toMap().value(QStringLiteral("key")));
  }

  return result;
}

}
