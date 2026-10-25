#pragma once

#include "../../text/decimal.hpp"
#include "payload.hpp"
#include "reports.hpp"
#include "text.hpp"

namespace telar::runtime::cli::hooks {

inline std::optional<AgentPlanStatus> planStatus(std::string_view text) noexcept {
  constexpr std::array names{"pending", "in_progress", "completed", "deleted"};
  const auto found = std::ranges::find(names, text);
  return found == names.end() ? std::nullopt : std::optional{static_cast<AgentPlanStatus>(found - names.begin())};
}

template <Allocator Memory>
void setPlan(Payload<Memory> &input, Reports &reports, ReportAgentProgress &report) {
  const bool todo = input.fields.text("tool_name") == "TodoWrite";
  const auto items = input.tools.value(todo ? "todos" : "plan");
  if (!items || !items->encoded().starts_with('[')) {
    return;
  }

  String<Memory> current{AllocatorRef<char, Memory>{input.memory}};
  String<Memory> pending{AllocatorRef<char, Memory>{input.memory}};
  items->eachElement([&](JsonValue value) {
    if (!value.encoded().starts_with('{')) {
      return;
    }

    Object item{input.memory, value};
    const auto status = planStatus(item.stringField("status").value_or("pending")).value_or(AgentPlanStatus::pending);
    if (status == AgentPlanStatus::deleted) {
      return;
    }

    report.plan_total += report.plan_total < UINT16_MAX;
    if (status == AgentPlanStatus::completed) {
      report.plan_done += report.plan_done < UINT16_MAX;
    } else if (status == AgentPlanStatus::in_progress && current.empty()) {
      current = item.stringField(todo ? "activeForm" : "step").value_or(item.stringField(todo ? "content" : "step").value_or(""));
    } else if (status == AgentPlanStatus::pending && pending.empty()) {
      pending = item.stringField(todo ? "content" : "step").value_or("");
    }
  });

  report.plan_op = AgentPlanOp::set;
  displayText(reports.step, current.empty() ? std::string_view{pending} : std::string_view{current}, false);
  report.plan_text = reports.step.view();
}

template <Allocator Memory>
void updatePlan(Payload<Memory> &input, Reports &reports, ReportAgentProgress &report) {
  if (input.event() == "SessionStart") {
    report.plan_op = AgentPlanOp::set;
    return;
  }
  if (input.event() != "PostToolUse") {
    return;
  }

  const auto tool = input.fields.text("tool_name");
  if (tool == "TaskCreate") {
    if (const auto subject = input.tools.stringField("subject")) {
      report.plan_op = AgentPlanOp::add;
      displayText(reports.step, *subject, false);
      report.plan_text = reports.step.view();
    }
  } else if (tool == "TaskUpdate") {
    const auto text = input.tools.stringField("taskId");
    const auto status = planStatus(input.tools.stringField("status").value_or(""));
    if (!text || !status) {
      return;
    }

    const auto identifier = unsignedDecimal<std::uint16_t>(*text);
    if (identifier && *identifier != 0) {
      report.plan_op = AgentPlanOp::mark;
      report.plan_index = *identifier - 1;
      report.plan_status = *status;
    }
  } else if (tool == "TodoWrite" || tool == "update_plan") {
    setPlan(input, reports, report);
  }
}

template <Allocator Memory>
std::optional<ReportAgentProgress> progressReport(Payload<Memory> &input, Reports &reports) {
  if ((input.provider != AgentProvider::claude && input.provider != AgentProvider::codex) || input.subagent()) {
    return std::nullopt;
  }

  ReportAgentProgress report;
  const auto changed = input.provider == AgentProvider::claude ? input.fields.text("new_cwd") : std::string_view{};
  const auto cwd = changed.empty() ? input.fields.text("cwd") : changed;
  if (cwd.starts_with('/') && cwd.size() <= 4096) {
    report.cwd = cwd;
    if (const auto linked = reports.worktree.find(cwd)) {
      try {
        DisplayText16<200>::validate(linked->branch);
        report.work_tree_path = cwd.substr(0, linked->root_length);
        report.work_tree_branch = linked->branch;
      } catch (const EncodingError &) {
      }
    }
  }

  updatePlan(input, reports, report);
  if (input.event() == "Stop") {
    displayText(reports.message, input.fields.optionalText("last_assistant_message").value_or(""), true);
    report.final_message = reports.message.view();
  }

  return report.cwd.empty() && report.plan_op == AgentPlanOp::none && report.final_message.empty() ? std::nullopt : std::optional{report};
}

}
