#pragma once

#include "agent_status_value.hpp"
#include "application/records.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "presentation/agent_order.hpp"
#include "presentation/application_mark.hpp"
#include "presentation/pane_chrome.hpp"
#include "presentation/tab_activity.hpp"
#include "presentation/tab_caption.hpp"
#include "presentation/window_title.hpp"
#include "progress_value.hpp"
#include "projection.hpp"
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui::qt {

  struct FullscreenPaneEntry {
    std::uint64_t pane_id = 0;
    std::uint16_t index = 0;
    bool focused = false;
  };

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

    if (context.empty() && !pane.title.empty() && pane.title != pane.foreground) {
      context = pane.title;
    }
    if (context.empty()) {
      context = TabCaption::directoryName(pane.cwd);
    }
    const auto safe_context = WindowTitle::render("{pane_title}", {.workspace = {}, .tab = {}, .pane_title = context, .hostname = {}});
    const auto progress_color = PaneProgressPresentation::color(pane.progress_state);
    return {
        {QStringLiteral("index"), QString::number(index)},
        {QStringLiteral("program"), pane.foreground.empty() ? QStringLiteral("shell") : toQString(pane.foreground)},
        {QStringLiteral("context"), toQString(safe_context.view())},
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
    const auto mark = ApplicationMark::forApplication(program);
    record.insert(QStringLiteral("key"), QString::number(entry.pane_id));
    record.insert(QStringLiteral("index"), QString::number(entry.index));
    record.insert(QStringLiteral("program"), toQString(program));
    record.insert(QStringLiteral("focused"), entry.focused);
    record.insert(QStringLiteral("glyph"), toQString(mark.glyph));
    record.insert(QStringLiteral("providerMark"), static_cast<int>(mark.provider));
    const auto agent = record.value(QStringLiteral("agent")).toMap();
    record.insert(QStringLiteral("attentionColor"), !entry.focused && record.value(QStringLiteral("needsAttention")).toBool() ? agent.value(QStringLiteral("statusColor")).toString() : QString{});

    return record;
  }

}
