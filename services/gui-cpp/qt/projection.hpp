#pragma once

#include "agents/provider.hpp"
#include "application/records.hpp"
#include "application/workbench_geometry.hpp"
#include "core/calendar_sample.hpp"
#include "core/configuration.hpp"
#include "history/entry.hpp"
#include "pane_attention_value.hpp"
#include "presentation/application_mark.hpp"
#include "presentation/history_labels.hpp"
#include "presentation/history_path.hpp"
#include "presentation/pane_decoration_geometry.hpp"
#include "presentation/tab_activity.hpp"
#include "presentation/tab_caption.hpp"
#include "presentation/workspace_mark.hpp"
#include "progress_value.hpp"
#include <QChar>
#include <QColor>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <span>

namespace telar::gui::qt {

inline QRectF toQRectF(Rect bounds, qreal density = 1) {
  return {bounds.x / density, bounds.y / density, bounds.width / density, bounds.height / density};
}

inline QColor toQColor(Color color) {
  return QColor::fromRgbF(color.r, color.g, color.b, color.a);
}

inline QString toQString(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

inline QString workspaceKey(WorkspaceLocation location) {
  const auto kind = location.kind == WorkspaceLocation::Kind::workspace ? QLatin1StringView("workspace:") : QLatin1StringView("worktree:");

  return kind + QString::number(location.id);
}

template <Allocator Memory>
QVariantMap workspaceRecord(const Workspace<Memory> &workspace, bool selected) {
  QVariantMap record;
  record.insert(QStringLiteral("key"), workspaceKey(workspace.location));
  record.insert(QStringLiteral("name"), toQString(workspace.name));
  record.insert(QStringLiteral("path"), toQString(workspace.path));
  record.insert(QStringLiteral("branch"), toQString(workspace.branch));
  record.insert(QStringLiteral("dirty"), workspace.dirty);
  record.insert(QStringLiteral("selected"), selected);
  const auto mark = WorkspaceMark::resolve(workspace.name);
  record.insert(QStringLiteral("initial"), toQString(mark.initial.view()));
  record.insert(QStringLiteral("markHue"), QString::fromLatin1(palette_names[static_cast<std::size_t>(mark.hue)]));

  return record;
}

template <Allocator Memory>
QVariantMap tabRecord(const Tab<Memory> &tab, const Pane<Memory> *pane, std::span<const Agent<Memory>> agents, bool selected) {
  std::string_view session_title;
  if (pane != nullptr) {
    for (const auto &agent : agents) {
      if (agent.pane_id != pane->id || !sameTab(agent.location, tab.location)) {
        continue;
      }

      if (agent.title_state != AgentTitleState::placeholder) {
        session_title = agent.title;
      }

      break;
    }
  }

  const auto application = tab.applicationName(pane);
  const auto mark = ApplicationMark::forApplication(application);
  TabCaption::Buffer storage;
  const auto caption = TabCaption::resolve({.manual = tab.label, .application = application, .directory = pane == nullptr ? std::string_view{} : std::string_view{pane->cwd}, .session_title = session_title}, storage);
  auto label = toQString(caption);
  if (tab.fullscreen) {
    label.append(toQString(TabCaption::fullscreen_suffix));
  }

  QVariantMap record;
  record.insert(QStringLiteral("key"), QString::number(tab.location.tab_id));
  record.insert(QStringLiteral("label"), label);
  record.insert(QStringLiteral("application"), toQString(application));
  record.insert(QStringLiteral("glyph"), toQString(mark.glyph));
  record.insert(QStringLiteral("providerMark"), static_cast<int>(mark.provider));
  record.insert(QStringLiteral("selected"), selected);
  const auto activity = TabActivity::derive(tab, pane, agents, selected);
  record.insert(QStringLiteral("activityKind"), static_cast<int>(activity.kind));
  record.insert(QStringLiteral("activityColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(activity.color)]));
  record.insert(QStringLiteral("statusWidth"), activity.width());
  record.insert(QStringLiteral("attentionColor"), activity.attention ? QString::fromLatin1(palette_names[static_cast<std::size_t>(*activity.attention)]) : QString{});
  if (activity.kind == TabActivity::Kind::progress && pane != nullptr) {
    record.insert(QStringLiteral("progressSample"), progressValue(ProgressSample{.pane_id = pane->id, .attachment = pane->attachment_generation, .state = pane->progress_state, .percent = pane->progress_percent}));
  }

  return record;
}

template <Allocator Memory>
QVariantMap historyRecord(const HistoryRow<Memory> &entry, CalendarSample sampled) {
  QVariantMap record;
  record.insert(QStringLiteral("key"), QString::number(entry.id));
  record.insert(QStringLiteral("command"), toQString(entry.command));
  record.insert(QStringLiteral("cwd"), toQString(entry.cwd));
  record.insert(QStringLiteral("compactCwd"), toQString(HistoryPath::compact(entry.cwd).view()));
  if (entry.exit_code) {
    record.insert(QStringLiteral("exitCode"), *entry.exit_code);
  }
  record.insert(QStringLiteral("failed"), entry.exit_code && *entry.exit_code != 0);
  record.insert(QStringLiteral("truncated"), entry.command_truncated);
  record.insert(QStringLiteral("provider"), toQString(entry.provider));
  record.insert(QStringLiteral("providerMark"), static_cast<int>(runtime::providerNamed(entry.provider)));
  const auto provider = toQString(entry.provider);
  constexpr char last_ascii = '\x7f';
  const auto letter = !provider.isEmpty() && provider.front().unicode() <= last_ascii && provider.front().isLetterOrNumber() ? provider.first(1).toUpper() : QStringLiteral("A");
  record.insert(QStringLiteral("providerLetter"), letter);
  record.insert(QStringLiteral("author"), entry.author == HistoryAuthor::agent ? QStringLiteral("agent") : QStringLiteral("human"));
  record.insert(QStringLiteral("status"), static_cast<int>(entry.status));
  record.insert(QStringLiteral("running"), entry.status == HistoryStatus::running);
  record.insert(QStringLiteral("timestamp"), static_cast<qlonglong>(entry.started_at_ms));
  const auto status = HistoryLabels::status(entry.status, entry.exit_code);
  const auto day = HistoryLabels::localDay(entry.started_at_ms, sampled.utc_offset_min);
  const auto today = HistoryLabels::localDay(sampled.now_ms, sampled.utc_offset_min);
  record.insert(QStringLiteral("statusGlyph"), toQString(status.glyph));
  record.insert(QStringLiteral("statusColor"), toQString(palette_names[static_cast<std::size_t>(status.color)]));
  record.insert(QStringLiteral("duration"), toQString(HistoryLabels::duration(entry.duration_ns).view()));
  record.insert(QStringLiteral("age"), toQString(HistoryLabels::ageAt(entry.started_at_ms, sampled).view()));
  record.insert(QStringLiteral("clock"), entry.started_at_ms >= 0 ? toQString(HistoryLabels::clock(entry.started_at_ms, sampled.utc_offset_min).view()) : QString{});
  record.insert(QStringLiteral("date"), entry.started_at_ms >= 0 ? toQString(HistoryLabels::dateLabel(entry.started_at_ms, sampled).view()) : QString{});
  record.insert(QStringLiteral("day"), static_cast<qlonglong>(day));
  record.insert(QStringLiteral("dayLabel"), toQString(HistoryLabels::dayLabel(day, today).view()).toUpper());

  return record;
}

template <Allocator Memory>
QVariantMap paneRecord(const Pane<Memory> &pane, const PaneLayout::Placement &placement, const WorkbenchGeometry &workbench, bool focused, qreal density) {
  const auto geometry = PaneDecorationGeometry::derive(placement, workbench);
  const auto local = [&](Rect area) {
    area.x -= geometry.outer.x;
    area.y -= geometry.outer.y;

    return toQRectF(area, density);
  };
  QVariantList panels;
  if (placement.framed) {
    for (const auto &panel : geometry.panels) {
      if (!panel.empty()) {
        panels.append(local(panel));
      }
    }
  }

  QVariantMap record;
  record.insert(QStringLiteral("key"), QString::number(pane.id));
  record.insert(QStringLiteral("attentionKey"), paneAttentionValue({.pane_id = pane.id, .attachment_generation = pane.attachment_generation}));
  record.insert(QStringLiteral("title"), pane.title.empty() ? toQString(pane.foreground) : toQString(pane.title));
  record.insert(QStringLiteral("cwd"), toQString(pane.cwd));
  record.insert(QStringLiteral("x"), geometry.outer.x / density);
  record.insert(QStringLiteral("y"), geometry.outer.y / density);
  record.insert(QStringLiteral("width"), geometry.outer.width / density);
  record.insert(QStringLiteral("height"), geometry.outer.height / density);
  record.insert(QStringLiteral("content"), local(geometry.content));
  record.insert(QStringLiteral("frame"), local(geometry.frame));
  record.insert(QStringLiteral("panels"), panels);
  record.insert(QStringLiteral("frameRadius"), PaneDecorationGeometry::frame_radius);
  record.insert(QStringLiteral("frameLineWidth"), PaneDecorationGeometry::frame_line_width / density);
  record.insert(QStringLiteral("dimAlpha"), PaneDecorationGeometry::dim_alpha);
  record.insert(QStringLiteral("focused"), focused);
  record.insert(QStringLiteral("framed"), placement.framed);
  record.insert(QStringLiteral("exited"), pane.exited);

  return record;
}

inline QVariantMap fontSettings(const FontConfiguration &font) {
  QVariantMap settings;
  settings.insert(QStringLiteral("family"), toQString(font.family.view()));
  settings.insert(QStringLiteral("style"), toQString(font.style.view()));
  settings.insert(QStringLiteral("size"), font.size);
  settings.insert(QStringLiteral("line_height"), font.line_height);
  settings.insert(QStringLiteral("letter_spacing"), font.letter_spacing);
  settings.insert(QStringLiteral("thicken"), font.thicken);
  settings.insert(QStringLiteral("thicken_strength"), font.thicken_strength);

  return settings;
}

inline QVariantMap themeColors(const Configuration &configuration) {
  const auto &theme = configuration.theme;
  auto window_background = theme.background;
  window_background.a = configuration.background_opacity;
  const auto panel_color = theme.chrome[static_cast<std::size_t>(PaletteRole::panel_bg)];
  const bool transparent_panel = configuration.background_opacity < 1 && panel_color.kind == CellColor::Kind::default_color;
  const auto panel_background = transparent_panel ? QColor{Qt::transparent} : toQColor(theme.chromeColor(PaletteRole::panel_bg));
  QVariantMap colors;
  colors.insert(QStringLiteral("background"), toQColor(theme.background));
  colors.insert(QStringLiteral("windowBackground"), toQColor(window_background));
  colors.insert(QStringLiteral("panelBackground"), panel_background);
  colors.insert(QStringLiteral("foreground"), toQColor(theme.chromeColor(PaletteRole::text)));
  colors.insert(QStringLiteral("surface"), toQColor(theme.surface));
  colors.insert(QStringLiteral("elevated"), toQColor(theme.elevated));
  colors.insert(QStringLiteral("border"), toQColor(theme.border));
  colors.insert(QStringLiteral("muted"), toQColor(theme.muted));
  colors.insert(QStringLiteral("accent"), toQColor(theme.accent));
  colors.insert(QStringLiteral("success"), toQColor(theme.success));
  colors.insert(QStringLiteral("warning"), toQColor(theme.warning));
  colors.insert(QStringLiteral("failure"), toQColor(theme.failure));
  for (std::size_t index = 0; index < palette_names.size(); ++index) {
    const auto name = QString::fromLatin1(palette_names[index]);
    colors.insert(name, toQColor(theme.chromeColor(static_cast<PaletteRole>(index))));
  }

  return colors;
}

}
