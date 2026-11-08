#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include <cmath>
#include <QDir>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "pane_attention_value.hpp"
#include "telar_base/text/utf8.hpp"
#include <charconv>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <tuple>
#include "progress_value.hpp"
#include <QChar>
#include <QColor>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtypes.h>

#pragma once


import telar.gui.application.workspace_replica;
import telar.gui.application.sound_playback;
import telar.gui.core.unicode_scalar;
import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.activity_order;
import telar.config;

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

// Paths read as the shell prompt does: the home directory is `~`.
inline QString displayPath(std::string_view path) {
  auto text = toQString(path);
  const auto home = QDir::homePath();
  if (text == home || text.startsWith(home + QLatin1Char('/'))) {
    text.replace(0, home.size(), QStringLiteral("~"));
  }

  return text;
}

inline QVariantMap applicationMarkRecord(std::string_view application) {
  const auto mark = ApplicationMark::forApplication(application);

  return {
      {QStringLiteral("glyph"), toQString(mark.glyph)},
      {QStringLiteral("providerMark"), static_cast<int>(mark.provider)},
      {QStringLiteral("tile"), toQString(mark.tile)},
      {QStringLiteral("ink"), toQString(mark.ink)},
  };
}

// `owns` tells which agent runs in this card's pane.
template <Allocator Memory, typename Owns>
QVariantMap tabCard(std::uint64_t pane_id, std::string_view program, bool focused, std::span<const Agent<Memory>> agents, Owns owns) {
  auto card = applicationMarkRecord(program);
  card.insert(QStringLiteral("key"), QString::number(pane_id));
  card.insert(QStringLiteral("program"), toQString(program));
  card.insert(QStringLiteral("focused"), focused);
  QString attention;
  for (const auto &agent : agents) {
    if (owns(agent) && AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input) {
      attention = QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(agent.status))]);
      break;
    }
  }

  card.insert(QStringLiteral("attentionColor"), attention);

  return card;
}

// Panes arrive as the session's owning pointers. A tab not loaded yet has none, so it shows
// the panes the runtime listed for it.
template <Allocator Memory, typename Panes>
QVariantList tabCards(const Tab<Memory> &tab, const Panes &panes, std::span<const Agent<Memory>> agents) {
  QVariantList cards;
  for (const auto &owned : panes) {
    const Pane<Memory> &candidate = *owned;
    if (!sameTab(candidate.location, tab.location)) {
      continue;
    }

    cards.append(tabCard(candidate.id, tabApplicationName(tab, &candidate), candidate.id == tab.focused_pane, agents, [&](const Agent<Memory> &agent) {
      return agent.pane_id == candidate.id && agent.pane_generation == candidate.generation;
    }));
  }

  if (!cards.isEmpty() || tab.loaded) {
    return cards;
  }

  for (const auto &member : tab.members) {
    cards.append(tabCard(member.pane_id, member.foreground.view(), member.pane_id == tab.foreground_pane, agents, [&](const Agent<Memory> &agent) {
      return agent.pane_id == member.pane_id && sameTab(agent.location, tab.location);
    }));
  }

  return cards;
}

template <Allocator Memory, typename Panes>
QVariantMap tabRecord(const Tab<Memory> &tab, const Pane<Memory> *pane, const Panes &panes, std::span<const Agent<Memory>> agents, bool selected) {
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

  const auto application = tabApplicationName(tab, pane);
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
  auto title = toQString(!tab.label.empty() ? std::string_view{tab.label} : !session_title.empty() ? session_title : application);
  if (tab.fullscreen) {
    title.append(toQString(TabCaption::fullscreen_suffix));
  }

  record.insert(QStringLiteral("title"), title);
  record.insert(QStringLiteral("path"), tab.label.empty() ? displayPath(pane != nullptr ? std::string_view{pane->cwd} : std::string_view{tab.directory}) : QString{});
  record.insert(QStringLiteral("cards"), tabCards(tab, panes, agents));
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
  // Covering overlays retain opaque palette roles; region backgrounds resolve their own alpha.
  const bool transparent_panel = configuration.background_opacity < 1;
  const auto panel_background = transparent_panel ? QColor{Qt::transparent} : toQColor(theme.chromeColor(PaletteRole::panel_bg));
  QVariantMap colors;
  colors.insert(QStringLiteral("background"), toQColor(theme.background));
  colors.insert(QStringLiteral("panelBackground"), panel_background);
  const auto surfaces = ChromeSurfaces::derive(theme, configuration.background_opacity, configuration.opacity);
  colors.insert(QStringLiteral("sidebarBackground"), toQColor(surfaces.sidebar));
  colors.insert(QStringLiteral("topbarBackground"), toQColor(surfaces.topbar));
  colors.insert(QStringLiteral("bottombarBackground"), toQColor(surfaces.bottombar));
  colors.insert(QStringLiteral("chromeText"), toQColor(surfaces.text));
  colors.insert(QStringLiteral("workbenchBackground"), toQColor(surfaces.workbench));
  colors.insert(QStringLiteral("paneBackground"), toQColor(surfaces.pane));
  auto terminal_background = theme.background;
  terminal_background.a = surfaces.pane.a;
  colors.insert(QStringLiteral("terminalBackground"), toQColor(terminal_background));
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
