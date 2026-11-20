module;
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_base/diagnostics/timing.hpp"

export module telar.base.diagnostics;

import std;
import telar.base.memory.containers;
import telar.base.ds;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar {
  using telar::accumulate;
  using telar::LimitReach;
  using telar::Timing;
}

export {
  namespace telar {

    class TimedScope {
    public:
      using Clock = std::chrono::steady_clock;

      explicit TimedScope(Timing& timing) noexcept;
      explicit TimedScope(Timing* timing) noexcept;
      ~TimedScope();

      TimedScope(const TimedScope&) = delete;
      TimedScope& operator=(const TimedScope&) = delete;

    private:
      Timing* timing_;
      Clock::time_point started_;
    };

  }
}

// Interface: telar_base/diagnostics/limit_ledger.cppm
export {
  namespace telar::runtime {

    std::int64_t wallMilliseconds() noexcept;

    constexpr std::uint64_t saturatedAdd(std::uint64_t left, std::uint64_t right) noexcept {
      return left + std::min(right, std::numeric_limits<std::uint64_t>::max() - left);
    }

    class LimitLedger {
    public:
      struct Row {
        FixedText<64> name;
        FixedText<32> noun;
        FixedText<32> route;
        std::uint64_t value = 0;
        ds::Option<std::uint64_t> requested;
        std::uint64_t hits = 0;
        std::int64_t last_ms = 0;
        ds::Option<std::chrono::steady_clock::time_point> shown;

        [[nodiscard]] LimitReach reach() const noexcept;
      };

      struct Recorded {
        const Row& row;
        bool show;
        std::size_t slot;
      };

      Recorded record(const LimitReach& reach, std::uint32_t hits);
      [[nodiscard]] std::span<const Row> rows() const noexcept;
      [[nodiscard]] std::uint64_t evicted() const noexcept;

      static constexpr std::size_t capacity = 128;

    private:
      ds::Array<Row, capacity> rows_{};
      std::size_t count_ = 0;
      std::uint64_t evicted_ = 0;
    };

  }
}
