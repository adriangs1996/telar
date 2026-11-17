#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/models/projection.hpp"
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <cmath>
#include <cstddef>
#include <cstring>

#pragma once

import telar.gui.application;
import telar.gui.foundation.core;

namespace telar::gui::qt {

  inline QVariantMap agentCardGeometryRecord(const application::window::DisplayMetrics& display, float list_width) {
    const auto& chrome = display.chrome;
    const auto density = display.density;
    const auto geometry = application::activity::AgentCardGeometry::derive(chrome);
    const Rect bounds{.width = geometry.cardWidth(list_width), .height = geometry.height()};

    return {
        {QStringLiteral("width"), bounds.width / density},
        {QStringLiteral("height"), bounds.height / density},
        {QStringLiteral("agentHeight"), geometry.agentHeight() / density},
        {QStringLiteral("agentTitleRow"), geometry.title_row / density},
        {QStringLiteral("agentDetailY"), (geometry.px(application::activity::AgentCardGeometry::vertical_padding) + geometry.title_row + geometry.px(application::activity::AgentCardGeometry::title_gap)) / density},
        {QStringLiteral("agentDetailRow"), geometry.small_row / density},
        {QStringLiteral("padding"), geometry.px(application::activity::AgentCardGeometry::horizontal_padding) / density},
        {QStringLiteral("tileWidth"), geometry.px(application::activity::AgentCardGeometry::tile_width) / density},
        {QStringLiteral("tileHeight"), geometry.px(application::activity::AgentCardGeometry::tile_height) / density},
        {QStringLiteral("markColumn"), geometry.px(application::activity::AgentCardGeometry::mark_column) / density},
        {QStringLiteral("textInset"), geometry.textInset() / density},
        // What one design pixel measures beside the chrome text, in logical pixels.
        {QStringLiteral("ratio"), geometry.scale / density},
        {QStringLiteral("taskIndent"), geometry.px(application::activity::AgentCardGeometry::task_indent) / density},
        {QStringLiteral("badgeSide"), geometry.px(application::activity::AgentCardGeometry::badge_side) / density},
        {QStringLiteral("planBarHeight"), geometry.px(application::activity::AgentCardGeometry::plan_bar_height) / density},
        {QStringLiteral("attentionAlpha"), application::activity::AgentCardGeometry::attention_alpha},
        {QStringLiteral("attentionOutlineAlpha"), application::activity::AgentCardGeometry::attention_outline_alpha},
        {QStringLiteral("context"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::context), density)},
        {QStringLiteral("title"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::title), density)},
        {QStringLiteral("detail"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::detail), density)},
        {QStringLiteral("radius"), geometry.px(application::activity::AgentCardGeometry::radius) / density},
        {QStringLiteral("gap"), geometry.px(application::activity::AgentCardGeometry::gap) / density},
        {QStringLiteral("projectLabelGap"), geometry.px(application::activity::AgentCardGeometry::project_label_gap) / density},
        {QStringLiteral("projectSide"), std::round(static_cast<float>(chrome.small) * application::activity::AgentCardGeometry::icon_size_ratio) / density},
        {QStringLiteral("providerSide"), geometry.px(application::activity::AgentCardGeometry::mark_side) / density},
        {QStringLiteral("providerAlpha"), application::activity::AgentCardGeometry::provider_alpha},
        {QStringLiteral("spacing"), geometry.px(application::activity::AgentCardGeometry::spacing) / density},
        {QStringLiteral("groupGap"), geometry.px(application::activity::AgentCardGeometry::group_gap) / density},
        {QStringLiteral("scrollbarWidth"), geometry.px(application::activity::AgentCardGeometry::scrollbar_width) / density},
    };
  }

  inline QVariantMap sidebarRegionsRecord(Rect area, const application::window::DisplayMetrics& display, std::size_t count, application::SidebarMachines machines = {}) {
    const auto& chrome = display.chrome;
    const auto density = display.density;
    const auto geometry = application::SidebarGeometry::measure(area, chrome, count, machines);

    return {
        {QStringLiteral("machinesHeader"), toQRectF(geometry.machines_header, density)},
        {QStringLiteral("machines"), toQRectF(geometry.machines, density)},
        {QStringLiteral("projectsHeader"), toQRectF(geometry.projects_header, density)},
        {QStringLiteral("projects"), toQRectF(geometry.projects, density)},
        {QStringLiteral("activityHeader"), toQRectF(geometry.activity_header, density)},
        {QStringLiteral("activity"), toQRectF(geometry.activity, density)},
        {QStringLiteral("workspaceHeight"), application::SidebarGeometry::workspaceHeight(chrome) / density},
        {QStringLiteral("sectionGap"), application::SidebarGeometry::sectionGap(chrome) / density},
        {QStringLiteral("cards"), agentCardGeometryRecord(display, geometry.activity.width)},
        {QStringLiteral("activitySeparatorY"), (std::floor(geometry.activity_header.y + (geometry.activity_header.height / 2)) - geometry.activity_header.y) / density},
    };
  }

}
