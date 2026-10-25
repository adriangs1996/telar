#pragma once

#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

enum class ClientRole {
  undecided,
  interactive,
  control
};

inline ClientRole classifyRequest(ClientTag tag) noexcept {
  switch (tag) {
  case ClientTag::runtime_stop:
  case ClientTag::execution_request:
  case ClientTag::query_history:
  case ClientTag::import_history:
  case ClientTag::delete_history:
  case ClientTag::prune_history:
  case ClientTag::read_history_output:
  case ClientTag::history_stats:
  case ClientTag::show_notification:
  case ClientTag::request_client_command:
  case ClientTag::detach_client:
  case ClientTag::query_clients:
  case ClientTag::query_agents:
  case ClientTag::search_pane:
  case ClientTag::read_pane:
  case ClientTag::send_pane_text:
  case ClientTag::report_agent_session:
  case ClientTag::report_agent:
  case ClientTag::report_agent_command:
  case ClientTag::report_agent_title:
  case ClientTag::request_pane_focus:
  case ClientTag::register_worktree:
  case ClientTag::launch_worktree:
  case ClientTag::launch_tab:
  case ClientTag::forget_worktree:
  case ClientTag::interrupt_agent:
  case ClientTag::report_agent_progress:
  case ClientTag::verify_pane_descent:
  case ClientTag::query_limits:
  case ClientTag::report_limit:
    return ClientRole::control;
  default:
    return ClientRole::interactive;
  }
}

struct PendingClientCommand {
  std::uint64_t target;
  std::uint64_t request_id;
  ClientAction action;
  std::uint64_t target_id;
};

struct PendingPaneFocus {
  std::uint64_t target;
  std::uint64_t request_id;
  std::uint64_t pane_id;
  std::uint64_t pane_generation;
};

}
