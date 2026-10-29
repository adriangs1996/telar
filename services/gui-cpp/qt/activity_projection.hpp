#pragma once

#include "agent_projection.hpp"
#include "application/records.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "presentation/task_card_labels.hpp"
#include "projection.hpp"
#include <QString>
#include <QVariantMap>
#include <cstddef>

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

}
