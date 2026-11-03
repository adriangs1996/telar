#pragma once

#include "command_io.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

#include <format>

namespace telar::runtime::cli {

inline std::string nativeSchemaVersion() {
  return {handshake::schema_id.begin(), handshake::schema_id.end()};
}

inline std::string proxyStatusJson(const ProxyStatus &status) {
  return std::format("{{\"active\":{},\"scope\":{},\"system_trusted\":{},\"port\":{},\"preferred_port\":{}}}", jsonBoolean(status.active), quoteJson(status.scope == ProxyScope::exact ? "exact" : "wildcard"), jsonBoolean(status.system_trusted), status.port ? std::to_string(*status.port) : "null", status.preferred_port ? std::to_string(*status.preferred_port) : "null");
}

inline std::string metricsJson(const SystemMetrics &metrics, bool event) {
  auto result = std::format("{{\"revision\":{},\"cpu_percent\":{},\"memory_used_decigib\":{},", metrics.revision, metrics.cpu_percent, metrics.memory_used_decigib);
  if (event) {
    result += std::format("\"has_battery\":{},\"battery_percent\":{},\"cpu_count\":{},\"memory_total_decigib\":{}}}", jsonBoolean(metrics.has_battery), metrics.battery_percent, metrics.cpu_count, metrics.memory_total_decigib);
  } else {
    result += std::format("\"memory_total_decigib\":{},\"cpu_count\":{},\"battery_percent\":{}}}", metrics.memory_total_decigib, metrics.cpu_count, metrics.has_battery ? std::to_string(metrics.battery_percent) : "null");
  }

  return result;
}

inline std::string workspaceEventJson(const WorkspaceList &list) {
  std::string result = std::format("{{\"type\":\"workspace_list\",\"revision\":{},\"data\":[", list.revision);
  for (const auto &entry : list.entries) {
    if (&entry != list.entries.data()) {
      result += ',';
    }

    result += std::format("{{\"workspace_id\":{},\"name\":{},\"path\":{},\"tab_count\":{},\"branch\":{},\"dirty\":{}}}", entry.workspace, quoteJson(entry.name), quoteJson(entry.path), entry.tab_count, quoteJson(entry.branch), jsonBoolean(entry.dirty));
  }

  return result + "]}";
}

inline std::string agentEventEntryJson(const AgentSnapshotEntry &agent) {
  constexpr std::array status_names{"unknown", "working", "blocked", "ready", "failed", "done"};
  constexpr std::array reason_names{"none", "permission", "question", "plan", "other"};
  constexpr std::string_view hex = "0123456789abcdef";
  std::string session;
  for (const auto byte : agent.session_id) {
    session += hex[byte >> 4];
    session += hex[byte & 15];
  }

  constexpr auto escapes = JsonEscapes::control;
  return std::format("{{\"pane_id\":{},\"pane_generation\":{},\"workspace_id\":{},\"tab_id\":{},\"pane_index\":{},\"provider\":{},\"provider_index\":{},\"status\":{},\"workspace\":{},\"tab\":{},\"title\":{},\"cwd\":{},\"blocked_reason\":{},\"status_age_s\":{},\"worktree_id\":{},\"last_event\":{},\"plan\":{{\"done\":{},\"total\":{},\"step\":{}}},\"final_message\":{},\"session_id\":{}}}", agent.pane_id, agent.pane_generation, agent.location.workspace.id, agent.location.tab_id, agent.pane_index, quoteJson(agent.provider_name.empty() ? "unknown" : agent.provider_name, escapes), static_cast<Byte>(agent.provider), quoteJson(status_names.at(static_cast<std::size_t>(agent.status)), escapes), quoteJson(agent.workspace_label, escapes), quoteJson(agent.tab_label, escapes), quoteJson(agent.session_title, escapes), quoteJson(agent.cwd_label, escapes), quoteJson(reason_names.at(static_cast<std::size_t>(agent.blocked_reason)), escapes), agent.status_age_s, agent.work_tree, quoteJson(agent.last_event, escapes), agent.plan_done, agent.plan_total, quoteJson(agent.plan_step, escapes), quoteJson(agent.final_message, escapes), quoteJson(session, escapes));
}

inline std::string agentEventJson(const AgentSnapshot &snapshot) {
  std::string result = std::format("{{\"type\":\"agent_snapshot\",\"revision\":{},\"data\":[", snapshot.revision);
  for (const auto &entry : snapshot.entries) {
    if (&entry != snapshot.entries.data()) {
      result += ',';
    }

    result += agentEventEntryJson(entry);
  }

  return result + "]}";
}

}
