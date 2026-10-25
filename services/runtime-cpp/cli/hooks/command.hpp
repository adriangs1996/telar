#pragma once

#include "../../agents/builtin_manifests.hpp"
#include "payload.hpp"
#include "text.hpp"

namespace telar::runtime::cli::hooks {

template <Allocator Memory>
std::optional<std::int32_t> commandExitCode(Payload<Memory> &input) {
  if (input.provider == AgentProvider::claude) {
    return input.event() == "PostToolUse" ? std::optional<std::int32_t>{0} : std::nullopt;
  }
  if (input.provider == AgentProvider::codex) {
    return std::nullopt;
  }
  if (input.provider != AgentProvider::cursor) {
    return input.fields.template integer<std::int32_t>("exit_code");
  }
  if (input.event() != "postToolUse" || input.fields.text("tool_name") != "Shell") {
    return std::nullopt;
  }

  try {
    Object output{input.memory, JsonValue::parse(input.fields.text("tool_output")), true};
    return output.template integer<std::int32_t>("exitCode");
  } catch (const std::exception &) {
    return std::nullopt;
  }
}

template <Allocator Memory>
std::optional<ReportAgentCommand> commandReport(Payload<Memory> &input) {
  if ((input.provider == AgentProvider::claude || input.provider == AgentProvider::codex) && input.subagent()) {
    return std::nullopt;
  }

  const auto event = input.toolEvent();
  const bool started = event == "PreToolUse" || event == "tool_execution_start" || event == "tool.execute.before";
  const bool finished = event == "PostToolUse" || event == "tool_execution_end" || event == "tool.execute.after";
  if (!started && !finished) {
    return std::nullopt;
  }

  const auto provider = describeProvider(input.provider).name;
  const auto *manifest = builtin_manifests.find(input.provider);
  const auto field = manifest == nullptr ? std::string_view{} : manifest->commandField(input.fields.text("tool_name"));
  const auto command = input.tools.stringField(field);
  if (!command || command->empty()) {
    return std::nullopt;
  }

  const auto cwd = input.fields.text("cwd");
  return ReportAgentCommand{
      .phase = started ? AgentCommandPhase::started : AgentCommandPhase::finished,
      .provider = provider,
      .tool_call_id = input.fields.text(input.provider == AgentProvider::pi || input.provider == AgentProvider::opencode ? "tool_call_id" : "tool_use_id"),
      .command = *command,
      .cwd = input.provider == AgentProvider::cursor && cwd.empty() ? input.workspace() : cwd,
      .session = sessionReference(input.session()),
      .exit_code = started ? std::nullopt : commandExitCode(input),
  };
}

}
