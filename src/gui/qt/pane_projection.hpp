#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "agent_status_value.hpp"
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
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <tuple>
#include "telar_base/text/utf8.hpp"
#include <charconv>
#include <cstring>
#include <system_error>
#include <cmath>
#include "progress_value.hpp"
#include "projection.hpp"
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>

#pragma once

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.presentation.activity_order;
import telar.gui.presentation.application_mark;

import telar.gui.presentation.history_inspection;

namespace telar::gui::qt {

  struct FullscreenPaneEntry {
    std::uint64_t pane_id = 0;
    std::uint16_t index = 0;
    bool focused = false;
  };

  // The repository beside the directory: ⎇ branch, then changes and divergence when known.
  inline QString gitSummary(const PaneGit &git) {
    if (!git.repository || git.branch.empty()) {
      return {};
    }
    auto text = QStringLiteral("\u2387 ") + toQString(git.branch);
    if (git.changes_known && git.staged + git.unstaged + git.conflicted != 0) {
      text += QStringLiteral(" \u25CF") + QString::number(git.staged + git.unstaged + git.conflicted);
    }
    if (git.divergence_known && git.ahead != 0) {
      text += QStringLiteral(" \u2191") + QString::number(git.ahead);
    }
    if (git.divergence_known && git.behind != 0) {
      text += QStringLiteral(" \u2193") + QString::number(git.behind);
    }
    return text;
  }

  // A shell `ssh` reached: its host, and the link the last command took to reach it.
  template <Allocator Memory>
  QString remoteSummary(const Pane<Memory> &pane) {
    if (!pane.shell.remote) {
      return {};
    }
    auto text = pane.shell.host.empty() ? QStringLiteral("remote") : toQString(pane.shell.host);
    if (pane.shell.link_ms != 0) {
      text += QStringLiteral(" \u00B7 link ") + QString::number(pane.shell.link_ms) + QStringLiteral(" ms");
    }
    return text;
  }

  template <Allocator Memory>
  QVariantMap paneChromeRecord(const Pane<Memory> &pane, std::span<const Agent<Memory>> agents, std::uint16_t index, bool images_paused = false) {
    QVariantMap agent_record;
    std::string_view context;
    bool needs_attention = false;
    for (const auto &agent : agents) {
      if (agent.pane_id == pane.id && agent.pane_generation == pane.generation && sameTab(agent.location, pane.location)) {
        agent_record = {
            {QStringLiteral("statusCode"), static_cast<int>(agent.status)},
            {QStringLiteral("blockedReason"), static_cast<int>(agent.blocked_reason)},
            {QStringLiteral("statusColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(PaneStatusChip::color(agent.status))])},
            {QStringLiteral("statusClock"), agent.status_clock.observed() ? statusAgeValue(agent.status_clock.interval()) : QVariant{}},
            {QStringLiteral("age"), agent.status_age_s},
        };
        needs_attention = AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input;
        if (agent.title_state != AgentTitleState::placeholder) {
          context = agent.title;
        }
        break;
      }
    }

    const std::string_view application = pane.foreground.empty() ? std::string_view{"shell"} : std::string_view{pane.foreground};
    const auto mark = ApplicationMark::forApplication(application);
    const auto safe_context = WindowTitle::render("{pane_title}", {.workspace = {}, .tab = {}, .pane_title = context, .hostname = {}});
    const auto progress_color = PaneProgressPresentation::color(pane.progress_state);
    return {
        {QStringLiteral("index"), QString::number(index)},
        {QStringLiteral("program"), pane.foreground.empty() ? QStringLiteral("shell") : toQString(pane.foreground)},
        {QStringLiteral("context"), context.empty() ? displayPath(pane.cwd) : toQString(safe_context.view())},
        {QStringLiteral("git"), gitSummary(pane.git)},
        {QStringLiteral("remote"), remoteSummary(pane)},
        {QStringLiteral("glyph"), toQString(mark.glyph)},
        {QStringLiteral("providerMark"), static_cast<int>(mark.provider)},
        {QStringLiteral("tile"), toQString(mark.tile)},
        {QStringLiteral("ink"), toQString(mark.ink)},
        {QStringLiteral("agent"), agent_record},
        {QStringLiteral("needsAttention"), needs_attention},
        {QStringLiteral("imagesPaused"), images_paused},
        {QStringLiteral("activityKind"), static_cast<int>(pane.progress_state == PaneProgressState::remove ? TabActivity::Kind::none : TabActivity::Kind::progress)},
        {QStringLiteral("activityColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(progress_color)])},
        {QStringLiteral("progressSample"), progressValue({.pane_id = pane.id, .attachment = pane.attachment_generation, .state = pane.progress_state, .percent = pane.progress_percent})},
        {QStringLiteral("progressText"), toQString(PaneProgressPresentation::text(pane.progress_state, pane.progress_percent.value_or(0)).view())},
    };
  }

  template <Allocator Memory>
  QVariantMap fullscreenPaneRecord(const Pane<Memory> *pane, std::span<const Agent<Memory>> agents, FullscreenPaneEntry entry) {
    auto record = pane == nullptr ? QVariantMap{} : paneChromeRecord(*pane, agents, entry.index);
    const auto program = pane == nullptr || pane->foreground.empty() ? std::string_view{"shell"} : std::string_view{pane->foreground};
    record.insert(QStringLiteral("key"), QString::number(entry.pane_id));
    record.insert(QStringLiteral("index"), QString::number(entry.index));
    record.insert(QStringLiteral("program"), toQString(program));
    record.insert(QStringLiteral("focused"), entry.focused);
    const auto agent = record.value(QStringLiteral("agent")).toMap();
    record.insert(QStringLiteral("attentionColor"), !entry.focused && record.value(QStringLiteral("needsAttention")).toBool() ? agent.value(QStringLiteral("statusColor")).toString() : QString{});

    return record;
  }

}
