module telar.cli.control_session;

import telar.sys.posix;
import telar.sys.socket;
import telar.platform.error;
import telar.client;
import telar.cli.output;

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
    case FailureCode::permission_denied:
      return "permission denied for the runtime's user";
    case FailureCode::process_not_found:
      return "the process is gone, or another process has its pid now";
    default:
      return "runtime refused the request";
    }
  }

  int commandFailure(const char* family, const std::exception& error) {
    const auto* system = dynamic_cast<const SystemError*>(&error);
    const auto socket_timeout = (dynamic_cast<const SocketError*>(&error) != nullptr) && (sys::lastError() == EAGAIN || sys::lastError() == EWOULDBLOCK);
    const auto timeout = socket_timeout || ((system != nullptr) && (system->code() == EAGAIN || system->code() == EWOULDBLOCK));

    std::fprintf(stderr, "%s: %s\n", family, timeout ? "RuntimeTimeout" : error.what());
    if (timeout) {
      return 1;
    }

    if (const auto* failure = dynamic_cast<const Failure*>(&error)) {
      return failure->status();
    }

    if (const auto* failure = dynamic_cast<const ControlFailure*>(&error)) {
      return (failure->code() == FailureCode::pane_not_found || failure->code() == FailureCode::pane_exited || failure->code() == FailureCode::process_not_found || (std::string_view{family} == "telar agent" && failure->code() == FailureCode::worktree_not_found)) ? 2 : 1;
    }

    return 1;
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
    return message_.view();
  }

  ControlSession::ControlSession(Memory& memory, const char* socket, std::size_t reply_bytes, std::size_t request_bytes)
      : connection_(socket),
        outgoing_(memory),
        incoming_(memory),
        decoded_(memory) {
    outgoing_.resize(request_bytes);
    incoming_.resize(reply_bytes);
    decoded_.resize(reply_bytes);
  }

  void ControlSession::receiveTimeout(unsigned seconds) {
    connection_.receiveTimeout(seconds);
  }

}
