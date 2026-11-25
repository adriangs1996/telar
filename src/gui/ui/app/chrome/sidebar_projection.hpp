#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/projection.hpp"
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
        {QStringLiteral("width"), static_cast<double>(bounds.width) / density},
        {QStringLiteral("height"), static_cast<double>(bounds.height) / density},
        {QStringLiteral("agentHeight"), static_cast<double>(geometry.agentHeight()) / density},
        {QStringLiteral("agentTitleRow"), static_cast<double>(geometry.title_row) / density},
        {QStringLiteral("agentDetailY"), static_cast<double>(geometry.agentSignalTop()) / density},
        {QStringLiteral("agentWhereY"), static_cast<double>(geometry.agentWhereTop()) / density},
        {QStringLiteral("agentDetailRow"), static_cast<double>(geometry.small_row) / density},
        {QStringLiteral("padding"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::horizontal_padding)) / density},
        {QStringLiteral("tileWidth"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::tile_width)) / density},
        {QStringLiteral("tileHeight"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::tile_height)) / density},
        {QStringLiteral("markColumn"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::mark_column)) / density},
        {QStringLiteral("textInset"), static_cast<double>(geometry.textInset()) / density},
        // What one design pixel measures beside the chrome text, in logical pixels.
        {QStringLiteral("ratio"), static_cast<double>(geometry.scale) / density},
        {QStringLiteral("badgeSide"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::badge_side)) / density},
        {QStringLiteral("planBarHeight"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::plan_bar_height)) / density},
        {QStringLiteral("attentionAlpha"), application::activity::AgentCardGeometry::attention_alpha},
        {QStringLiteral("attentionOutlineAlpha"), application::activity::AgentCardGeometry::attention_outline_alpha},
        {QStringLiteral("context"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::context), density)},
        {QStringLiteral("title"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::title), density)},
        {QStringLiteral("detail"), toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::detail), density)},
        {QStringLiteral("radius"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::radius)) / density},
        {QStringLiteral("gap"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::gap)) / density},
        {QStringLiteral("projectLabelGap"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::project_label_gap)) / density},
        {QStringLiteral("projectSide"), static_cast<double>(std::round(static_cast<float>(chrome.small) * application::activity::AgentCardGeometry::icon_size_ratio)) / density},
        {QStringLiteral("providerSide"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::mark_side)) / density},
        {QStringLiteral("providerAlpha"), application::activity::AgentCardGeometry::provider_alpha},
        {QStringLiteral("spacing"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::spacing)) / density},
        {QStringLiteral("scrollbarWidth"), static_cast<double>(geometry.px(application::activity::AgentCardGeometry::scrollbar_width)) / density},
    };
  }

  inline QVariantMap sidebarRegionsRecord(Rect area, const application::window::DisplayMetrics& display, std::size_t count) {
    const auto& chrome = display.chrome;
    const auto density = display.density;
    const auto geometry = application::SidebarGeometry::measure(area, chrome, count);

    return {
        {QStringLiteral("projectsHeader"), toQRectF(geometry.projects_header, density)},
        {QStringLiteral("projects"), toQRectF(geometry.projects, density)},
        {QStringLiteral("activityHeader"), toQRectF(geometry.activity_header, density)},
        {QStringLiteral("activity"), toQRectF(geometry.activity, density)},
        {QStringLiteral("workspaceHeight"), static_cast<double>(application::SidebarGeometry::workspaceHeight(chrome)) / density},
        {QStringLiteral("sectionGap"), static_cast<double>(application::SidebarGeometry::sectionGap(chrome)) / density},
        {QStringLiteral("cards"), agentCardGeometryRecord(display, geometry.activity.width)},
        {QStringLiteral("activitySeparatorY"), (static_cast<double>(std::floor(geometry.activity_header.y + (geometry.activity_header.height / 2)) - geometry.activity_header.y)) / density},
    };
  }

}
