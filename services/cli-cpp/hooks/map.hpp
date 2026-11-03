#pragma once

#include "codex_subagents.hpp"
#include "command.hpp"
#include "lifecycle.hpp"
#include "progress.hpp"
#include "session_files.hpp"
#include "telar_platform/trace.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<ReportAgentTitle> titleReport(Payload<Memory> &input) {
  std::optional<std::string_view> title;
  if (input.provider == AgentProvider::claude) {
    if (input.event() == "SessionStart" && !input.fields.optionalText("agent_id").has_value() && !input.fields.text("session_title").empty()) {
      title = input.fields.text("session_title");
    }
  } else if (input.provider == AgentProvider::pi) {
    if (input.event() == "session_info_changed") {
      title = input.fields.optionalText("name").value_or("");
    } else if (input.event() == "session_start") {
      title = input.fields.optionalText("name");
    }
  } else if (input.provider == AgentProvider::opencode && input.event() == "session.updated") {
    title = input.fields.optionalText("title");
    if (title && defaultOpenCodeTitle(*title)) {
      title = "";
    }
  }

  return title ? std::optional{ReportAgentTitle{.title = utf8Prefix(*title, 96)}} : std::nullopt;
}

template <Allocator Memory, EnvironmentLookup Environment>
void map(Payload<Memory> &input, Reports &reports, SessionFiles &files, const Environment &environment) {
  TELAR_TRACE("hooks.mapReports");
  reports.command = commandReport(input);
  reports.title = titleReport(input);
  reports.progress = progressReport(input, reports);
  switch (input.provider) {
  case AgentProvider::claude:
    reports.lifecycle = claudeLifecycle(input, reports.event);
    break;
  case AgentProvider::codex: {
    if (input.event() == "Stop" || input.event() == "Interrupt" || input.event() == "SubagentStop") {
      CodexSubagents children;
      children.read(input.fields.text("transcript_path"));
      input.running_subagents = children.countExcept(input.fields.optionalText("agent_id").value_or(""));
    }

    const auto database = files.codex(environment);
    const bool has_home = !environment.lookup("CODEX_HOME").empty() || !environment.lookup("HOME").empty();
    reports.lifecycle = codexLifecycle(input, reports.event, has_home ? database : input.fields.text("state_database"));
    break;
  }
  case AgentProvider::pi:
    reports.lifecycle = piLifecycle(input);
    break;
  case AgentProvider::opencode:
    reports.lifecycle = openCodeLifecycle(input, reports.event);
    break;
  case AgentProvider::cursor:
    reports.lifecycle = cursorLifecycle(input, reports.event, files.cursor(input, environment));
    break;
  default:
    break;
  }
}

}
