module;
#include "telar_base/diagnostics/timing.hpp"
#include <cstring>
#include <stdexcept>
#include <string_view>

#include "telar_base/diagnostics/limit_reach.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <limits>
#include <span>

export module telar.base.diagnostics;

import telar.base.memory;

// Owned textual headers stay in this global module fragment only; importers
// reach their names through these declarations instead of including them.
export namespace telar {
using telar::LimitReach;
using telar::TimedScope;
using telar::Timing;
using telar::accumulate;
}



// Interface: telar_base/diagnostics/limit_ledger.cppm
export {
namespace telar::runtime {

inline std::int64_t wallMilliseconds() noexcept {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

inline std::uint64_t saturatedAdd(std::uint64_t left, std::uint64_t right) noexcept {
  return left + std::min(right, std::numeric_limits<std::uint64_t>::max() - left);
}

class LimitLedger {
public:
  struct Row {
    FixedText<64> name;
    FixedText<32> noun;
    FixedText<32> route;
    std::uint64_t value = 0;
    std::optional<std::uint64_t> requested;
    std::uint64_t hits = 0;
    std::int64_t last_ms = 0;
    std::optional<std::chrono::steady_clock::time_point> shown;

    inline LimitReach reach() const noexcept {
      return {name.view(), noun.view(), value, requested, route.view()};
    }
  };

  struct Recorded {
    const Row &row;
    bool show;
  };

  inline Recorded record(const LimitReach &reach, std::uint32_t hits) {
    auto rows = std::span{rows_}.first(count_);
    auto found = std::find_if(rows.begin(), rows.end(), [&](const Row &row) { return row.name.view() == reach.name; });
    Row *row = found == rows.end() ? nullptr : &*found;
    if (row == nullptr) {
      if (count_ < capacity) {
        row = &rows_[count_++];
      } else {
        row = &*std::min_element(rows.begin(), rows.end(), [](const Row &left, const Row &right) { return left.last_ms < right.last_ms; });
        evicted_ = saturatedAdd(evicted_, 1);
      }

      *row = {};
      row->name.assign(reach.name);
    }

    row->noun.assign(reach.noun);
    row->route.assign(reach.route);
    row->value = reach.value;
    if (reach.requested) {
      row->requested = reach.requested;
    }

    row->hits = saturatedAdd(row->hits, hits);
    row->last_ms = wallMilliseconds();
    const auto now = std::chrono::steady_clock::now();
    const bool show = !row->shown || now - *row->shown >= std::chrono::minutes{1};
    if (show) {
      row->shown = now;
    }

    return {*row, show};
  }

  inline std::span<const Row> rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  inline std::uint64_t evicted() const noexcept {
    return evicted_;
  }

  static constexpr std::size_t capacity = 128;

private:
  std::array<Row, capacity> rows_{};
  std::size_t count_ = 0;
  std::uint64_t evicted_ = 0;
};

}
}
