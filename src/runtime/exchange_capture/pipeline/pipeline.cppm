module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"
#include <cstdlib>
#include <new>
#include <unistd.h>

#include <cstdint>

#include <cassert>
#include <cstddef>
#include <cstring>

#include <brotli/decode.h>
#include <pthread.h>
#include <zlib.h>
#include <zstd.h>

#include <cerrno>

export module telar.runtime.exchange_capture.pipeline;

import std;
import telar.tbc;

export import telar.runtime.vocabulary.exchange;
export import telar.base.memory.allocators;
export import telar.base.memory.containers;

export import telar.runtime.exchange_capture.producer;

export import telar.runtime.platform.request_worker;
import telar.base.diagnostics;
import telar.platform.primitives;
import telar.platform.thread;

// Interface: exchange_capture/clock.cppm
export {
  namespace telar::runtime {

    template <typename Clock>
    concept CaptureClock = requires {
      { Clock::now() } noexcept -> std::same_as<std::int64_t>;
    };

    struct CaptureWallClock {
      static std::int64_t now() noexcept;
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
        full,
      };

      struct Result {
        State state;
        CapturedExchange<Memory> exchange;
      };

      // The joiner holds halves until their peers arrive, and the halves keep their quota: region `a`.
      explicit CaptureJoiner(tbc::view<Memory&, tbc::lt::a> memory, std::chrono::milliseconds timeout) noexcept;

      tbc::view<Result, tbc::lt::a> push(std::int64_t now_ms, tbc::view<Half, tbc::lt::a> half) noexcept;

      tbc::view<std::optional<CapturedExchange<Memory>>, tbc::lt::a> expire(std::int64_t now_ms) noexcept;

      static constexpr std::size_t capacity = 256;

    private:
      struct Entry {
        Half half;
        std::int64_t expires_at_ms;
      };

      std::optional<std::size_t> find(CaptureKey key) const noexcept;

      tbc::view<Memory&, tbc::lt::a> memory_;
      std::int64_t timeout_ms_;
      tbc::view<std::array<std::optional<Entry>, capacity>, tbc::lt::a> slots_;
      SlotIndexes<capacity> occupied_;
    };

    extern template class CaptureJoiner<ConcurrentMemory>;

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

      explicit CaptureReceiver(CaptureProducer<Memory>& producer) noexcept;

      Result observe(const Request& request) noexcept;

      void stop() noexcept;

    private:
      CaptureProducer<Memory>& producer_;
      bool named_ = false;
    };

    extern template class CaptureReceiver<ConcurrentMemory>;

  }
}

// Interface: exchange_capture/tap.cppm
export {
  namespace telar::runtime {

    template <typename Tap, typename Memory>
    concept CaptureTap = Allocator<Memory> && requires(Tap& tap, CapturedExchange<Memory>& exchange) {
      { tap.listening() } noexcept -> std::same_as<bool>;
      { tap.submit(exchange) } noexcept -> std::same_as<void>;
    };

    struct IgnoreCaptureTap {
      constexpr bool listening() const noexcept {
        return false;
      }

      template <Allocator Memory>
      constexpr void submit(CapturedExchange<Memory>&) noexcept {}
    };

  }
}

// Interface: exchange_capture/pipeline.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's tap and clock.
    template <ConcurrentAllocator Memory, typename Tap, CaptureClock Clock = CaptureWallClock>
      requires CaptureTap<Tap, Memory>
    class TBC_HOT_PATH CapturePipeline {
    public:
      inline explicit CapturePipeline(Memory& memory, CaptureProducer<Memory>& producer, ProxyCaptureLimits limits, Tap& tap)
          : tap_(tap),
            joiner_(memory, limits.join_timeout),
            worker_(std::in_place, producer) {
        worker_.submit({tap_.listening()});
      }

      inline int descriptor() const noexcept {
        return worker_.descriptor();
      }

      inline bool collect() noexcept {
        TELAR_TRACE("proxy.collectCaptures");
        const auto now = Clock::now();

        while (auto expired = joiner_.expire(now)) {
          tap_.submit(*expired);
        }

        bool full = false;

        worker_.collect([&](auto& half) noexcept {
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
      Tap& tap_;
      CaptureJoiner<Memory> joiner_;
      ObservationWorker<CaptureReceiver<Memory>> worker_;
    };

  }
}
