#pragma once

#include "../memory/drop_channel.hpp"
#include "../platform/completion_signal.hpp"
#include "result.hpp"
#include <limits.h>

namespace telar::runtime::plugins {

template <Allocator Memory>
class ResultQueue {
  static_assert(Limits::queue_depth <= PIPE_BUF);

public:
  void activate() { ready_.emplace(); }

  void publish(OwnedResult<Memory> result) noexcept {
    if (results_.publish(std::move(result))) {
      ready_->notify();
    }
  }

  template <typename Consumer>
  void collect(Consumer &&consumer) {
    if (!ready_ || !ready_->consume()) {
      return;
    }

    auto result = results_.tryReceive();
    if (result) {
      consumer(**result);
    }
  }

  void close() noexcept { results_.close(); }
  int descriptor() const noexcept { return ready_ ? ready_->descriptor() : -1; }

private:
  DropChannel<OwnedResult<Memory>, Limits::queue_depth, ChannelPolicy::keep_oldest> results_;
  std::optional<CompletionSignal> ready_;
};

}
