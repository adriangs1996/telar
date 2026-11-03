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
  output.raw("{\"pane_id\":").number(agent.pane_id).raw(",\"pane_generation\":").number(agent.pane_generation).raw(",\"workspace_id\":").number(agent.location.workspace.id).raw(",\"tab_id\":").number(agent.location.tab_id).raw(",\"pane_index\":").number(agent.pane_index).raw(",\"provider\":").quoted(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes).raw(",\"provider_index\":").number(static_cast<Byte>(agent.provider)).raw(",\"status\":").quoted(agentStatus(agent.status), escapes).raw(",\"workspace\":").quoted(agent.workspace_label, escapes).raw(",\"tab\":").quoted(agent.tab_label, escapes).raw(",\"title\":").quoted(agent.session_title, escapes).raw(",\"cwd\":").quoted(agent.cwd_label, escapes).raw(",\"blocked_reason\":").quoted(blockedReason(agent.blocked_reason), escapes).raw(",\"status_age_s\":").number(agent.status_age_s).raw(",\"worktree_id\":").number(agent.work_tree).raw(",\"last_event\":").quoted(agent.last_event, escapes).raw(",\"plan\":{\"done\":").number(agent.plan_done).raw(",\"total\":").number(agent.plan_total).raw(",\"step\":").quoted(agent.plan_step, escapes).raw("},\"final_message\":").quoted(agent.final_message, escapes).raw(",\"session_id\":").quoted(hexSession(agent.session_id), escapes).raw("}");
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
    output.raw(entry.branch).raw("\t").raw(entry.title.empty() ? entry.branch : entry.title).raw("\t").raw(worktreeState(entry.state)).raw("\t").raw(member == agents.end() ? "-" : agentStatus(member->status)).raw("\t+").number(entry.diff_added).raw(" -").number(entry.diff_removed).raw(" ").number(entry.diff_files).raw(" files\t").raw(entry.command_label.empty() ? "-" : entry.command_label).raw(" ").raw(commandState(entry.command_state)).raw("\t").raw(entry.path).raw("\n");
    return;
  }

  output.raw("{\"worktree_id\":").number(entry.worktree).raw(",\"branch\":").quoted(entry.branch, escapes).raw(",\"title\":").quoted(entry.title, escapes).raw(",\"brief\":").quoted(entry.brief, escapes).raw(",\"base\":").quoted(entry.base, escapes).raw(",\"dispatched_from\":").quoted(entry.dispatched_from, escapes).raw(",\"coordinator\":");
  if (entry.coordinator) {
    output.raw("{\"session_id\":").quoted(hexSession(entry.coordinator->session_id)).raw(",\"pane_id\":").number(entry.coordinator->pane_id).raw(",\"pane_generation\":").number(entry.coordinator->pane_generation).raw("}");
  } else {
    output.raw("null");
  }
  output.raw(",\"path\":").quoted(entry.path, escapes).raw(",\"origin\":").quoted(entry.origin == WorktreeOrigin::telar ? "telar" : "external").raw(",\"state\":").quoted(worktreeState(entry.state)).raw(",\"source_workspace_id\":").number(entry.source).raw(",\"workspace_id\":");
  if (entry.workspace) {
    output.number(*entry.workspace);
  } else {
    output.raw("null");
  }
  output.raw(",\"diff\":{\"added\":").number(entry.diff_added).raw(",\"removed\":").number(entry.diff_removed).raw(",\"files\":").number(entry.diff_files).raw(",\"commits_ahead\":").number(entry.commits_ahead).raw("},\"command\":{\"label\":").quoted(entry.command_label, escapes).raw(",\"state\":").quoted(commandState(entry.command_state)).raw(",\"exit_code\":").signedNumber(entry.command_exit).raw("},\"agents\":[");
  bool first = true;
  for (const auto &agent : agents) {
    if (agent.work_tree != entry.worktree) {
      continue;
    }
    if (!first) {
      output.raw(",");
    }
    worktreeAgent(output, agent);
    first = false;
  }
  output.raw("]}");
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
    output.raw("{\"worktree_id\":").number(launch.worktree).raw(",\"setup_execution_id\":");
    if (launch.setup) {
      output.number(*launch.setup);
    } else {
      output.raw("null");
    }
    output.raw(",\"environment\":").quoted(launch.setup ? "ready" : "not_declared").raw(",\"branch\":").quoted(launch.branch).raw(",\"base\":").quoted(launch.base).raw(",\"path\":").quoted(launch.path).raw(",\"workspace_id\":").number(launch.opened.location.workspace.id).raw(",\"tab_id\":").number(launch.opened.location.tab_id).raw(",\"pane_id\":").number(launch.opened.pane_id).raw(",\"pane_generation\":").number(launch.opened.pane_generation).raw("}\n");
  } else {
    output.raw("worktree ").raw(launch.branch).raw(" at ").raw(launch.path).raw(": pane ").number(launch.opened.pane_id).raw(" in workspace ").number(launch.opened.location.workspace.id).raw("\n");
  }
}

}
