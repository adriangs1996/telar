#pragma once

#include <algorithm>
#include <chrono>
#include <optional>

namespace telar::runtime {

class FramePacer {
public:
  using Clock = std::chrono::steady_clock;
  using Time = Clock::time_point;

  void configure(std::chrono::nanoseconds interval) noexcept {
    interval_ = interval;
  }

  void noteInput(Time time) noexcept {
    if (time != last_input_) {
      last_input_ = time;
      input_frames_left_ = input_burst;
    }
  }

  std::optional<Time> deadline(Time now) const noexcept {
    const bool input_recent = last_input_ && input_frames_left_ != 0 && now - *last_input_ < input_grace;
    if (available(now) != 0 || input_recent) {
      return std::nullopt;
    }

    return anchor_.value_or(now) + interval_;
  }

  void record(Time now, std::optional<Time> scheduled) noexcept {
    const auto credits = available(now);
    if (credits == 0 && !scheduled && input_frames_left_ != 0) {
      --input_frames_left_;
    }

    credits_ = credits == 0 ? 0 : credits - 1;
    anchor_ = scheduled ? *scheduled + interval_ * ((now - *scheduled) / interval_) : now;
  }

private:
  unsigned available(Time now) const noexcept {
    if (!anchor_) {
      return idle_burst;
    }

    const auto refill = std::max(Clock::duration::zero(), now - *anchor_) / interval_;
    return static_cast<unsigned>(std::min<std::int64_t>(idle_burst, credits_ + refill));
  }

  static constexpr unsigned idle_burst = 4;
  static constexpr unsigned input_burst = 16;
  static constexpr auto input_grace = std::chrono::milliseconds{30};
  std::chrono::nanoseconds interval_{1'000'000'000 / 60};
  std::optional<Time> anchor_;
  std::optional<Time> last_input_;
  unsigned credits_ = idle_burst;
  unsigned input_frames_left_ = 0;
};

}
