#pragma once

#include "control_failure.hpp"
#include "runtime_connection.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>

namespace telar::runtime::cli {

// The runtime refused a request; `what()` is the text scripts read on stderr.
class ControlFailure final : public std::runtime_error {
public:
  explicit ControlFailure(FailureCode code)
      : std::runtime_error{controlFailureDescription(code)},
        code_(code) {}

  [[nodiscard]] FailureCode code() const noexcept {
    return code_;
  }

private:
  FailureCode code_;
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
  ControlSession(Memory &memory, const char *socket, std::size_t reply_bytes = max_payload_size)
      : connection_(socket),
        outgoing_(maximum_request_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
        incoming_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}),
        decoded_(reply_bytes, Byte{}, AllocatorRef<Byte, Memory>{memory}) {}

  void receiveTimeout(unsigned seconds) {
    connection_.receiveTimeout(seconds);
  }

  template <typename Request>
  void send(Request request) {
    if constexpr (requires { request.request_id; }) {
      request.request_id = next_request_++;
    }

    connection_.send(request, outgoing_);
  }

  template <typename Reply, typename Request>
  Reply exchange(Request request) {
    request.request_id = next_request_++;
    connection_.send(request, outgoing_);
    for (;;) {
      const auto frame = connection_.receive(incoming_);
      DecodeStorage storage{decoded_};
      if (frame.front() == static_cast<Byte>(MessageSchema<Reply>::tag)) {
        auto reply = Codec::decode<Reply>(frame, storage);
        if (reply.request_id == request.request_id) {
          return reply;
        }
      } else if (frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
        const auto failure = Codec::decode<RequestFailed>(frame, storage);
        if (failure.request_id == request.request_id) {
          throw ControlFailure{failure.code};
        }
      } else {
        throw EncodingError{"Unexpected reply from the runtime"};
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
