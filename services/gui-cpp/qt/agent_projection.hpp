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
#include <charconv>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <cmath>
#include "projection.hpp"
#include <QString>
#include <QVariantMap>

#pragma once

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.presentation.notification_stack;
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

struct AgentRecordContext {
  std::string_view machine;
  std::string_view branch;
  bool selected = false;
  bool connected = true;
  bool coordinator = false;
  bool starts_project = false;
  std::size_t depth = 0;
};

template <Allocator Memory>
QVariantMap agentRecord(const Agent<Memory> &agent, const AgentRecordContext &context) {
  using Status = AgentStatusPresentation;
  const auto state = context.connected ? agent.status : AgentStatus::unknown;
  const auto word = context.connected ? Status::word(state, agent.blocked_reason) : "offline";
  const auto label = Status::text(state, agent.blocked_reason, agent.status_age_s, context.connected);
  AgentCardLabels::Project project;
  const auto project_label = AgentCardLabels::project(agent.workspace_label, context.machine, context.coordinator, project);
  const auto glyph = AgentCardLabels::providerGlyph(agent.provider_kind, agent.icon);
  const auto provider_label = agent.display_name.empty() ? std::string_view{agent.provider_name} : std::string_view{agent.display_name};

  return {
      {QStringLiteral("key"), QString::number(agent.pane_id)},
      {QStringLiteral("title"), toQString(AgentCardLabels::title(agent.title, agent.display_name))},
      {QStringLiteral("provider"), toQString(provider_label)},
      {QStringLiteral("project"), toQString(project_label)},
      {QStringLiteral("detail"), toQString(agent.status == AgentStatus::working ? std::string_view{agent.detail} : context.branch)},
      {QStringLiteral("status"), toQString(label.view())},
      {QStringLiteral("statusWord"), toQString(word)},
      {QStringLiteral("statusGlyph"), state == AgentStatus::ready ? QString{} : toQString(Status::glyph(state, agent.blocked_reason))},
      {QStringLiteral("statusColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(Status::color(state))])},
      {QStringLiteral("working"), state == AgentStatus::working},
      {QStringLiteral("statusCode"), static_cast<int>(state)},
      {QStringLiteral("blockedReason"), static_cast<int>(agent.blocked_reason)},
      {QStringLiteral("statusClock"), agent.status_clock.observed() ? statusAgeValue(agent.status_clock.interval()) : QVariant{}},
      {QStringLiteral("providerMark"), static_cast<int>(agent.provider_kind)},
      {QStringLiteral("glyph"), toQString(glyph)},
      {QStringLiteral("selected"), context.connected && context.selected},
      {QStringLiteral("enabled"), context.connected},
      {QStringLiteral("startsProject"), context.starts_project},
      {QStringLiteral("depth"), static_cast<qulonglong>(context.depth)},
      {QStringLiteral("planStep"), toQString(agent.plan_step)},
      {QStringLiteral("planDone"), agent.plan_done},
      {QStringLiteral("planTotal"), agent.plan_total},
      {QStringLiteral("age"), agent.status_age_s},
  };
}

}
