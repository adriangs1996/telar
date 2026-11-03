#pragma once

#include "hook_options.hpp"
#include "hooks/input.hpp"
#include "hooks/map.hpp"
#include "hooks/session.hpp"
#include "hooks/target.hpp"
#include "hooks/worktrees.hpp"
#include "telar_platform/runtime_paths.hpp"

namespace telar::runtime::cli {

template <Allocator Memory, EnvironmentLookup Environment>
int runHook(Memory &memory, const HookOptions &options, const Environment &environment) noexcept {
#if TELAR_DEBUG
  std::optional<trace::Session<Memory>> tracing;
  try {
    const String<Memory> path{environment.lookup("TELAR_HOOK_TRACE"), AllocatorRef<char, Memory>{memory}};
    if (!path.empty()) {
      tracing.emplace(memory, path.c_str());
    }
  } catch (const std::exception &) {
  }
#endif

  hooks::Input input{memory};
  int status = 0;
  try {
    input.read(STDIN_FILENO);
    validateUtf8(input.text());
    const auto parsed = JsonValue::parse(input.text());
    hooks::validateUnicodeEscapes(memory, input.text());
    hooks::Object fields{memory, parsed, true};
    const auto worktree_status = options.provider == AgentProvider::claude ? hooks::answerWorktree(memory, environment, fields, options.socket) : std::nullopt;
    status = worktree_status.value_or(0);
    const auto target = hooks::paneTarget(environment, options.provider);
    if (!worktree_status && target) {
      hooks::Payload payload{memory, options.provider, std::move(fields)};
      hooks::Reports reports;
      hooks::SessionFiles files;
      hooks::map(payload, reports, files, environment);
      if (!reports.empty()) {
        ServerOptions server;
        server.socket = options.socket;
        const RuntimePaths paths{memory, server, environment};
        hooks::Session session{memory, paths.socket.c_str(), *target};
        if (reports.progress) {
          session.report(*reports.progress);
        }
        if (reports.lifecycle) {
          session.report(*reports.lifecycle);
        }
        if (reports.title) {
          session.report(*reports.title);
        }
        if (reports.command) {
          session.report(*reports.command);
        }
        if (input.limited()) {
          session.reportLimit(input.received(), input.maximum_bytes);
        }
      }
    }
  } catch (const std::exception &) {
  }

  if (input.limited()) {
    std::fprintf(stderr, "telar: Limit reached: hooks.max_input_bytes: %llu bytes; limit %zu\n", static_cast<unsigned long long>(input.received()), input.maximum_bytes);
  }

  return status;
}

}
