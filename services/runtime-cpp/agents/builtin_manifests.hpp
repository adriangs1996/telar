#pragma once

#include "manifest.hpp"

namespace telar::runtime {

inline AgentManifests makeBuiltinManifests() {
  AgentManifests table;
  for (const auto provider : {AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode}) {
    const auto description = describeProvider(provider);
    auto &manifest = table.add(description.name);
    manifest.display_name.assign(description.display_name);
    manifest.attachments = description.attachments;
    manifest.interrupt = AgentInterruptKey::escape;
    manifest.process_names.append(provider == AgentProvider::cursor ? "cursor-agent" : description.name);
  }

  auto &claude = table.add("claude");
  claude.process_names.append("claude-code");
  claude.process_paths.append("/@anthropic-ai/claude-code/");
  claude.process_paths.append("\\@anthropic-ai\\claude-code\\");
  claude.brand.append("claude");
  claude.identity.append("claude code");
  claude.addCommandTool("Bash", "command");
  claude.interrupt = AgentInterruptKey::control_c;
  for (const auto phrase : {"press enter to confirm", "enter to submit answer", "enter to select", "allow command?", "[y/n]", "do you want to proceed?", "waiting for permission", "yes, and don't ask again"}) {
    claude.blocked.append(phrase);
  }

  for (const auto phrase : {"esc to interrupt", "working (", "waiting for background agents", "tasks still running", "background shells"}) {
    claude.working.append(phrase);
  }

  auto &codex = table.add("codex");
  codex.process_paths.append("/@openai/codex/");
  codex.process_paths.append("\\@openai\\codex\\");
  codex.brand.append("codex");
  codex.ready_prompt.append("ask codex to do anything");
  codex.addCommandTool("Bash", "command");
  codex.addCommandTool("exec_command", "cmd");
  codex.addCommandTool("shell", "command");

  auto &pi = table.add("pi");
  pi.process_paths.append("/@earendil-works/pi-coding-agent/");
  pi.process_paths.append("\\@earendil-works\\pi-coding-agent\\");
  pi.process_paths.append("/@mariozechner/pi-coding-agent/");
  pi.process_paths.append("\\@mariozechner\\pi-coding-agent\\");
  pi.addCommandTool("bash", "command");

  auto &cursor = table.add("cursor");
  cursor.process_paths.append("/cursor-agent/versions/");
  cursor.addCommandTool("Shell", "command");
  for (const auto phrase : {"not in allowlist:", "skip & tell the agent what to do instead", "yes, build locally", "do you trust the contents of this directory?"}) {
    cursor.blocked.append(phrase);
  }

  auto &opencode = table.add("opencode");
  opencode.interrupt = AgentInterruptKey::escape_twice;
  opencode.addCommandTool("bash", "command");
  return table;
}

inline const AgentManifests builtin_manifests = makeBuiltinManifests();

}
