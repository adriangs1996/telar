#pragma once

#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime::cli {

inline constexpr const char *missing_pane_context = "TELAR_PANE_ID is not set; run inside a telar pane or name a pane";

inline const char *controlFailureDescription(FailureCode code) noexcept {
  switch (code) {
  case FailureCode::pane_not_found:
    return "pane not found or its generation is stale";
  case FailureCode::pane_exited:
    return "pane already exited";
  case FailureCode::agent_blocked:
    return "agent is waiting for a decision; answer it before prompting";
  case FailureCode::invalid_request:
    return "runtime rejected the request";
  case FailureCode::worktree_not_found:
    return "no tracked worktree matches that branch or title";
  case FailureCode::workspace_not_found:
    return "workspace not found";
  case FailureCode::pane_focused:
    return "that pane has the focus in an attached telar window, where a person may type; try again once another pane has it, or open tabs for automation with `telar tab create --background`";
  case FailureCode::prompt_rate_limited:
    return "prompt budget for that pane is spent; wait for its answer with `telar agent wait`";
  case FailureCode::agent_not_working:
    return "the agent is not working; nothing to interrupt";
  case FailureCode::interrupt_unsupported:
    return "that agent declares no interrupt key";
  case FailureCode::foreign_process:
    return "only a process inside that pane may report for its agent";
  default:
    return "runtime refused the request";
  }
}

}
