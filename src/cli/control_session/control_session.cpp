module telar.cli.control_session;

import telar.sys.socket;
import telar.platform.error;

namespace telar::runtime::cli {

  const char* controlFailureDescription(FailureCode code) noexcept {
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

  void RuntimeConnection::receiveTimeout(unsigned seconds) {
    const timeval timeout{.tv_sec = static_cast<std::time_t>(seconds), .tv_usec = 0};
    if (::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
      throw SystemError{"Set runtime reply timeout"};
    }
  }

  ControlFailure::ControlFailure(FailureCode code, std::string_view message)
      : std::runtime_error{controlFailureDescription(code)},
        code_(code),
        message_(message) {}

  FailureCode ControlFailure::code() const noexcept {
    return code_;
  }

  std::string_view ControlFailure::message() const noexcept {
    return message_;
  }

  ControlSession::ControlSession(Memory& memory, const char* socket, std::size_t reply_bytes, std::size_t request_bytes)
      : connection_(socket),
        outgoing_(request_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
        incoming_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
        decoded_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}) {}

  void ControlSession::receiveTimeout(unsigned seconds) {
    connection_.receiveTimeout(seconds);
  }

}
