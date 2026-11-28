export module telar.gui.ui.app.chrome:sidebar_projection;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.gui.foundation.core;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QVariantMap agentCardGeometryRecord(const application::window::DisplayMetrics& display, float list_width) {
    const auto& chrome = display.chrome;
    const auto density = display.density;
    const auto geometry = application::activity::AgentCardGeometry::derive(chrome);
    const Rect bounds{.width = geometry.cardWidth(list_width), .height = geometry.height()};

    return {
        {u"width"_s, static_cast<double>(bounds.width) / density},
        {u"height"_s, static_cast<double>(bounds.height) / density},
        {u"agentHeight"_s, static_cast<double>(geometry.agentHeight()) / density},
        {u"agentTitleRow"_s, static_cast<double>(geometry.title_row) / density},
        {u"agentDetailY"_s, static_cast<double>(geometry.agentSignalTop()) / density},
        {u"agentWhereY"_s, static_cast<double>(geometry.agentWhereTop()) / density},
        {u"agentDetailRow"_s, static_cast<double>(geometry.small_row) / density},
        {u"padding"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::horizontal_padding)) / density},
        {u"tileWidth"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::tile_width)) / density},
        {u"tileHeight"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::tile_height)) / density},
        {u"markColumn"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::mark_column)) / density},
        {u"textInset"_s, static_cast<double>(geometry.textInset()) / density},
        // What one design pixel measures beside the chrome text, in logical pixels.
        {u"ratio"_s, static_cast<double>(geometry.scale) / density},
        {u"badgeSide"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::badge_side)) / density},
        {u"planBarHeight"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::plan_bar_height)) / density},
        {u"attentionAlpha"_s, application::activity::AgentCardGeometry::attention_alpha},
        {u"attentionOutlineAlpha"_s, application::activity::AgentCardGeometry::attention_outline_alpha},
        {u"context"_s, toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::context), density)},
        {u"title"_s, toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::title), density)},
        {u"detail"_s, toQRectF(geometry.row(bounds, application::activity::AgentCardGeometry::Row::detail), density)},
        {u"radius"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::radius)) / density},
        {u"gap"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::gap)) / density},
        {u"projectLabelGap"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::project_label_gap)) / density},
        {u"projectSide"_s, static_cast<double>(std::round(static_cast<float>(chrome.small) * application::activity::AgentCardGeometry::icon_size_ratio)) / density},
        {u"providerSide"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::mark_side)) / density},
        {u"providerAlpha"_s, application::activity::AgentCardGeometry::provider_alpha},
        {u"spacing"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::spacing)) / density},
        {u"scrollbarWidth"_s, static_cast<double>(geometry.px(application::activity::AgentCardGeometry::scrollbar_width)) / density},
    };
  }

  [[tbc::hot_path]] inline QVariantMap sidebarRegionsRecord(Rect area, const application::window::DisplayMetrics& display, std::size_t count) {
    const auto& chrome = display.chrome;
    const auto density = display.density;
    const auto geometry = application::SidebarGeometry::measure(area, chrome, count);

    return {
        {u"projectsHeader"_s, toQRectF(geometry.projects_header, density)},
        {u"projects"_s, toQRectF(geometry.projects, density)},
        {u"activityHeader"_s, toQRectF(geometry.activity_header, density)},
        {u"activity"_s, toQRectF(geometry.activity, density)},
        {u"workspaceHeight"_s, static_cast<double>(application::SidebarGeometry::workspaceHeight(chrome)) / density},
        {u"sectionGap"_s, static_cast<double>(application::SidebarGeometry::sectionGap(chrome)) / density},
        {u"cards"_s, agentCardGeometryRecord(display, geometry.activity.width)},
        {u"activitySeparatorY"_s, (static_cast<double>(std::floor(geometry.activity_header.y + (geometry.activity_header.height / 2)) - geometry.activity_header.y)) / density},
    };
  }

}
