export module telar.gui.ui.app.panes:pane_projection;

import std;
import telar.gui.qt;
import telar.gui.foundation.model;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.wire.pane_io;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  struct FullscreenPaneEntry {
    std::uint64_t pane_id = 0;
    std::uint16_t index = 0;
    bool focused = false;
  };

  // The repository beside the directory: ⎇ branch, then changes and divergence when known.
  [[tbc::hot_path]] inline QString gitSummary(const PaneGit& git) {
    if (!git.repository || git.branch.empty()) {
      return {};
    }

    auto text = u"\u2387 "_s + toQString(git.branch);

    if (git.changes_known && git.staged + git.unstaged + git.conflicted != 0) {
      text += u" \u25CF"_s + QString::number(git.staged + git.unstaged + git.conflicted);
    }

    if (git.divergence_known && git.ahead != 0) {
      text += u" \u2191"_s + QString::number(git.ahead);
    }

    if (git.divergence_known && git.behind != 0) {
      text += u" \u2193"_s + QString::number(git.behind);
    }

    return text;
  }

  // A shell `ssh` reached: its host, and the link the last command took to reach it.
  template <Allocator Memory>
  [[tbc::generic]] QString remoteSummary(const application::Pane<Memory>& pane) {
    if (!pane.shell.remote) {
      return {};
    }

    auto text = pane.shell.host.empty() ? u"remote"_s : toQString(pane.shell.host);

    if (pane.shell.link_ms != 0) {
      text += u" \u00B7 link "_s + QString::number(pane.shell.link_ms) + u" ms"_s;
    }

    return text;
  }

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap paneChromeRecord(const application::Pane<Memory>& pane, std::span<const Agent<Memory>> agents, std::uint16_t index, bool images_paused = false) {
    QVariantMap agent_record;
    std::string_view context;
    bool needs_attention = false;

    for (const auto& agent : agents) {
      if (agent.pane_id == pane.id && agent.pane_generation == pane.generation && sameTab(agent.location, pane.location)) {
        agent_record = {
            {u"statusCode"_s, static_cast<int>(agent.status)},
            {u"blockedReason"_s, static_cast<int>(agent.blocked_reason)},
            {u"statusColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(application::workbench::PaneStatusChip::color(agent.status))])},
            {u"statusClock"_s, agent.status_clock.observed() ? statusAgeValue(agent.status_clock.interval()) : QVariant{}},
            {u"age"_s, agent.status_age_s},
        };

        needs_attention = application::activity::AgentOrder::attention(agent.status) == application::activity::AgentOrder::Attention::needs_input;
        if (agent.title_state != AgentTitleState::placeholder) {
          context = agent.title;
        }

        break;
      }
    }

    const std::string_view application = pane.foreground.empty() ? std::string_view{"shell"} : std::string_view{pane.foreground};
    const auto mark = application::activity::ApplicationMark::forApplication(application);
    const auto safe_context = application::window::WindowTitle::render("{pane_title}", {.workspace = {}, .tab = {}, .pane_title = context, .hostname = {}});
    const auto progress_color = application::workbench::PaneProgressPresentation::color(pane.progress_state);

    return {
        {u"index"_s, QString::number(index)},
        {u"program"_s, pane.foreground.empty() ? u"shell"_s : toQString(pane.foreground)},
        {u"context"_s, context.empty() ? displayPath(pane.cwd) : toQString(safe_context.view())},
        // The context is the pane's directory, which its tab shows beside its caption.
        {u"contextIsDirectory"_s, context.empty()},
        {u"git"_s, gitSummary(pane.git)},
        {u"remote"_s, remoteSummary(pane)},
        {u"glyph"_s, toQString(mark.glyph)},
        {u"providerMark"_s, static_cast<int>(mark.provider)},
        {u"tile"_s, toQString(mark.tile)},
        {u"ink"_s, toQString(mark.ink)},
        {u"agent"_s, agent_record},
        {u"needsAttention"_s, needs_attention},
        {u"imagesPaused"_s, images_paused},
        {u"activityKind"_s, static_cast<int>(pane.progress_state == PaneProgressState::remove ? application::activity::TabActivity::Kind::none : application::activity::TabActivity::Kind::progress)},
        {u"activityColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(progress_color)])},
        {u"progressSample"_s, progressValue({.pane_id = pane.id, .attachment = pane.attachment_generation, .state = pane.progress_state, .percent = pane.progress_percent})},
        {u"progressText"_s, toQString(application::workbench::PaneProgressPresentation::text(pane.progress_state, pane.progress_percent.valueOr(0)).view())},
    };
  }

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap fullscreenPaneRecord(const application::Pane<Memory>* pane, std::span<const Agent<Memory>> agents, FullscreenPaneEntry entry) {
    auto record = pane == nullptr ? QVariantMap{} : paneChromeRecord(*pane, agents, entry.index);
    const auto program = pane == nullptr || pane->foreground.empty() ? std::string_view{"shell"} : std::string_view{pane->foreground};

    record.insert(u"key"_s, QString::number(entry.pane_id));
    record.insert(u"index"_s, QString::number(entry.index));
    record.insert(u"program"_s, toQString(program));
    record.insert(u"focused"_s, entry.focused);
    const auto agent = record.value(u"agent"_s).toMap();

    record.insert(u"attentionColor"_s, !entry.focused && record.value(u"needsAttention"_s).toBool() ? agent.value(u"statusColor"_s).toString() : QString{});

    return record;
  }

}
