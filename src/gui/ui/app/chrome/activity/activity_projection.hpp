#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "agent_projection.hpp"
#include "foundation/core/memory.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QString>
#include <QVariantMap>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.agents;
import telar.gui.foundation.model;
import telar.gui.application;

namespace telar::gui::qt {

  // An agent in a worktree: its card names the task and trades the project for the worktree's facts.
  template <Allocator Memory>
  QVariantMap taskRecord(const Agent<Memory>& agent, const Worktree<Memory>& task, const AgentRecordContext& context) {
    auto record = agentRecord(agent, context);
    const auto title = task.displayName();
    const auto handle = task.handle();
    const auto facts = application::activity::TaskCardLabels::facts(task);

    record.insert(QStringLiteral("task"), true);
    record.insert(QStringLiteral("machine"), toQString(context.machine));
    record.insert(QStringLiteral("title"), toQString(title));
    // A task titled after its branch would only repeat it.
    record.insert(QStringLiteral("taskBranch"), title == task.branch || title == handle ? QString{} : toQString(handle));
    record.insert(QStringLiteral("diffAdded"), toQString(facts.added.view()));
    record.insert(QStringLiteral("diffRemoved"), toQString(facts.removed.view()));
    record.insert(QStringLiteral("diffFiles"), toQString(facts.files.view()));
    record.insert(QStringLiteral("commitsAhead"), toQString(facts.ahead.view()));
    record.insert(QStringLiteral("commandResult"), toQString(facts.command.view()));

    return record;
  }

  template <Allocator Memory>
  QVariantMap commandRecord(const Worktree<Memory>& task, const AgentRecordContext& context) {
    application::activity::TaskCardLabels::Text storage;
    const auto facts = application::activity::TaskCardLabels::commandFacts(context.machine, task, context.connected, storage);

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
  inline QVariantMap processRecord(const ListedPane& pane, std::string_view workspace, const AgentRecordContext& context) {
    const auto name = pane.foreground.view();
    const auto mark = application::activity::ApplicationMark::forApplication(name);
    AgentCardLabels::Project project;

    return {
        {QStringLiteral("process"), true},
        {QStringLiteral("title"), toQString(name)},
        {QStringLiteral("provider"), toQString(name)},
        {QStringLiteral("project"), toQString(AgentCardLabels::project(workspace, context.machine, false, project))},
        {QStringLiteral("detail"), QString{}},
        {QStringLiteral("statusWord"), context.connected ? QString{} : QStringLiteral("offline")},
        {QStringLiteral("statusColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(AgentStatus::ready))])},
        {QStringLiteral("badge"), QString{}},
        {QStringLiteral("badgeGlyph"), QString{}},
        {QStringLiteral("attention"), QString{}},
        {QStringLiteral("signal"), QString{}},
        {QStringLiteral("signalColor"), QString::fromLatin1(palette_names[static_cast<std::size_t>(PaletteRole::overlay1)])},
        {QStringLiteral("showPlan"), false},
        {QStringLiteral("contextShare"), 1.0F},
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
        {QStringLiteral("symbol"), QStringLiteral("square-terminal")},
        {QStringLiteral("count"), QString::number(count)},
        {QStringLiteral("enabled"), false},
    };
  }

}
