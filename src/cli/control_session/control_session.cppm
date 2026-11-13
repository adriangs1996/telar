module;
#include "tbc/view.hpp"
#include <cstddef>
#include <cstdint>
#include <sys/socket.h>
#include <sys/time.h>

export module telar.cli.control_session;

import std;

export import telar.client;

export import telar.platform.error;
import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.wire.runtime;
import telar.platform.primitives;

// Interface: control_failure.cppm
export {
  namespace telar::runtime::cli {

    inline constexpr const char* missing_pane_context = "TELAR_PANE_ID is not set; run inside a telar pane or name a pane";

    inline const char* controlFailureDescription(FailureCode code) noexcept {
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
}

// Interface: runtime_connection.cppm
export {
  namespace telar::runtime::cli {

    class RuntimeConnection {
    public:
      explicit RuntimeConnection(const char* path, bool negotiate = true);
      ~RuntimeConnection();
      RuntimeConnection(const RuntimeConnection&) = delete;
      RuntimeConnection& operator=(const RuntimeConnection&) = delete;

      void requestStop();
      [[noreturn]] void bridge();

      template <typename Message>
      inline void send(const Message& message, std::span<Byte> buffer) {
        client_.send(message, buffer);
      }

      inline tbc::view<std::span<const Byte>, tbc::lt::a> receive(tbc::view<std::span<Byte>, tbc::lt::a> buffer) {
        return client_.receiveFrame(buffer);
      }

      inline void receiveTimeout(unsigned seconds) {
        const timeval timeout{.tv_sec = static_cast<time_t>(seconds), .tv_usec = 0};
        if (::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) != 0) {
          throw SystemError{"Set runtime reply timeout"};
        }
      }

    private:
      static Client connect(const char* path);
      Client client_;
    };

  }
}

// Interface: control_session.cppm
export {
  namespace telar::runtime::cli {

    // The runtime refused a request; `what()` is the text scripts read on stderr.
    class ControlFailure final : public std::runtime_error {
    public:
      inline explicit ControlFailure(FailureCode code, std::string_view message = {})
          : std::runtime_error{controlFailureDescription(code)},
            code_(code),
            message_(message) {}

      [[nodiscard]] inline FailureCode code() const noexcept {
        return code_;
      }

      inline std::string_view message() const noexcept {
        return message_;
      }

    private:
      FailureCode code_;
      std::string message_;
    };

    // One conversation with the runtime, as every command that addresses panes, tabs,
    // workspaces or agents has: each request gets the next id, and `exchange` returns
    // the reply that answers it or throws the runtime's refusal as `ControlFailure`.
    // A decoded reply borrows the session's storage until the next exchange.
    template <Allocator Memory>
    class ControlSession {
    public:
      // `reply_bytes` bounds one reply and what decoding it may borrow; small fixed
      // replies, as hooks get, need far less than the protocol's 4 MiB frames.
      inline ControlSession(Memory& memory, const char* socket, std::size_t reply_bytes = max_payload_size, std::size_t request_bytes = maximum_request_bytes)
          : connection_(socket),
            outgoing_(request_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
            incoming_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
            decoded_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}) {}

      inline void receiveTimeout(unsigned seconds) {
        connection_.receiveTimeout(seconds);
      }

      template <typename Request>
      inline void send(Request request) {
        if constexpr (requires { request.request_id; }) {
          request.request_id = next_request_++;
        }

        connection_.send(request, outgoing_);
      }

      template <typename Reply, typename Request>
      inline Reply exchange(Request request) {
        request.request_id = next_request_++;
        connection_.send(request, outgoing_);
        return receive<Reply>(request.request_id);
      }

      // Subscription events may interleave with a reply; snapshots have no request id.
      template <typename Reply>
      inline Reply receive(std::optional<std::uint64_t> request_id = std::nullopt) {
        for (;;) {
          const auto frame = connection_.receive(incoming_);
          DecodeStorage storage{decoded_};

          if (frame.front() == static_cast<Byte>(MessageSchema<Reply>::tag)) {
            auto reply = Codec::decode<Reply>(frame, storage);

            if constexpr (requires { reply.request_id; }) {
              if (request_id && reply.request_id != *request_id) {
                continue;
              }
            }

            return reply;
          }

          if (frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
            const auto failure = Codec::decode<RequestFailed>(frame, storage);
            if (!request_id || failure.request_id == *request_id) {
              throw ControlFailure{failure.code, failure.message};
            }
          } else if (frame.front() == static_cast<Byte>(ServerTag::runtime_stopping)) {
            throw std::runtime_error{"RuntimeStopping"};
          }
        }
      }

    private:
      static constexpr std::size_t maximum_request_bytes = 65536 + 4096 + 1024;

      RuntimeConnection connection_;
      Vector<Byte, Memory> outgoing_;
      Vector<Byte, Memory> incoming_;
      Vector<Byte, Memory> decoded_;
      std::uint64_t next_request_ = 1;
    };

  }
}
