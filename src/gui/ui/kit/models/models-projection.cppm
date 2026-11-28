export module telar.gui.ui.kit.models:projection;

import std;
import telar.gui.qt;
import :pane_attention_value;
import :progress_value;
import telar.gui.application;
import telar.gui.foundation.model;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.gui.foundation.forms;
import telar.gui.foundation.agents;
import telar.config.gui;
import telar.config.core;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QRectF toQRectF(Rect bounds, qreal density = 1) {
    return {static_cast<qreal>(bounds.x) / density, static_cast<qreal>(bounds.y) / density, static_cast<qreal>(bounds.width) / density, static_cast<qreal>(bounds.height) / density};
  }

  [[tbc::hot_path]] inline QColor toQColor(Color color) {
    return QColor::fromRgbF(color.r, color.g, color.b, color.a);
  }

  [[tbc::hot_path]] inline QString toQString(std::string_view text) {
    return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
  }

  [[tbc::hot_path]] inline QString workspaceKey(WorkspaceLocation location) {
    const auto kind = location.kind == WorkspaceLocation::Kind::workspace ? QLatin1StringView("workspace:") : QLatin1StringView("worktree:");

    return kind + QString::number(location.id);
  }

  // Paths read as the shell prompt does: the home directory is `~`.
  [[tbc::hot_path]] inline QString displayPath(std::string_view path) {
    auto text = toQString(path);
    const auto home = QDir::homePath();
    if (text == home || text.startsWith(home + QLatin1Char('/'))) {
      text.replace(0, home.size(), u"~"_s);
    }

    return text;
  }

  // `mark` is the workspace's own, or the one its machine's marks gave it apart from the others.
  template <Allocator Memory>
  [[tbc::generic]] QVariantMap workspaceRecord(const Workspace<Memory>& workspace, bool selected, const application::workbench::WorkspaceMark& mark) {
    QVariantMap record;

    record.insert(u"key"_s, workspaceKey(workspace.location));
    record.insert(u"name"_s, toQString(workspace.name));
    record.insert(u"path"_s, toQString(workspace.path));
    record.insert(u"shownPath"_s, displayPath(workspace.path));
    record.insert(u"branch"_s, toQString(workspace.branch));
    record.insert(u"dirty"_s, workspace.dirty);
    record.insert(u"selected"_s, selected);
    record.insert(u"initial"_s, toQString(mark.initial.view()));
    record.insert(u"markHue"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(mark.hue)]));

    return record;
  }

  [[tbc::hot_path]] inline QVariantMap applicationMarkRecord(std::string_view application) {
    const auto mark = application::activity::ApplicationMark::forApplication(application);

    return {
        {u"glyph"_s, toQString(mark.glyph)},
        {u"providerMark"_s, static_cast<int>(mark.provider)},
        {u"tile"_s, toQString(mark.tile)},
        {u"ink"_s, toQString(mark.ink)},
    };
  }

  // `owns` tells which agent runs in this card's pane.
  template <Allocator Memory, typename Owns>
  [[tbc::generic]] QVariantMap tabCard(std::uint64_t pane_id, std::string_view program, bool focused, std::span<const Agent<Memory>> agents, Owns owns) {
    auto card = applicationMarkRecord(program);

    card.insert(u"key"_s, QString::number(pane_id));
    card.insert(u"program"_s, toQString(program));
    card.insert(u"focused"_s, focused);
    QString attention;

    for (const auto& agent : agents) {
      if (owns(agent) && application::activity::AgentOrder::attention(agent.status) == application::activity::AgentOrder::Attention::needs_input) {
        attention = QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(agent.status))]);
        break;
      }
    }

    card.insert(u"attentionColor"_s, attention);

    return card;
  }

  // Panes arrive as the session's owning pointers. A tab not loaded yet has none, so it shows
  // the panes the runtime listed for it.
  template <Allocator Memory, typename Panes>
  [[tbc::generic]] QVariantList tabCards(const Tab<Memory>& tab, const Panes& panes, std::span<const Agent<Memory>> agents) {
    QVariantList cards;

    for (const auto& owned : panes) {
      const application::Pane<Memory>& candidate = *owned;
      if (!sameTab(candidate.location, tab.location)) {
        continue;
      }

      cards.append(tabCard(candidate.id, application::tabApplicationName(tab, &candidate), candidate.id == tab.focused_pane, agents, [&](const Agent<Memory>& agent) {
        return agent.pane_id == candidate.id && agent.pane_generation == candidate.generation;
      }));
    }

    if (!cards.isEmpty() || tab.loaded) {
      return cards;
    }

    for (const auto& member : tab.members) {
      cards.append(tabCard(member.pane_id, member.foreground.view(), member.pane_id == tab.foreground_pane, agents, [&](const Agent<Memory>& agent) {
        return agent.pane_id == member.pane_id && sameTab(agent.location, tab.location);
      }));
    }

    return cards;
  }

  template <Allocator Memory, typename Panes>
  [[tbc::generic]] QVariantMap tabRecord(const Tab<Memory>& tab, const application::Pane<Memory>* pane, const Panes& panes, std::span<const Agent<Memory>> agents, bool selected) {
    std::string_view session_title;

    if (pane != nullptr) {
      for (const auto& agent : agents) {
        if (agent.pane_id != pane->id || !sameTab(agent.location, tab.location)) {
          continue;
        }

        if (agent.title_state != AgentTitleState::placeholder) {
          session_title = agent.title;
        }

        break;
      }
    }

    const auto application = application::tabApplicationName(tab, pane);
    TabCaption::Buffer storage;
    const auto caption = TabCaption::resolve({.manual = tab.label, .application = application, .directory = pane == nullptr ? std::string_view{} : std::string_view{pane->cwd}, .session_title = session_title}, storage);
    auto label = toQString(caption);

    if (tab.fullscreen) {
      label.append(toQString(TabCaption::fullscreen_suffix));
    }

    QVariantMap record;

    record.insert(u"key"_s, QString::number(tab.location.tab_id));
    record.insert(u"label"_s, label);
    record.insert(u"application"_s, toQString(application));
    auto title_text = std::string_view{application};

    if (!tab.label.empty()) {
      title_text = std::string_view{tab.label};
    } else if (!session_title.empty()) {
      title_text = session_title;
    }

    auto title = toQString(title_text);

    if (tab.fullscreen) {
      title.append(toQString(TabCaption::fullscreen_suffix));
    }

    record.insert(u"title"_s, title);
    record.insert(u"path"_s, tab.label.empty() ? displayPath(pane != nullptr ? std::string_view{pane->cwd} : std::string_view{tab.directory}) : QString{});
    record.insert(u"cards"_s, tabCards(tab, panes, agents));
    record.insert(u"selected"_s, selected);
    const auto activity = application::activity::TabActivity::derive(tab, pane != nullptr ? pane->progress_state : PaneProgressState::remove, agents, selected);

    record.insert(u"activityKind"_s, static_cast<int>(activity.kind));
    record.insert(u"activityColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(activity.color)]));
    record.insert(u"statusWidth"_s, activity.width());
    record.insert(u"attentionColor"_s, activity.attention ? QString::fromLatin1(palette_names[static_cast<std::size_t>(*activity.attention)]) : QString{});
    if (activity.kind == application::activity::TabActivity::Kind::progress && pane != nullptr) {
      record.insert(u"progressSample"_s, progressValue(application::workbench::ProgressSample{.pane_id = pane->id, .attachment = pane->attachment_generation, .state = pane->progress_state, .percent = pane->progress_percent}));
    }

    return record;
  }

  // The bytes [start, end) a query matched, as the runtime marked them, flat: start, end, start…
  [[tbc::hot_path]] inline QVariantList historyRanges(const application::history::HistoryMarks& marks) {
    QVariantList flat;

    flat.reserve(2 * static_cast<qsizetype>(marks.view().size()));
    for (const auto range : marks.view()) {
      flat.append(static_cast<qulonglong>(range.start));
      flat.append(static_cast<qulonglong>(range.end));
    }

    return flat;
  }

  // The bytes `flat` marks of a text of `bytes` bytes, as historyRanges writes them. A range past
  // the text is cut at its end, as a row shows a prefix of a long command.
  [[tbc::hot_path]] inline HistoryMatchRanges historyMatches(const QVariantList& flat, std::size_t bytes) {
    HistoryMatchRanges matches;

    for (qsizetype index = 0; index + 1 < flat.size(); index += 2) {
      const auto start = flat[index].toULongLong();
      const auto end = std::min<qulonglong>(flat[index + 1].toULongLong(), bytes);

      // The runtime bounds a range to 64 KiB of command.
      if (start < end) {
        matches.append({.offset = static_cast<std::uint32_t>(start), .length = static_cast<std::uint32_t>(end - start)});
      }
    }

    return matches;
  }

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap historyRecord(const application::history::HistoryRow<Memory>& entry, CalendarSample sampled) {
    QVariantMap record;

    record.insert(u"key"_s, QString::number(entry.id));
    record.insert(u"command"_s, toQString(entry.command));
    record.insert(u"cwd"_s, toQString(entry.cwd));
    record.insert(u"compactCwd"_s, toQString(application::history::HistoryPath::compact(entry.cwd).view()));
    if (entry.exit_code) {
      record.insert(u"exitCode"_s, *entry.exit_code);
    }

    record.insert(u"failed"_s, entry.exit_code && *entry.exit_code != 0);
    record.insert(u"truncated"_s, entry.command_truncated);
    record.insert(u"provider"_s, toQString(entry.provider));
    record.insert(u"providerMark"_s, static_cast<int>(runtime::providerNamed(entry.provider)));
    const auto provider = toQString(entry.provider);
    constexpr char last_ascii = '\x7f';
    const auto letter = !provider.isEmpty() && provider.front().unicode() <= last_ascii && provider.front().isLetterOrNumber() ? provider.first(1).toUpper() : u"A"_s;

    record.insert(u"providerLetter"_s, letter);
    record.insert(u"author"_s, entry.author == HistoryAuthor::agent ? u"agent"_s : u"human"_s);
    record.insert(u"status"_s, static_cast<int>(entry.status));
    record.insert(u"running"_s, entry.status == HistoryStatus::running);
    record.insert(u"timestamp"_s, static_cast<qlonglong>(entry.started_at_ms));
    const auto status = application::history::HistoryLabels::status(entry.status, entry.exit_code);
    const auto day = application::history::HistoryLabels::localDay(entry.started_at_ms, sampled.utc_offset_min);
    const auto today = application::history::HistoryLabels::localDay(sampled.now_ms, sampled.utc_offset_min);

    record.insert(u"statusGlyph"_s, toQString(status.glyph));
    record.insert(u"statusColor"_s, toQString(palette_names[static_cast<std::size_t>(status.color)]));
    record.insert(u"duration"_s, toQString(application::history::HistoryLabels::duration(entry.duration_ns).view()));
    // An imported command, or one whose end the shell did not tell, has no duration to show.
    record.insert(u"measured"_s, entry.duration_ns > 0);
    record.insert(u"age"_s, toQString(application::history::HistoryLabels::ageAt(entry.started_at_ms, sampled).view()));
    record.insert(u"clock"_s, entry.started_at_ms >= 0 ? toQString(application::history::HistoryLabels::clock(entry.started_at_ms, sampled.utc_offset_min).view()) : QString{});
    record.insert(u"date"_s, entry.started_at_ms >= 0 ? toQString(application::history::HistoryLabels::dateLabel(entry.started_at_ms, sampled).view()) : QString{});
    record.insert(u"day"_s, static_cast<qlonglong>(day));
    record.insert(u"dayLabel"_s, toQString(application::history::HistoryLabels::dayLabel(day, today).view()).toUpper());
    record.insert(u"ranges"_s, historyRanges(entry.ranges));
    record.insert(u"excerpt"_s, toQString(entry.excerpt));
    record.insert(u"excerptRanges"_s, historyRanges(entry.excerpt_ranges));
    record.insert(u"neighbour"_s, entry.neighbour);
    record.insert(u"host"_s, toQString(entry.host));

    return record;
  }

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap paneRecord(const application::Pane<Memory>& pane, const PaneLayout::Placement& placement, const WorkbenchGeometry& workbench, bool focused, qreal density) {
    const auto geometry = application::workbench::PaneDecorationGeometry::derive(placement, workbench);
    const auto local = [&](Rect area) {
      area.x -= geometry.outer.x;
      area.y -= geometry.outer.y;

      return toQRectF(area, density);
    };

    QVariantList panels;

    if (placement.framed) {
      for (const auto& panel : geometry.panels) {
        if (!panel.empty()) {
          panels.append(local(panel));
        }
      }
    }

    QVariantMap record;

    record.insert(u"key"_s, QString::number(pane.id));
    record.insert(u"attentionKey"_s, paneAttentionValue({.pane_id = pane.id, .attachment_generation = pane.attachment_generation}));
    record.insert(u"title"_s, pane.title.empty() ? toQString(pane.foreground) : toQString(pane.title));
    record.insert(u"cwd"_s, toQString(pane.cwd));
    record.insert(u"x"_s, static_cast<qreal>(geometry.outer.x) / density);
    record.insert(u"y"_s, static_cast<qreal>(geometry.outer.y) / density);
    record.insert(u"width"_s, static_cast<qreal>(geometry.outer.width) / density);
    record.insert(u"height"_s, static_cast<qreal>(geometry.outer.height) / density);
    record.insert(u"content"_s, local(geometry.content));
    record.insert(u"frame"_s, local(geometry.frame));
    record.insert(u"panels"_s, panels);
    record.insert(u"frameRadius"_s, application::workbench::PaneDecorationGeometry::frame_radius);
    record.insert(u"frameLineWidth"_s, static_cast<qreal>(application::workbench::PaneDecorationGeometry::frame_line_width) / density);
    record.insert(u"dimAlpha"_s, application::workbench::PaneDecorationGeometry::dim_alpha);
    record.insert(u"focused"_s, focused);
    record.insert(u"framed"_s, placement.framed);
    record.insert(u"exited"_s, pane.exited);

    return record;
  }

  [[tbc::hot_path]] inline QVariantMap fontSettings(const FontConfiguration& font) {
    QVariantMap settings;

    settings.insert(u"family"_s, toQString(font.family.view()));
    settings.insert(u"style"_s, toQString(font.style.view()));
    settings.insert(u"size"_s, font.size);
    settings.insert(u"line_height"_s, font.line_height);
    settings.insert(u"letter_spacing"_s, font.letter_spacing);
    settings.insert(u"thicken"_s, font.thicken);
    settings.insert(u"thicken_strength"_s, font.thicken_strength);
    const auto hinting = telar::runtime::config::font_hinting_names.at(std::to_underlying(font.hinting));

    settings.insert(u"hinting"_s, QString::fromLatin1(hinting.data(), static_cast<qsizetype>(hinting.size())));

    return settings;
  }

  [[tbc::hot_path]] inline QVariantMap themeColors(const Configuration& configuration) {
    const auto& theme = configuration.theme;
    // Covering overlays retain opaque palette roles; region backgrounds resolve their own alpha.
    const bool transparent_panel = configuration.background_opacity < 1;
    const auto panel_background = transparent_panel ? QColor{Qt::transparent} : toQColor(theme.chromeColor(PaletteRole::panel_bg));
    QVariantMap colors;

    colors.insert(u"theme"_s, static_cast<int>(theme.name));
    colors.insert(u"background"_s, toQColor(theme.background));
    colors.insert(u"panelBackground"_s, panel_background);
    const auto surfaces = application::window::ChromeSurfaces::derive(theme, configuration.background_opacity, configuration.opacity);

    colors.insert(u"sidebarBackground"_s, toQColor(surfaces.sidebar));
    colors.insert(u"topbarBackground"_s, toQColor(surfaces.topbar));
    colors.insert(u"bottombarBackground"_s, toQColor(surfaces.bottombar));
    colors.insert(u"chromeText"_s, toQColor(surfaces.text));
    colors.insert(u"workbenchBackground"_s, toQColor(surfaces.workbench));
    colors.insert(u"paneBackground"_s, toQColor(surfaces.pane));
    auto terminal_background = theme.background;

    terminal_background.a = surfaces.pane.a;
    colors.insert(u"terminalBackground"_s, toQColor(terminal_background));
    colors.insert(u"foreground"_s, toQColor(theme.chromeColor(PaletteRole::text)));
    colors.insert(u"surface"_s, toQColor(theme.surface));
    colors.insert(u"elevated"_s, toQColor(theme.elevated));
    colors.insert(u"border"_s, toQColor(theme.border));
    colors.insert(u"muted"_s, toQColor(theme.muted));
    colors.insert(u"accent"_s, toQColor(theme.accent));
    colors.insert(u"success"_s, toQColor(theme.success));
    colors.insert(u"warning"_s, toQColor(theme.warning));
    colors.insert(u"failure"_s, toQColor(theme.failure));
    for (std::size_t index = 0; index < palette_names.size(); ++index) {
      const auto name = QString::fromLatin1(palette_names[index]);

      colors.insert(name, toQColor(theme.chromeColor(static_cast<PaletteRole>(index))));
    }

    for (std::size_t index = 0; index < syntax_names.size(); ++index) {
      colors.insert(u"syntax_"_s + QString::fromLatin1(syntax_names[index]), toQColor(theme.resolve(theme.syntax[index], theme.foreground)));
    }

    // The yellow the terminal draws with, which the explorer marks a change in: a theme whose
    // accent is its bright yellow, as the default one's is, keeps the two apart with it.
    constexpr std::size_t terminal_yellow = 3;

    colors.insert(u"terminalYellow"_s, toQColor(theme.palette[terminal_yellow]));

    return colors;
  }

}
