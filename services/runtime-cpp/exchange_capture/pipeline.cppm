module;
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <unistd.h>

#include <cstdint>

#include <cassert>
#include <cstddef>
#include <cstring>

#include <pthread.h>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>

#include <cerrno>

export module telar.runtime.exchange_capture.pipeline;

import std;

export import telar.runtime.exchange_capture.exchange;
export import telar.base.memory;


export import telar.platform;
export import telar.runtime.exchange_capture.producer;


export import telar.runtime.platform.request_worker;
import telar.base.diagnostics;
import telar.platform.primitives;

// Interface: exchange_capture/clock.cppm
export {
namespace telar::runtime {

template <typename Clock>
concept CaptureClock = requires {
  { Clock::now() } noexcept -> std::same_as<std::int64_t>;
};

struct CaptureWallClock {
  inline static std::int64_t now() noexcept {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }
};

}
}

// Interface: exchange_capture/joiner.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class CaptureJoiner {
public:
  using Half = typename CapturedExchange<Memory>::Half;
  enum class State {
    pending,
    complete,
    partial,
    full
  };

  struct Result {
    State state;
    CapturedExchange<Memory> exchange;
  };

  inline explicit CaptureJoiner(Memory &memory, std::chrono::milliseconds timeout) noexcept : memory_(memory), timeout_ms_(timeout.count()) {}

  inline Result push(std::int64_t now_ms, Half half) noexcept {
    Result result{State::pending, CapturedExchange<Memory>{memory_}};
    const auto existing = find(half->key);
    if (existing) {
      auto &entry = *slots_[*existing];
      if (entry.half->side == half->side) {
        result.state = State::partial;
      } else {
        result.state = State::complete;
        result.exchange.include(std::move(entry.half));
        slots_[*existing].reset();
        occupied_.erase(*existing);
      }
      result.exchange.include(std::move(half));
      return result;
    }

    const auto available = occupied_.firstUnused();
    if (!available) {
      result.state = State::full;
      result.exchange.include(std::move(half));
      return result;
    }

    const auto maximum_time = std::numeric_limits<std::int64_t>::max();
    const auto deadline = now_ms > maximum_time - timeout_ms_ ? maximum_time : now_ms + timeout_ms_;
    slots_[*available].emplace(std::move(half), deadline);
    occupied_.insert(*available);
    return result;
  }

  inline std::optional<CapturedExchange<Memory>> expire(std::int64_t now_ms) noexcept {
    std::optional<std::size_t> expired;
    occupied_.forEach([&](std::size_t index) {
      if (!expired && slots_[index]->expires_at_ms <= now_ms) {
        expired = index;
      }
    });
    if (!expired) {
      return std::nullopt;
    }

    CapturedExchange<Memory> result{memory_};
    result.include(std::move(slots_[*expired]->half));
    slots_[*expired].reset();
    occupied_.erase(*expired);
    return result;
  }

  static constexpr std::size_t capacity = 256;

private:
  struct Entry {
    Half half;
    std::int64_t expires_at_ms;
  };

  inline std::optional<std::size_t> find(CaptureKey key) const noexcept {
    std::optional<std::size_t> found;
    occupied_.forEach([&](std::size_t index) {
      if (slots_[index]->half->key == key) {
        found = index;
      }
    });
    return found;
  }

  Memory &memory_;
  std::int64_t timeout_ms_;
  std::array<std::optional<Entry>, capacity> slots_;
  SlotIndexes<capacity> occupied_;
};

}
}

// Interface: exchange_capture/receiver.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class CaptureReceiver {
public:
  struct Request {
    bool decode;
  };

  using Result = std::optional<typename CaptureProducer<Memory>::Half>;

  inline explicit CaptureReceiver(CaptureProducer<Memory> &producer) noexcept : producer_(producer) {}

  inline Result observe(const Request &request) noexcept {
    if (!named_) {
      setThreadName("telar.capture");
      named_ = true;
    }

    auto half = producer_.receive();
    if (half && request.decode) {
      producer_.decodeBody(**half);
    }
    return half;
  }

  inline void stop() noexcept { producer_.close(); }

private:
  CaptureProducer<Memory> &producer_;
  bool named_ = false;
};

}
}

// Interface: exchange_capture/tap.cppm
export {
namespace telar::runtime {

template <typename Tap, typename Memory>
concept CaptureTap = Allocator<Memory> && requires(Tap &tap, CapturedExchange<Memory> &exchange) {
  { tap.listening() } noexcept -> std::same_as<bool>;
  { tap.submit(exchange) } noexcept -> std::same_as<void>;
};

struct IgnoreCaptureTap {
  inline bool listening() const noexcept { return false; }

  template <Allocator Memory>
  inline void submit(CapturedExchange<Memory> &) noexcept {}
};

}
}

// Interface: exchange_capture/pipeline.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory, typename Tap, CaptureClock Clock = CaptureWallClock>
  requires CaptureTap<Tap, Memory>
class CapturePipeline {
public:
  inline explicit CapturePipeline(Memory &memory, CaptureProducer<Memory> &producer, ProxyCaptureLimits limits, Tap &tap)
      : tap_(tap), joiner_(memory, limits.join_timeout), worker_(std::in_place, producer) {
    worker_.submit({tap_.listening()});
  }

  inline int descriptor() const noexcept { return worker_.descriptor(); }

  inline bool collect() noexcept {
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
  CaptureJoiner<Memory> joiner_;
  ObservationWorker<CaptureReceiver<Memory>> worker_;
};

}
}
