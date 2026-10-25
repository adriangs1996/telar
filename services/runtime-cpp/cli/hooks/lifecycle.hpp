#pragma once

#include "event.hpp"
#include "reports.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<ReportAgent> claudeLifecycle(Payload<Memory> &input, FixedText<96> &event) {
  const auto name = input.event();
  if (input.subagent()) {
    return name == "PreToolUse" || name == "PostToolUse" ? std::optional{ReportAgent{.state = AgentReportState::continuing}} : std::nullopt;
  }

  const auto file = input.fields.text("transcript_path");
  ReportAgent report{.session = sessionReference(input.session()), .session_file = file.size() <= 1024 ? file : ""};
  if (name == "SessionStart") {
    report.state = AgentReportState::ready;
  } else if (name == "UserPromptSubmit") {
    report.state = AgentReportState::working;
  } else if (name == "PreToolUse" || name == "PostToolUse") {
    toolEvent(event, input);
    report.state = AgentReportState::working;
    const auto tool = input.fields.text("tool_name");
    if (name == "PreToolUse" && (tool == "AskUserQuestion" || tool == "ExitPlanMode")) {
      report.state = AgentReportState::blocked;
      report.blocked_reason = tool == "AskUserQuestion" ? AgentBlockedReason::question : AgentBlockedReason::plan;
      if (tool == "AskUserQuestion") {
        questionEvent(event, input);
      }
    }
  } else if (name == "Stop") {
    report.state = input.running_subagents == 0 ? AgentReportState::ready : AgentReportState::waiting;
    if (input.running_subagents == 0) {
      eventLine(event, input.fields.text("last_assistant_message"));
    } else {
      backgroundEvent(event, input.running_subagents);
    }
  } else if (name == "SessionEnd") {
    report.state = AgentReportState::exited;
    report.session = {};
  } else if (name == "Notification") {
    const auto notification = input.fields.text("notification_type");
    if (notification == "idle_prompt") {
      report.state = AgentReportState::idle;
    } else if (notification == "permission_prompt" || notification == "elicitation_dialog" || notification == "elicitation_url_dialog" || notification == "agent_needs_input") {
      report.state = AgentReportState::blocked;
      report.blocked_reason = notification == "permission_prompt" ? AgentBlockedReason::permission : AgentBlockedReason::question;
      eventLine(event, input.fields.text("message"));
    } else {
      return std::nullopt;
    }
  } else {
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> codexLifecycle(Payload<Memory> &input, FixedText<96> &event, std::string_view database) {
  const auto name = input.event();
  if (input.subagent()) {
    if (name == "PreToolUse" || name == "PostToolUse") {
      return ReportAgent{.state = AgentReportState::continuing};
    }

    auto path = input.fields.text("transcript_path");
    const auto session = input.session();
    if (name == "SubagentStop" && input.running_subagents == 0 && !session.empty() && path.ends_with(".jsonl")) {
      path.remove_suffix(sizeof(".jsonl") - 1);
      if (path.size() > session.size() && path.ends_with(session) && path[path.size() - session.size() - 1] == '-') {
        return ReportAgent{.state = AgentReportState::released};
      }
    }

    return std::nullopt;
  }

  ReportAgent report{.session = sessionReference(input.session()), .session_file = database.size() <= 1024 ? database : "", .session_file_kind = AgentSessionFileKind::codex_state};
  if ((name == "Stop" || name == "Interrupt") && input.running_subagents != 0) {
    report.state = AgentReportState::waiting;
    backgroundEvent(event, input.running_subagents);
  } else if (name == "SessionStart") {
    report.state = input.fields.text("source") == "compact" ? AgentReportState::working : AgentReportState::ready;
  } else if (name == "UserPromptSubmit") {
    report.state = AgentReportState::working;
  } else if (name == "PreToolUse" || name == "PostToolUse" || name == "PermissionRequest") {
    report.state = name == "PermissionRequest" ? AgentReportState::blocked : AgentReportState::working;
    report.blocked_reason = name == "PermissionRequest" ? AgentBlockedReason::permission : AgentBlockedReason::none;
    toolEvent(event, input);
  } else if (name == "Stop") {
    report.state = AgentReportState::settling;
  } else if (name == "Interrupt") {
    report.state = AgentReportState::ready;
  } else if (name == "SessionEnd") {
    report.state = AgentReportState::exited;
    report.session = {};
  } else {
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> piLifecycle(Payload<Memory> &input) {
  const auto name = input.event();
  ReportAgent report{.session = sessionReference(input.session())};
  if (name == "session_start" || name == "agent_settled" || name == "ui_prompt_end" || name == "state_snapshot") {
    const bool idle = input.fields.boolean("idle").value_or(name == "session_start" || name == "agent_settled");
    report.state = idle ? AgentReportState::ready : AgentReportState::working;
    if (input.fields.boolean("blocked").value_or(false)) {
      report.state = AgentReportState::blocked;
      report.blocked_reason = AgentBlockedReason::question;
    }
  } else if (name == "agent_start") {
    report.state = AgentReportState::working;
  } else if (name == "ui_prompt_start") {
    report.state = AgentReportState::blocked;
    report.blocked_reason = AgentBlockedReason::question;
  } else if (name == "session_shutdown") {
    report.state = AgentReportState::exited;
    report.session = {};
  } else {
    return std::nullopt;
  }

  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> openCodeLifecycle(Payload<Memory> &input, FixedText<96> &event) {
  const auto name = input.event();
  const auto blocked = input.blockedReason();
  ReportAgent report{.session = sessionReference(input.session())};
  if (name == "tool.execute.before") {
    if (blocked != AgentBlockedReason::none) {
      return std::nullopt;
    }

    report.state = AgentReportState::working;
    toolEvent(event, input);
  } else if (name == "load" || name == "chat.message" || name == "session.status" || name == "permission.asked" || name == "question.asked" || name == "permission.replied" || name == "question.replied" || name == "question.rejected" || name == "state_snapshot") {
    report.state = input.fields.boolean("busy").value_or(false) ? AgentReportState::working : AgentReportState::ready;
    if (blocked != AgentBlockedReason::none) {
      report.state = AgentReportState::blocked;
      report.blocked_reason = blocked;
      if (blocked == AgentBlockedReason::permission) {
        toolEvent(event, input);
      } else if (blocked == AgentBlockedReason::question) {
        questionEvent(event, input);
      }
    }
  } else if (name == "dispose") {
    report.state = AgentReportState::exited;
    report.session = {};
  } else {
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

template <Allocator Memory>
std::optional<ReportAgent> cursorLifecycle(Payload<Memory> &input, FixedText<96> &event, std::string_view metadata) {
  const auto name = input.event();
  ReportAgent report{.session = sessionReference(input.session()), .session_file = metadata.size() <= 1024 ? metadata : "", .session_file_kind = AgentSessionFileKind::cursor_meta};
  if (name == "sessionStart" || name == "stop") {
    report.state = AgentReportState::ready;
  } else if (name == "beforeSubmitPrompt") {
    report.state = AgentReportState::working;
  } else if (input.toolEvent() != name) {
    report.state = AgentReportState::working;
    toolEvent(event, input);
  } else if (name == "sessionEnd") {
    report.state = AgentReportState::exited;
    report.session = {};
  } else {
    return std::nullopt;
  }

  report.event = event.view();
  return report;
}

}
