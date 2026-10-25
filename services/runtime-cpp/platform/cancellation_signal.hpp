#pragma once

#include "completion_signal.hpp"
#include <atomic>

namespace telar::runtime {

class CancellationSignal {
public:
  void request() noexcept {
    requested_.store(true, std::memory_order_relaxed);
    wake_.notify();
  }

  bool requested() const noexcept { return requested_.load(std::memory_order_relaxed); }
  int descriptor() const noexcept { return wake_.descriptor(); }

private:
  CompletionSignal wake_;
  std::atomic<bool> requested_{false};
};

}
