#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "agent_projection.hpp"
#include "ui/kit/models/projection.hpp"
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
import telar.wire.vocabulary;

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
        {QStringLiteral("enabled"), context.connected && task.workspace.hasValue()},
        {QStringLiteral("selected"), false},
    };
  }

  // The two lowest listening ports, and how many more there are, a space between each:
  // `:3000`, `:3000 :9229`, `:3000 :9229 +2`. The card draws each word on its own.
  inline QString portsLabel(std::span<const std::uint16_t> ports) {
    constexpr std::size_t written = 2;
    QString label;

    for (const auto port : ports.first(std::min(ports.size(), written))) {
      if (!label.isEmpty()) {
        label += QLatin1Char(' ');
      }

      label += QLatin1Char(':') + QString::number(port);
    }

    if (ports.size() > written) {
      label += QStringLiteral(" +") + QString::number(ports.size() - written);
    }

    return label;
  }

  // The command a pane's integrated shell runs or last ran: `none` for a pane without one, and
  // until its shell runs its first.
  inline QString commandStateName(PaneCommandState state) {
    switch (state) {
    case PaneCommandState::running:
      return QStringLiteral("running");
    case PaneCommandState::finished:
      return QStringLiteral("finished");
    case PaneCommandState::none:
      break;
    }

    // No command, or a state outside the enum.
    return QStringLiteral("none");
  }

  // A pane no agent holds: its foreground program, where it runs, how long it has held the terminal,
  // the ports it listens on, the command its shell runs or last ran and the repository it works in.
  // `context` names the branch of the pane's workspace, which stands for a pane that works in that
  // workspace and has no integrated shell to read its own repository.
  inline QVariantMap processRecord(const ListedPane& pane, std::string_view workspace, const AgentRecordContext& context) {
    constexpr std::uint32_t milliseconds_per_second = 1000;
    const auto name = pane.foreground.view();
    const auto mark = application::activity::ApplicationMark::forApplication(name);
    const auto& facts = pane.facts;
    const bool finished = facts.command_state == PaneCommandState::finished;
    const bool inherited = facts.branch.view().empty() && facts.in_workspace;
    const auto branch = inherited ? context.branch : facts.branch.view();
    AgentCardLabels::Project project;

    return {
        {QStringLiteral("commandLine"), toQString(facts.command.view())},
        {QStringLiteral("commandState"), commandStateName(facts.command_state)},
        {QStringLiteral("commandTruncated"), facts.command_truncated},
        // The file an editor pane shows in its focused window, which stands for the command it has not.
        {QStringLiteral("document"), toQString(facts.document.view())},
        // The status the command exited with; invalid while it runs and when its shell reported none.
        {QStringLiteral("exitCode"), finished && facts.exit_code ? QVariant{*facts.exit_code} : QVariant{}},
        // How long a finished command ran, as the cards write an age: `12s`, `3m`, `2h`.
        {QStringLiteral("commandDuration"), finished ? toQString(AgentStatusPresentation::age(facts.duration_ms / milliseconds_per_second, true).view()) : QString{}},
        {QStringLiteral("cwd"), toQString(facts.directory.view())},
        {QStringLiteral("branch"), toQString(branch)},
        {QStringLiteral("dirty"), !branch.empty() && (inherited ? context.dirty : facts.dirty)},
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
