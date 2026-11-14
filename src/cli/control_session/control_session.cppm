module;
#include "tbc/annotations.hpp"

export module telar.cli.control_session;

import std;
import telar.tbc;

export import telar.client;

import telar.base.diagnostics;
import telar.base.memory.allocators;
import telar.wire.vocabulary;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.platform.error;

// Interface: control_failure.cppm
export {
  namespace telar::runtime::cli {

    inline constexpr const char* missing_pane_context = "TELAR_PANE_ID is not set; run inside a telar pane or name a pane";

    const char* controlFailureDescription(FailureCode code) noexcept;

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

      // Generic over the protocol's messages, an open set, so it stays a template
      // here.
      template <typename Message>
      TBC_GENERIC inline void send(const Message& message, std::span<Byte> buffer) {
        client_.send(message, buffer);
      }

      tbc::view<std::span<const Byte>, tbc::lt::a> receive(tbc::view<std::span<Byte>, tbc::lt::a> buffer);

      void receiveTimeout(unsigned seconds);

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
      explicit ControlFailure(FailureCode code, std::string_view message = {});

      [[nodiscard]] FailureCode code() const noexcept;

      std::string_view message() const noexcept;

    private:
      FailureCode code_;
      std::string message_;
    };

    // One conversation with the runtime, as every command that addresses panes, tabs,
    // workspaces or agents has: each request gets the next id, and `exchange` returns
    // the reply that answers it or throws the runtime's refusal as `ControlFailure`.
    // A decoded reply borrows the session's storage until the next exchange.
    class ControlSession {
    public:
      // `reply_bytes` bounds one reply and what decoding it may borrow; small fixed
      // replies, as hooks get, need far less than the protocol's 4 MiB frames.
      ControlSession(Memory& memory, const char* socket, std::size_t reply_bytes = max_payload_size, std::size_t request_bytes = maximum_request_bytes);

      void receiveTimeout(unsigned seconds);

      // The members generic over the protocol's messages keep their bodies here,
      // marked TBC_GENERIC: the messages are an open set that no implementation
      // unit can instantiate ahead.
      template <typename Request>
      TBC_GENERIC inline void send(Request request) {
        if constexpr (requires { request.request_id; }) {
          request.request_id = next_request_++;
        }

        connection_.send(request, outgoing_);
      }

      template <typename Reply, typename Request>
      TBC_GENERIC inline Reply exchange(Request request) {
        request.request_id = next_request_++;
        connection_.send(request, outgoing_);
        return receive<Reply>(request.request_id);
      }

      // Subscription events may interleave with a reply; snapshots have no request id.
      template <typename Reply>
      TBC_GENERIC inline Reply receive(std::optional<std::uint64_t> request_id = std::nullopt) {
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
