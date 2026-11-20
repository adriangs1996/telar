module;
#include "tbc/annotations.hpp"

export module telar.cli.session.control_session;

import std;
import telar.tbc;

import telar.client;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.wire.vocabulary;
import telar.wire.runtime;
import telar.base.ds;

// Interface: control_failure.cppm
export {
  namespace telar::runtime::cli {

    inline constexpr const char* missing_pane_context = "TELAR_PANE_ID is not set; run inside a telar pane or name a pane";

    const char* controlFailureDescription(FailureCode code) noexcept;

    // Prints a command's failure on stderr as `family: what` and returns its exit status: the
    // failure's own, 2 when the runtime names a pane or process that is gone, 1 otherwise.
    int commandFailure(const char* family, const std::exception& error);

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
      RuntimeConnection(RuntimeConnection&&) = delete;
      RuntimeConnection& operator=(RuntimeConnection&&) = delete;

      void requestStop();
      [[noreturn]] void bridge();

      // Generic over the protocol's messages, an open set, so it stays a template
      // here.
      template <typename Message>
      TBC_GENERIC inline void send(const Message& message, std::span<Byte> buffer) {
        client_.send(message, buffer);
      }

      tbc::val_a<std::span<const Byte>> receive(tbc::val_a<std::span<Byte>> buffer);

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

      [[nodiscard]] std::string_view message() const noexcept;

    private:
      static constexpr std::size_t message_capacity = 1023;

      FailureCode code_;
      ErrorText<message_capacity> message_;
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

        connection_.send(request, outgoing_.viewMut());
      }

      template <typename Reply, typename Request>
      TBC_GENERIC inline Reply exchange(Request request) {
        request.request_id = next_request_++;
        connection_.send(request, outgoing_.viewMut());
        return receive<Reply>(request.request_id);
      }

      // Subscription events may interleave with a reply; snapshots have no request id.
      template <typename Reply>
      TBC_GENERIC inline Reply receive(ds::Option<std::uint64_t> request_id = ds::none) {
        for (;;) {
          const auto frame = connection_.receive(incoming_.viewMut());
          DecodeStorage storage{decoded_.viewMut()};

          if (frame.front() != static_cast<Byte>(MessageSchema<Reply>::tag)) {
            refuse(frame, request_id, storage);
            continue;
          }

          auto reply = Codec::decode<Reply>(frame, storage);

          if constexpr (requires { reply.request_id; }) {
            if (request_id && reply.request_id != *request_id) {
              continue;
            }
          }

          return reply;
        }
      }

    private:
      // Throws the refusal of the request `request_id` names, or of any when it names none, and the
      // runtime's stop; a frame that carries neither passes.
      static void refuse(std::span<const Byte> frame, ds::Option<std::uint64_t> request_id, DecodeStorage& storage);

      static constexpr std::size_t maximum_request_bytes = 65536 + 4096 + 1024;

      RuntimeConnection connection_;
      ds::Vec<Byte, Memory> outgoing_;
      ds::Vec<Byte, Memory> incoming_;
      ds::Vec<Byte, Memory> decoded_;
      std::uint64_t next_request_ = 1;
    };

  }
}
