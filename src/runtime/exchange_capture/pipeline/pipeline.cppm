module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.exchange_capture.pipeline;

import std;
import telar.tbc;

import telar.runtime.vocabulary.exchange;
import telar.base.memory.allocators;
import telar.base.memory.containers;

import telar.runtime.exchange_capture.producer;

import telar.runtime.platform.request_worker;
import telar.platform.primitives;
import telar.config.runtime;

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

    class CaptureJoiner {
    public:
      using Half = CapturedExchange::Half;
      enum class State {
        pending,
        complete,
        partial,
        full,
      };

      struct Result {
        State state;
        CapturedExchange exchange;
      };

      // The joiner holds halves until their peers arrive, and the halves keep their quota: region `a`.
      explicit CaptureJoiner(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, std::chrono::milliseconds timeout) noexcept;

      tbc::view<Result, tbc::lt::a> push(std::int64_t now_ms, tbc::view<Half, tbc::lt::a> half) noexcept;

      tbc::view<std::optional<CapturedExchange>, tbc::lt::a> expire(std::int64_t now_ms) noexcept;

      static constexpr std::size_t capacity = 256;

    private:
      struct Entry {
        Half half;
        std::int64_t expires_at_ms;
      };

      std::optional<std::size_t> find(CaptureKey key) const noexcept;

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      std::int64_t timeout_ms_;
      tbc::view<std::array<std::optional<Entry>, capacity>, tbc::lt::a> slots_;
      SlotIndexes<capacity> occupied_;
    };

  }
}

// Interface: exchange_capture/receiver.cppm
export {
  namespace telar::runtime {

    class CaptureReceiver {
    public:
      struct Request {
        bool decode;
      };

      using Result = std::optional<CaptureProducer::Half>;

      explicit CaptureReceiver(CaptureProducer& producer) noexcept;

      Result observe(const Request& request) noexcept;

      void stop() noexcept;

    private:
      CaptureProducer& producer_;
      bool named_ = false;
    };

  }
}

// Interface: exchange_capture/tap.cppm
export {
  namespace telar::runtime {

    template <typename Tap>
    concept CaptureTap = requires(Tap& tap, CapturedExchange& exchange) {
      { tap.listening() } noexcept -> std::same_as<bool>;
      { tap.submit(exchange) } noexcept -> std::same_as<void>;
    };

    struct IgnoreCaptureTap {
      constexpr bool listening() const noexcept {
        return false;
      }

      constexpr void submit(CapturedExchange&) noexcept {}
    };

  }
}

// Interface: exchange_capture/pipeline.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's tap and clock.
    template <typename Tap, CaptureClock Clock = CaptureWallClock>
      requires CaptureTap<Tap>
    class TBC_GENERIC CapturePipeline {
    public:
      inline explicit CapturePipeline(ConcurrentMemory& memory, CaptureProducer& producer, ProxyCaptureLimits limits, Tap& tap)
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
          using State = CaptureJoiner::State;

          if (joined.state != State::pending) {
            tap_.submit(joined.exchange);
          }

          full = joined.state == State::full;
        });

        return full;
      }

    private:
      Tap& tap_;
      CaptureJoiner joiner_;
      ObservationWorker<CaptureReceiver> worker_;
    };

  }
}
