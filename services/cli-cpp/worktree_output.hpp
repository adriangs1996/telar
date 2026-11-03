#pragma once

#include "session_channel.hpp"

namespace telar::runtime::cli::sessions {

inline std::string hexSession(const std::array<Byte, 16> &session) {
  constexpr std::string_view digits = "0123456789abcdef";
  std::string result;
  for (const auto byte : session) {
    result += digits[byte >> 4];
    result += digits[byte & 15];
  }
  return result;
}

inline std::string_view agentStatus(AgentStatus status) {
  switch (status) {
  case AgentStatus::unknown:
    return "unknown";
  case AgentStatus::working:
    return "working";
  case AgentStatus::blocked:
    return "blocked";
  case AgentStatus::ready:
    return "ready";
  case AgentStatus::done:
    return "done";
  case AgentStatus::failed:
    return "failed";
  }
  return "unknown";
}

inline std::string_view blockedReason(AgentBlockedReason reason) {
  switch (reason) {
  case AgentBlockedReason::none:
    return "none";
  case AgentBlockedReason::permission:
    return "permission";
  case AgentBlockedReason::question:
    return "question";
  case AgentBlockedReason::plan:
    return "plan";
  case AgentBlockedReason::other:
    return "other";
  }
  return "none";
}

template <Allocator Memory>
void worktreeAgent(Output<Memory> &output, const AgentSnapshotEntry &agent) {
  constexpr auto escapes = JsonEscapes::control;
  output.text("{\"pane_id\":").number(agent.pane_id).text(",\"pane_generation\":").number(agent.pane_generation).text(",\"workspace_id\":").number(agent.location.workspace.id).text(",\"tab_id\":").number(agent.location.tab_id).text(",\"pane_index\":").number(agent.pane_index).text(",\"provider\":").json(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes).text(",\"provider_index\":").number(static_cast<Byte>(agent.provider)).text(",\"status\":").json(agentStatus(agent.status), escapes).text(",\"workspace\":").json(agent.workspace_label, escapes).text(",\"tab\":").json(agent.tab_label, escapes).text(",\"title\":").json(agent.session_title, escapes).text(",\"cwd\":").json(agent.cwd_label, escapes).text(",\"blocked_reason\":").json(blockedReason(agent.blocked_reason), escapes).text(",\"status_age_s\":").number(agent.status_age_s).text(",\"worktree_id\":").number(agent.work_tree).text(",\"last_event\":").json(agent.last_event, escapes).text(",\"plan\":{\"done\":").number(agent.plan_done).text(",\"total\":").number(agent.plan_total).text(",\"step\":").json(agent.plan_step, escapes).text("},\"final_message\":").json(agent.final_message, escapes).text(",\"session_id\":").json(hexSession(agent.session_id), escapes).text("}");
}

inline std::string_view worktreeState(WorktreeState state) {
  switch (state) {
  case WorktreeState::active:
    return "active";
  case WorktreeState::integrated:
    return "integrated";
  case WorktreeState::gone:
    return "gone";
  }
  return "active";
}

inline std::string_view commandState(CommandState state) {
  switch (state) {
  case CommandState::none:
    return "none";
  case CommandState::running:
    return "running";
  case CommandState::exited:
    return "exited";
  }
  return "none";
}

template <Allocator Memory>
void worktreeEntry(Output<Memory> &output, const WorktreeListEntry &entry, std::span<const AgentSnapshotEntry> agents, bool json) {
  constexpr auto escapes = JsonEscapes::control;
  if (!json) {
    const auto member = std::ranges::find(agents, entry.worktree, &AgentSnapshotEntry::work_tree);
    output.text(entry.branch).text("\t").text(entry.title.empty() ? entry.branch : entry.title).text("\t").text(worktreeState(entry.state)).text("\t").text(member == agents.end() ? "-" : agentStatus(member->status)).text("\t+").number(entry.diff_added).text(" -").number(entry.diff_removed).text(" ").number(entry.diff_files).text(" files\t").text(entry.command_label.empty() ? "-" : entry.command_label).text(" ").text(commandState(entry.command_state)).text("\t").text(entry.path).text("\n");
    return;
  }

  output.text("{\"worktree_id\":").number(entry.worktree).text(",\"branch\":").json(entry.branch, escapes).text(",\"title\":").json(entry.title, escapes).text(",\"brief\":").json(entry.brief, escapes).text(",\"base\":").json(entry.base, escapes).text(",\"dispatched_from\":").json(entry.dispatched_from, escapes).text(",\"coordinator\":");
  if (entry.coordinator) {
    output.text("{\"session_id\":").json(hexSession(entry.coordinator->session_id)).text(",\"pane_id\":").number(entry.coordinator->pane_id).text(",\"pane_generation\":").number(entry.coordinator->pane_generation).text("}");
  } else {
    output.text("null");
  }
  output.text(",\"path\":").json(entry.path, escapes).text(",\"origin\":").json(entry.origin == WorktreeOrigin::telar ? "telar" : "external").text(",\"state\":").json(worktreeState(entry.state)).text(",\"source_workspace_id\":").number(entry.source).text(",\"workspace_id\":");
  if (entry.workspace) {
    output.number(*entry.workspace);
  } else {
    output.text("null");
  }
  output.text(",\"diff\":{\"added\":").number(entry.diff_added).text(",\"removed\":").number(entry.diff_removed).text(",\"files\":").number(entry.diff_files).text(",\"commits_ahead\":").number(entry.commits_ahead).text("},\"command\":{\"label\":").json(entry.command_label, escapes).text(",\"state\":").json(commandState(entry.command_state)).text(",\"exit_code\":").number(entry.command_exit).text("},\"agents\":[");
  bool first = true;
  for (const auto &agent : agents) {
    if (agent.work_tree != entry.worktree) {
      continue;
    }
    if (!first) {
      output.text(",");
    }
    worktreeAgent(output, agent);
    first = false;
  }
  output.text("]}");
}

struct WorktreeLaunch {
  std::optional<std::uint64_t> setup{};
  std::uint64_t worktree{};
  std::string_view path{}, branch{}, base{};
  PaneOpened opened{};
};

template <Allocator Memory>
void worktreeLaunch(Output<Memory> &output, const WorktreeLaunch &launch, bool json) {
  if (json) {
    output.text("{\"worktree_id\":").number(launch.worktree).text(",\"setup_execution_id\":");
    if (launch.setup) {
      output.number(*launch.setup);
    } else {
      output.text("null");
    }
    output.text(",\"environment\":").json(launch.setup ? "ready" : "not_declared").text(",\"branch\":").json(launch.branch).text(",\"base\":").json(launch.base).text(",\"path\":").json(launch.path).text(",\"workspace_id\":").number(launch.opened.location.workspace.id).text(",\"tab_id\":").number(launch.opened.location.tab_id).text(",\"pane_id\":").number(launch.opened.pane_id).text(",\"pane_generation\":").number(launch.opened.pane_generation).text("}\n");
  } else {
    output.text("worktree ").text(launch.branch).text(" at ").text(launch.path).text(": pane ").number(launch.opened.pane_id).text(" in workspace ").number(launch.opened.location.workspace.id).text("\n");
  }
}

}
