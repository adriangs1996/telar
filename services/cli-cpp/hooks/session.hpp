#pragma once

#include "../control_session.hpp"
#include "telar_platform/trace.hpp"

namespace telar::runtime::cli::hooks {

struct PaneTarget {
  std::uint64_t pane_id;
  std::uint64_t generation;
  AgentProvider provider;
};

// The hook's conversation with the runtime: every report carries the pane and
// provider the hook runs for, and the runtime first verifies the reporter's ancestry.
template <Allocator Memory>
class Session {
public:
  Session(Memory &memory, const char *socket, PaneTarget target)
      : control_(memory, socket, reply_bytes),
        target_(target) {
    control_.receiveTimeout(30);
    exchange(VerifyPaneDescent{});
  }

  template <typename Report>
  void report(Report value) noexcept {
    try {
      TELAR_TRACE("hooks.sendReport");
      exchange(value);
    } catch (const std::exception &) {
    }
  }

  void reportLimit(std::uint64_t received, std::size_t capacity) noexcept {
    try {
      control_.send(ReportLimit{.reach = {.name = "hooks.max_input_bytes", .noun = "bytes", .value = capacity, .requested = received}, .hits = 1});
    } catch (const std::exception &) {
    }
  }

  template <typename Reply = RequestCompleted, typename Report>
  Reply exchange(Report value) {
    if constexpr (requires { value.pane_id; value.pane_generation; }) {
      value.pane_id = target_.pane_id;
      value.pane_generation = target_.generation;
    }
    if constexpr (requires { value.provider = AgentProvider{}; }) {
      value.provider = target_.provider;
    }

    return control_.template exchange<Reply>(value);
  }

private:
  static constexpr std::size_t reply_bytes = 2048;

  ControlSession<Memory> control_;
  PaneTarget target_;
};
}
