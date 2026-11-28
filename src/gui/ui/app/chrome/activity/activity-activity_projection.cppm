export module telar.gui.ui.app.chrome.activity:activity_projection;

import std;
import telar.gui.qt;
import :agent_projection;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.foundation.agents;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  // An agent in a worktree: its card names the task and trades the project for the worktree's facts.
  template <Allocator Memory>
  [[tbc::generic]] QVariantMap taskRecord(const Agent<Memory>& agent, const Worktree<Memory>& task, const AgentRecordContext& context) {
    auto record = agentRecord(agent, context);
    const auto title = task.displayName();
    const auto handle = task.handle();
    const auto facts = application::activity::TaskCardLabels::facts(task);

    record.insert(u"task"_s, true);
    record.insert(u"machine"_s, toQString(context.machine));
    record.insert(u"title"_s, toQString(title));
    // A task titled after its branch would only repeat it.
    record.insert(u"taskBranch"_s, title == task.branch || title == handle ? QString{} : toQString(handle));
    record.insert(u"diffAdded"_s, toQString(facts.added.view()));
    record.insert(u"diffRemoved"_s, toQString(facts.removed.view()));
    record.insert(u"diffFiles"_s, toQString(facts.files.view()));
    record.insert(u"commitsAhead"_s, toQString(facts.ahead.view()));
    record.insert(u"commandResult"_s, toQString(facts.command.view()));

    return record;
  }

  template <Allocator Memory>
  [[tbc::generic]] QVariantMap commandRecord(const Worktree<Memory>& task, const AgentRecordContext& context) {
    application::activity::TaskCardLabels::Text storage;
    const auto facts = application::activity::TaskCardLabels::commandFacts(context.machine, task, context.connected, storage);

    return {
        {u"key"_s, u"command:"_s + QString::number(task.id)},
        {u"command"_s, true},
        {u"facts"_s, toQString(facts)},
        {u"title"_s, toQString(task.displayName())},
        {u"detail"_s, toQString(task.command_label)},
        {u"enabled"_s, context.connected && task.workspace.hasValue()},
        {u"selected"_s, false},
    };
  }

  // The two lowest listening ports, and how many more there are, a space between each:
  // `:3000`, `:3000 :9229`, `:3000 :9229 +2`. The card draws each word on its own.
  [[tbc::hot_path]] inline QString portsLabel(std::span<const std::uint16_t> ports) {
    constexpr std::size_t written = 2;
    QString label;

    for (const auto port : ports.first(std::min(ports.size(), written))) {
      if (!label.isEmpty()) {
        label += QLatin1Char(' ');
      }

      label += QLatin1Char(':') + QString::number(port);
    }

    if (ports.size() > written) {
      label += u" +"_s + QString::number(ports.size() - written);
    }

    return label;
  }

  // The command a pane's integrated shell runs or last ran: `none` for a pane without one, and
  // until its shell runs its first.
  [[tbc::hot_path]] inline QString commandStateName(PaneCommandState state) {
    switch (state) {
    case PaneCommandState::running:
      return u"running"_s;
    case PaneCommandState::finished:
      return u"finished"_s;
    case PaneCommandState::none:
      break;
    }

    // No command, or a state outside the enum.
    return u"none"_s;
  }

  // A pane no agent holds: its foreground program, where it runs, how long it has held the terminal,
  // the ports it listens on, the command its shell runs or last ran and the repository it works in.
  // `context` names the branch of the pane's workspace, which stands for a pane that works in that
  // workspace and has no integrated shell to read its own repository.
  [[tbc::hot_path]] inline QVariantMap processRecord(const ListedPane& pane, std::string_view workspace, const AgentRecordContext& context) {
    constexpr std::uint32_t milliseconds_per_second = 1000;
    const auto name = pane.foreground.view();
    const auto mark = application::activity::ApplicationMark::forApplication(name);
    const auto& facts = pane.facts;
    const bool finished = facts.command_state == PaneCommandState::finished;
    const bool inherited = facts.branch.view().empty() && facts.in_workspace;
    const auto branch = inherited ? context.branch : facts.branch.view();
    AgentCardLabels::Project project;

    return {
        {u"commandLine"_s, toQString(facts.command.view())},
        {u"commandState"_s, commandStateName(facts.command_state)},
        {u"commandTruncated"_s, facts.command_truncated},
        // The file an editor pane shows in its focused window, which stands for the command it has not.
        {u"document"_s, toQString(facts.document.view())},
        // The status the command exited with; invalid while it runs and when its shell reported none.
        {u"exitCode"_s, finished && facts.exit_code ? QVariant{*facts.exit_code} : QVariant{}},
        // How long a finished command ran, as the cards write an age: `12s`, `3m`, `2h`.
        {u"commandDuration"_s, finished ? toQString(AgentStatusPresentation::age(facts.duration_ms / milliseconds_per_second, true).view()) : QString{}},
        {u"cwd"_s, toQString(facts.directory.view())},
        {u"branch"_s, toQString(branch)},
        {u"dirty"_s, !branch.empty() && (inherited ? context.dirty : facts.dirty)},
        {u"process"_s, true},
        {u"title"_s, toQString(name)},
        {u"provider"_s, toQString(name)},
        {u"project"_s, toQString(AgentCardLabels::project(workspace, context.machine, false, project))},
        {u"detail"_s, QString{}},
        {u"statusWord"_s, context.connected ? QString{} : u"offline"_s},
        {u"statusColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(AgentStatusPresentation::color(AgentStatus::ready))])},
        {u"badge"_s, QString{}},
        {u"badgeGlyph"_s, QString{}},
        {u"attention"_s, QString{}},
        {u"signal"_s, QString{}},
        {u"signalColor"_s, QString::fromLatin1(palette_names[static_cast<std::size_t>(PaletteRole::overlay1)])},
        {u"showPlan"_s, false},
        {u"contextShare"_s, 1.0F},
        {u"working"_s, false},
        {u"statusCode"_s, static_cast<int>(AgentStatus::ready)},
        {u"blockedReason"_s, static_cast<int>(AgentBlockedReason::none)},
        {u"statusClock"_s, statusAgeValue(pane.age)},
        {u"providerMark"_s, 0},
        {u"glyph"_s, toQString(mark.glyph)},
        {u"tile"_s, toQString(mark.tile)},
        {u"ink"_s, toQString(mark.ink)},
        {u"dim"_s, pane.shell},
        {u"ports"_s, portsLabel(pane.ports())},
        {u"selected"_s, context.connected && context.selected},
        {u"enabled"_s, context.connected},
    };
  }

  [[tbc::hot_path]] inline QVariantMap processHeaderRecord(qsizetype count) {
    return {
        {u"key"_s, u"processes"_s},
        {u"header"_s, true},
        {u"title"_s, u"Processes"_s},
        {u"symbol"_s, u"square-terminal"_s},
        {u"count"_s, QString::number(count)},
        {u"enabled"_s, false},
    };
  }

}
