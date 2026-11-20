module telar.base.diagnostics;

import std;

namespace telar {

  TimedScope::TimedScope(Timing& timing) noexcept
      : TimedScope(&timing) {}

  TimedScope::TimedScope(Timing* timing) noexcept
      : timing_(timing),
        started_(timing == nullptr ? Clock::time_point{} : Clock::now()) {}

  TimedScope::~TimedScope() {
    if (timing_ != nullptr) {
      timing_->observe(static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started_).count()));
    }
  }

}

namespace telar::runtime {

  std::int64_t wallMilliseconds() noexcept {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }

  LimitReach LimitLedger::Row::reach() const noexcept {
    return {.name = name.view(), .noun = noun.view(), .value = value, .requested = requested, .route = route.view()};
  }

  LimitLedger::Recorded LimitLedger::record(const LimitReach& reach, std::uint32_t hits) {
    Row* row = nullptr;

    for (auto& candidate : rows_.viewMut().first(count_)) {
      if (candidate.name.view() == reach.name) {
        row = &candidate;
        break;
      }
    }

    if (row == nullptr) {
      if (count_ < capacity) {
        row = &rows_.atMut(count_++);
      } else {
        // Every row is taken: the one recorded longest ago makes room.
        row = &*std::ranges::min_element(rows_.viewMut().first(count_), {}, &Row::last_ms);
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

    return {.row = *row, .show = show, .slot = static_cast<std::size_t>(row - rows_.data())};
  }

  std::span<const LimitLedger::Row> LimitLedger::rows() const noexcept {
    return std::span{rows_}.first(count_);
  }

  std::uint64_t LimitLedger::evicted() const noexcept {
    return evicted_;
  }

}
