#pragma once

#include "../platform/observation_worker.hpp"
#include "clock.hpp"
#include "joiner.hpp"
#include "receiver.hpp"
#include "tap.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, typename Tap, CaptureClock Clock = CaptureWallClock>
  requires CaptureTap<Tap, Memory>
class CapturePipeline {
public:
  explicit CapturePipeline(Memory &memory, CaptureProducer<Memory> &producer, ProxyCaptureLimits limits, Tap &tap)
      : tap_(tap), receiver_(producer), joiner_(memory, limits.join_timeout), worker_(receiver_) {
    worker_.submit({tap_.listening()});
  }

  int descriptor() const noexcept { return worker_.descriptor(); }

  bool collect() noexcept {
    TELAR_TRACE("proxy.collectCaptures");
    const auto now = Clock::now();
    while (auto expired = joiner_.expire(now)) {
      tap_.submit(*expired);
    }

    bool full = false;
    worker_.collect([&](auto &half) noexcept {
      if (!half) {
        return;
      }

      worker_.submit({tap_.listening()});
      auto joined = joiner_.push(now, std::move(*half));
      using State = typename CaptureJoiner<Memory>::State;
      if (joined.state != State::pending) {
        tap_.submit(joined.exchange);
      }
      full = joined.state == State::full;
    });
    return full;
  }

private:
  Tap &tap_;
  CaptureReceiver<Memory> receiver_;
  CaptureJoiner<Memory> joiner_;
  ObservationWorker<CaptureReceiver<Memory>> worker_;
};

}
