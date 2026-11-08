#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "agent_projection.hpp"
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
import telar.gui.presentation.activity_order;

namespace telar::gui::qt {

template <Allocator Memory>
QVariantMap taskRecord(const Agent<Memory> &agent, const Worktree<Memory> &task, const AgentRecordContext &context, bool compact) {
  auto record = agentRecord(agent, context);
  const auto activity = TaskCardLabels::activity(agent);
  const auto facts = TaskCardLabels::facts(context.machine, task);
  const auto plan = TaskCardLabels::plan(agent.plan_done, agent.plan_total);
  record.insert(QStringLiteral("task"), true);
  record.insert(QStringLiteral("compact"), compact);
  record.insert(QStringLiteral("dim"), context.connected && agent.status == AgentStatus::ready);
  record.insert(QStringLiteral("machine"), toQString(context.machine));
  record.insert(QStringLiteral("taskHandle"), toQString(task.handle()));
  record.insert(QStringLiteral("title"), toQString(task.displayName()));
  record.insert(QStringLiteral("facts"), toQString(facts.view()));
  record.insert(QStringLiteral("activity"), toQString(activity.text));
  record.insert(QStringLiteral("activityColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(activity.color)]));
  record.insert(QStringLiteral("showPlan"), activity.plan);
  record.insert(QStringLiteral("planCells"), static_cast<qulonglong>(plan.cells));
  record.insert(QStringLiteral("planFilled"), static_cast<qulonglong>(plan.filled));
  record.insert(QStringLiteral("planCount"), toQString(plan.count.view()));
  record.insert(QStringLiteral("compactGlyph"), toQString(AgentStatusPresentation::glyph(context.connected ? agent.status : AgentStatus::unknown, agent.blocked_reason)));

  return record;
}

template <Allocator Memory>
QVariantMap commandRecord(const Worktree<Memory> &task, const AgentRecordContext &context) {
  TaskCardLabels::Text storage;
  const auto facts = TaskCardLabels::commandFacts(context.machine, task, context.connected, storage);

  return {
      {QStringLiteral("key"), QStringLiteral("command:") + QString::number(task.id)},
      {QStringLiteral("command"), true},
      {QStringLiteral("facts"), toQString(facts)},
      {QStringLiteral("title"), toQString(task.displayName())},
      {QStringLiteral("detail"), toQString(task.command_label)},
      {QStringLiteral("enabled"), context.connected && task.workspace.has_value()},
      {QStringLiteral("selected"), false},
      {QStringLiteral("startsProject"), context.starts_project},
      {QStringLiteral("depth"), static_cast<qulonglong>(context.depth)},
  };
}

// The lowest listening port, and how many more there are: `:3000`, `:3000 +2`.
inline QString portsLabel(std::span<const std::uint16_t> ports) {
  if (ports.empty()) {
    return {};
  }

  auto label = QLatin1Char(':') + QString::number(ports.front());
  if (ports.size() > 1) {
    label += QStringLiteral(" +") + QString::number(ports.size() - 1);
  }

  return label;
}

// A pane no agent holds: its foreground program, where it runs, how long it has held the terminal
// and the ports it listens on.
inline QVariantMap processRecord(const ListedPane &pane, std::string_view workspace, const AgentRecordContext &context) {
  const auto name = pane.foreground.view();
  const auto mark = ApplicationMark::forApplication(name);
  AgentCardLabels::Project project;

  return {
      {QStringLiteral("process"), true},
      {QStringLiteral("title"), toQString(name)},
      {QStringLiteral("provider"), toQString(name)},
      {QStringLiteral("project"), toQString(AgentCardLabels::project(workspace, context.machine, false, project))},
      {QStringLiteral("detail"), QString{}},
      {QStringLiteral("statusWord"), context.connected ? QString{} : QStringLiteral("offline")},
      {QStringLiteral("statusGlyph"), QString{}},
      {QStringLiteral("statusColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(AgentStatus::ready))])},
      {QStringLiteral("working"), false},
      {QStringLiteral("statusCode"), static_cast<int>(AgentStatus::ready)},
      {QStringLiteral("blockedReason"), static_cast<int>(AgentBlockedReason::none)},
      {QStringLiteral("statusClock"), statusAgeValue(pane.age)},
      {QStringLiteral("providerMark"), 0},
      {QStringLiteral("glyph"), toQString(mark.glyph)},
      {QStringLiteral("tile"), toQString(mark.tile)},
      {QStringLiteral("ink"), toQString(mark.ink)},
      {QStringLiteral("dim"), pane.shell},
      {QStringLiteral("ports"), portsLabel(pane.ports())},
      {QStringLiteral("selected"), context.connected && context.selected},
      {QStringLiteral("enabled"), context.connected},
      {QStringLiteral("startsProject"), false},
      {QStringLiteral("depth"), qulonglong{0}},
  };
}

inline QVariantMap processHeaderRecord(qsizetype count) {
  return {
      {QStringLiteral("key"), QStringLiteral("processes")},
      {QStringLiteral("header"), true},
      {QStringLiteral("title"), QStringLiteral("Processes")},
      {QStringLiteral("count"), QString::number(count)},
      {QStringLiteral("enabled"), false},
  };
}

}
