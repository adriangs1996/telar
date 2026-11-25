module telar.gui.features.activity;

import std;
import telar.tbc;
import telar.gui.foundation.agents;
import telar.gui.foundation.core;
import telar.gui.foundation.drawing;
import telar.gui.foundation.model;
import telar.base.ds;

namespace telar::gui::features::activity {

  template <Allocator Memory>
  tbc::val_a<ProjectActivity> ProjectActivity::derive(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept {
    ProjectActivity result;

    result.worktrees = static_cast<std::size_t>(std::ranges::count(workspaces.worktrees(), project, &Worktree<Memory>::source));
    const auto entry = workspaces.indexOf(project);
    if (entry < workspaces.entries().size()) {
      result.path = workspaces.entries()[entry].path;
    }

    for (std::size_t index = 0; index < agents.size(); ++index) {
      const auto& agent = agents[index];
      if (agent.location.workspace.kind != WorkspaceLocation::Kind::workspace || workspaces.projectOf(agent.location.workspace.id) != project) {
        continue;
      }

      if (workspaces.worktreeOfWorkspace(agent.location.workspace.id) != nullptr || workspaces.worktree(agent.work_tree) != nullptr) {
        result.working += static_cast<std::size_t>(agent.status == AgentStatus::working);
        result.finished += static_cast<std::size_t>(agent.status == AgentStatus::done || agent.status == AgentStatus::ready);
      }

      if (AgentOrder::attention(agent.status) == AgentOrder::Attention::needs_input) {
        ++result.waiting;
        if (!result.urgent || AgentOrder::priority(agent) < AgentOrder::priority(agents[*result.urgent])) {
          result.urgent = index;
        }
      }
    }

    return result;
  }

  tbc::val_a<ds::Option<std::string_view>> ProjectActivity::summary(tbc::mut_a<Text> storage) const {
    storage.truncate(0);
    if (!path) {
      return ds::none;
    }

    const auto fact = [&](std::size_t count, std::string_view one, std::string_view many) {
      if (count == 0) {
        return;
      }

      if (!storage.view().empty()) {
        storage.append(" \u00b7 ");
      }

      storage.appendDecimal(count);
      storage.append(count == 1 ? one : many);
    };

    fact(worktrees, " worktree", " worktrees");
    fact(working, " working", " working");
    fact(finished, " done", " done");
    if (storage.view().empty()) {
      return ds::none;
    }

    return storage.view();
  }

  auto ProjectActivity::attentionLabel() const -> Attention {
    Attention label;

    if (waiting != 0) {
      label.append("! ");
      label.appendDecimal(waiting);
    }

    return label;
  }

  float TabActivity::width() const noexcept {
    switch (kind) {
    case Kind::dot:
      return dot_side;
    case Kind::spinner:
      return spinner_side;
    case Kind::progress:
      return ProgressGeometry::compactWidth();
    case Kind::none:
      break;
    }

    // No activity, or a kind outside the enum.
    return 0;
  }

  template <Allocator Memory>
  TabActivity TabActivity::derive(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept {
    const Agent<Memory>* urgent = nullptr;

    for (const auto& agent : agents) {
      if (sameTab(agent.location, tab.location) && (urgent == nullptr || AgentOrder::priority(agent) < AgentOrder::priority(*urgent))) {
        urgent = &agent;
      }
    }

    TabActivity activity;

    if (urgent != nullptr && AgentOrder::attention(urgent->status) == AgentOrder::Attention::needs_input) {
      activity.attention = AgentStatusPresentation::color(urgent->status);
    }

    if (selected && tab.layout.nodes().size() == 1 && focused != PaneProgressState::remove) {
      activity.kind = Kind::progress;
      if (focused == PaneProgressState::error) {
        activity.color = PaletteRole::red;
      } else if (focused == PaneProgressState::pause) {
        activity.color = PaletteRole::yellow;
      }

      return activity;
    }

    if (urgent == nullptr) {
      return activity;
    }

    switch (urgent->status) {
    case AgentStatus::working:
      activity.kind = Kind::spinner;
      break;
    case AgentStatus::blocked:
    case AgentStatus::failed:
    case AgentStatus::done:
      activity.kind = Kind::dot;
      activity.color = AgentStatusPresentation::color(urgent->status);
      break;
    case AgentStatus::unknown:
    case AgentStatus::ready:
      break;
    }

    return activity;
  }

  template <Allocator Memory>
  auto TaskCardLabels::facts(const Worktree<Memory>& task) -> Facts {
    Facts parts;

    if (task.diff_files != 0) {
      append(parts.added, "+");
      decimal(parts.added, task.diff_added);
      append(parts.removed, "\u2212");
      decimal(parts.removed, task.diff_removed);
      append(parts.files, "· ");
      decimal(parts.files, task.diff_files);
    }

    if (task.commits_ahead != 0) {
      append(parts.ahead, "\u2191");
      decimal(parts.ahead, task.commits_ahead);
    }

    if (task.command_state == CommandState::exited) {
      append(parts.command, task.command_exit == 0 ? "\u2713 " : "\u2715 ");
      append(parts.command, task.command_label);
    }

    return parts;
  }

  template <Allocator Memory>
  auto TaskCardLabels::activity(const Agent<Memory>& agent) noexcept -> Activity {
    const auto said = [](std::string_view text, PaletteRole color, std::string_view missing) noexcept {
      return text.empty() ? Activity{.text = missing} : Activity{.text = text, .color = color};
    };

    switch (agent.status) {
    case AgentStatus::blocked:
      return said(agent.detail, PaletteRole::yellow, "No request text");
    case AgentStatus::failed:
      return said(agent.detail, PaletteRole::red, "No error text");
    case AgentStatus::done:
    case AgentStatus::ready: {
      const auto final = agent.finalLine();

      return said(final.empty() ? std::string_view{agent.detail} : final, PaletteRole::subtext0, "No final message");
    }
    case AgentStatus::unknown:
      return said(agent.detail, PaletteRole::subtext0, "No signal");
    case AgentStatus::working:
      break;
    }

    // A working agent, or a status outside the enum.
    if (agent.plan_total != 0 && !std::string_view{agent.plan_step}.empty()) {
      return {.text = agent.plan_step, .color = PaletteRole::subtext0, .plan = true};
    }

    auto activity = said(agent.detail, PaletteRole::subtext0, "No event yet");

    activity.plan = agent.plan_total != 0;

    return activity;
  }

  float TaskCardLabels::contextShare(AgentStatus state, bool signal) noexcept {
    if (!signal) {
      return 1;
    }

    switch (state) {
    case AgentStatus::blocked:
    case AgentStatus::failed:
      return waiting_context_share;
    case AgentStatus::done:
    case AgentStatus::ready:
      return resting_context_share;
    case AgentStatus::unknown:
    case AgentStatus::working:
      break;
    }

    // An unknown or working agent, or a status outside the enum.
    return context_share;
  }

  template <Allocator Memory>
  tbc::val_static<std::string_view> TaskCardLabels::commandState(const Worktree<Memory>& task, bool connected) noexcept {
    if (!connected) {
      return "offline · last known";
    }

    switch (task.command_state) {
    case CommandState::running:
      return "running";
    case CommandState::exited:
      return task.command_exit == 0 ? "exited successfully" : "failed";
    case CommandState::none:
      break;
    }

    // No command, or a state outside the enum.
    return {};
  }

  template <Allocator Memory>
  tbc::val_a<std::string_view> TaskCardLabels::commandFacts(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::mut_a<Text> storage) {
    const auto status = commandState(task, connected);

    storage.truncate(0);
    try {
      if (!machine.empty()) {
        storage.append(machine);
        storage.append(" · ");
      }

      storage.append(task.handle());
      storage.append(" · ");
      storage.append(status);

      return storage.view();
    } catch (const std::length_error&) {
      return std::string_view{status};
    }
  }

  void TaskCardLabels::append(Text& storage, std::string_view text) {
    storage.append(text.substr(0, text_capacity - storage.view().size()));
  }

  void TaskCardLabels::decimal(Text& storage, std::uint32_t value) {
    constexpr auto decimal_digits = std::numeric_limits<std::uint32_t>::digits10 + 1;
    ds::Array<char, decimal_digits> digits{};
    const auto result = std::to_chars(digits.dataMut(), std::to_address(digits.viewMut().end()), value);

    append(storage, {digits.data(), static_cast<std::size_t>(result.ptr - digits.data())});
  }

  template tbc::val_a<ProjectActivity> ProjectActivity::derive<Memory>(tbc::ref_a<WorkspaceReplica<Memory>> workspaces, std::span<const Agent<Memory>> agents, std::uint64_t project) noexcept;
  template tbc::val_a<ProjectActivity> ProjectActivity::derive<ConcurrentMemory>(tbc::ref_a<WorkspaceReplica<ConcurrentMemory>> workspaces, std::span<const Agent<ConcurrentMemory>> agents, std::uint64_t project) noexcept;
  template TabActivity TabActivity::derive<Memory>(const Tab<Memory>& tab, PaneProgressState focused, std::span<const Agent<Memory>> agents, bool selected) noexcept;
  template TabActivity TabActivity::derive<ConcurrentMemory>(const Tab<ConcurrentMemory>& tab, PaneProgressState focused, std::span<const Agent<ConcurrentMemory>> agents, bool selected) noexcept;
  template TaskCardLabels::Facts TaskCardLabels::facts<Memory>(const Worktree<Memory>& task);
  template TaskCardLabels::Facts TaskCardLabels::facts<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task);
  template TaskCardLabels::Activity TaskCardLabels::activity<Memory>(const Agent<Memory>& agent) noexcept;
  template TaskCardLabels::Activity TaskCardLabels::activity<ConcurrentMemory>(const Agent<ConcurrentMemory>& agent) noexcept;
  template tbc::val_static<std::string_view> TaskCardLabels::commandState<Memory>(const Worktree<Memory>& task, bool connected) noexcept;
  template tbc::val_static<std::string_view> TaskCardLabels::commandState<ConcurrentMemory>(const Worktree<ConcurrentMemory>& task, bool connected) noexcept;
  template tbc::val_a<std::string_view> TaskCardLabels::commandFacts<Memory>(std::string_view machine, const Worktree<Memory>& task, bool connected, tbc::mut_a<TaskCardLabels::Text> storage);
  template tbc::val_a<std::string_view> TaskCardLabels::commandFacts<ConcurrentMemory>(std::string_view machine, const Worktree<ConcurrentMemory>& task, bool connected, tbc::mut_a<TaskCardLabels::Text> storage);

}
