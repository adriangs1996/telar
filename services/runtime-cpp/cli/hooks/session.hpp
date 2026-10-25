#pragma once

#include "../../diagnostics/trace.hpp"
#include "../control_failure.hpp"
#include "../runtime_connection.hpp"

namespace telar::runtime::cli::hooks {

struct PaneTarget {
  std::uint64_t pane_id;
  std::uint64_t generation;
  AgentProvider provider;
};

class Session {
public:
  explicit Session(const char *socket, PaneTarget target)
      : connection_(socket), target_(target) {
    connection_.receiveTimeout(30);
    exchange<RequestCompleted>(VerifyPaneDescent{});
  }

  template <typename Report>
  void report(Report value) noexcept {
    try {
      TELAR_TRACE("hooks.sendReport");
      exchange<RequestCompleted>(value);
    } catch (const std::exception &) {
    }
  }

  void reportLimit(std::uint64_t received, std::size_t capacity) noexcept {
    try {
      connection_.send(ReportLimit{.reach = {.name = "hooks.max_input_bytes", .noun = "bytes", .value = capacity, .requested = received}, .hits = 1}, outgoing_);
    } catch (const std::exception &) {
    }
  }

  template <typename Reply, typename Report>
  Reply exchange(Report value) {
    value.request_id = next_request_++;
    if constexpr (requires { value.pane_id; value.pane_generation; }) {
      value.pane_id = target_.pane_id;
      value.pane_generation = target_.generation;
    }
    if constexpr (requires { value.provider = AgentProvider{}; }) {
      value.provider = target_.provider;
    }

    connection_.send(value, outgoing_);
    for (;;) {
      const auto frame = connection_.receive(response_);
      if (frame.front() == static_cast<Byte>(MessageSchema<Reply>::tag)) {
        const auto reply = Codec::decode<Reply>(frame);
        if (reply.request_id == value.request_id) {
          return reply;
        }
      } else if (frame.front() == static_cast<Byte>(ServerTag::request_failed)) {
        const auto failure = Codec::decode<RequestFailed>(frame);
        if (failure.request_id == value.request_id) {
          throw EncodingError{controlFailureDescription(failure.code)};
        }
      } else {
        throw EncodingError{"Unexpected hook reply"};
      }
    }
  }

private:
  RuntimeConnection connection_;
  PaneTarget target_;
  std::uint64_t next_request_ = 1;
  static constexpr std::size_t maximum_command_frame_bytes = 65536 + 4096 + 1024;
  std::array<Byte, maximum_command_frame_bytes> outgoing_;
  std::array<Byte, 2048> response_;
};

}
