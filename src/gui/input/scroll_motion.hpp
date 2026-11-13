#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace telar::gui {

// How a pane's scroll position moves between frames, in logical pixels from the top of the
// rows it shows. Input says where it goes; `advance` takes it there, one display frame at a time.
struct ScrollTuning {
  static constexpr double default_wheel_ms = 80;
  static constexpr double default_friction = 0.997;
  static constexpr double default_glide_min_ms = 200;
  static constexpr double default_glide_max_ms = 520;

  // A wheel notch settles in about this long: each `wheel_ms` closes 1 - 1/e of what is left.
  double wheel_ms = default_wheel_ms;
  // A fling keeps this fraction of its speed every millisecond.
  double friction = default_friction;
  // A jump glides at least and at most this long, longer for longer distances.
  double glide_min_ms = default_glide_min_ms;
  double glide_max_ms = default_glide_max_ms;
};

// A moment on the monotonic clock the frames are paced by.
struct ScrollTime {
  std::int64_t nanoseconds = 0;

  [[nodiscard]] constexpr double millisecondsSince(ScrollTime earlier) const noexcept {
    constexpr double nanoseconds_per_ms = 1e6;
    return static_cast<double>(nanoseconds - earlier.nanoseconds) / nanoseconds_per_ms;
  }
};

class ScrollMotion {
public:
  explicit ScrollMotion(ScrollTuning tuning = {}) noexcept
      : tuning_(tuning) {}

  void tune(ScrollTuning tuning) noexcept {
    tuning_ = tuning;
  }

  [[nodiscard]] double position() const noexcept {
    return position_;
  }

  [[nodiscard]] double limit() const noexcept {
    return limit_;
  }

  [[nodiscard]] bool moving() const noexcept {
    return kind_ != Kind::rest;
  }

  // Gliding to the end, which may move while it glides.
  [[nodiscard]] bool towardEnd() const noexcept {
    return kind_ == Kind::glide && to_end_;
  }

  // Where the motion comes to rest, as far as it is known now.
  [[nodiscard]] double destination() const noexcept {
    switch (kind_) {
    case Kind::ease:
      return target_;
    case Kind::glide:
      return to_end_ ? limit_ : target_;
    case Kind::fling: {
      // The geometric series of a speed that decays by `friction` every millisecond.
      constexpr double least_loss = 1e-6;
      const auto travel = velocity_ / std::max(least_loss, 1 - tuning_.friction);
      return std::clamp(position_ + travel, 0.0, limit_);
    }
    case Kind::rest:
    case Kind::follow:
      break;
    }
    return position_;
  }

  // The farthest the position may go, the rows past the first view; the position and any
  // target stay within it.
  void setLimit(double limit) noexcept {
    limit_ = std::isfinite(limit) ? std::max(0.0, limit) : 0;
    position_ = std::clamp(position_, 0.0, limit_);
    target_ = std::clamp(target_, 0.0, limit_);
  }

  // At rest here, at once.
  void place(double position) noexcept {
    stop();
    position_ = bounded(position);
  }

  void stop() noexcept {
    kind_ = Kind::rest;
    velocity_ = 0;
    to_end_ = false;
    history_size_ = 0;
    history_next_ = 0;
  }

  // A precise device's distance, followed one to one: what the finger moves is what the rows
  // move. Its speed is remembered for a fling when the platform does not continue it.
  void follow(double delta, ScrollTime now) noexcept {
    if (!std::isfinite(delta)) {
      return;
    }
    if (kind_ != Kind::rest && kind_ != Kind::follow) {
      stop();
    }
    kind_ = Kind::follow;
    position_ = bounded(position_ + delta);
    sample(delta, now);
    last_ = now;
  }

  // A precise gesture ended: at rest, or flung on with the speed of its last moments.
  void release(ScrollTime now) noexcept {
    const auto speed = recentSpeed(now);
    history_size_ = 0;
    if (kind_ != Kind::follow) {
      return;
    }
    kind_ = Kind::rest;
    fling(speed, now);
  }

  // A gesture ended without a fling of its own: whatever the platform sends next continues it.
  void settle() noexcept {
    if (kind_ == Kind::follow) {
      kind_ = Kind::rest;
    }
    history_size_ = 0;
  }

  // A wheel's distance, added to where the last notches were going; the position eases there.
  void wheel(double delta, ScrollTime now) noexcept {
    if (!std::isfinite(delta) || delta == 0) {
      return;
    }
    const auto from = kind_ == Kind::ease ? target_ : position_;
    if (kind_ != Kind::ease) {
      stop();
      last_ = now;
    }
    kind_ = Kind::ease;
    target_ = bounded(from + delta);
  }

  // On at `velocity` pixels a millisecond, slowing by the friction.
  void fling(double velocity, ScrollTime now) noexcept {
    constexpr double slowest = 0.05;
    constexpr double fastest = 8;
    if (!std::isfinite(velocity) || std::abs(velocity) < slowest) {
      return;
    }
    stop();
    kind_ = Kind::fling;
    velocity_ = std::clamp(velocity, -fastest, fastest);
    last_ = now;
  }

  // To `target`, easing out, in a time that grows with the distance. Farther than three views
  // away, the position first jumps to a view and a half before it: the glide shows the
  // direction and the arrival without crossing everything between.
  void glide(double target, ScrollTime now, double viewport) noexcept {
    if (!std::isfinite(target)) {
      return;
    }
    beginGlide({.target = bounded(target), .viewport = viewport}, now);
  }

  // To the end, which may grow while it glides, as output arrives.
  void glideToEnd(ScrollTime now, double viewport) noexcept {
    beginGlide({.target = limit_, .viewport = viewport, .to_end = true}, now);
  }

  // Moves the position to `now`. Whether it still moves.
  bool advance(ScrollTime now) noexcept {
    if (kind_ == Kind::rest || kind_ == Kind::follow) {
      return false;
    }
    constexpr double longest_frame_ms = 50;
    const auto elapsed = std::clamp(now.millisecondsSince(last_), 0.0, longest_frame_ms);
    last_ = now;
    switch (kind_) {
    case Kind::ease:
      advanceEase(elapsed);
      break;
    case Kind::fling:
      advanceFling(elapsed);
      break;
    case Kind::glide:
      advanceGlide(now);
      break;
    case Kind::rest:
    case Kind::follow:
      break;
    }
    return moving();
  }

private:
  enum class Kind : std::uint8_t {
    rest,
    // A precise device moves the position itself; nothing to advance.
    follow,
    ease,
    fling,
    glide,
  };

  struct Glide {
    double target = 0;
    double viewport = 1;
    bool to_end = false;
  };

  struct Sample {
    ScrollTime time;
    double delta = 0;
  };

  static constexpr double settled = 0.25;
  static constexpr std::size_t sample_capacity = 8;
  // The speed of a gesture's last moments, over at most this long.
  static constexpr double speed_window_ms = 80;
  // A glide farther than this many views starts this many views before its target.
  static constexpr double far_views = 3;
  static constexpr double approach_views = 1.5;
  // Each pixel's square root adds this many milliseconds to a glide.
  static constexpr double glide_ms_per_root_pixel = 7;

  [[nodiscard]] double bounded(double position) const noexcept {
    return std::clamp(std::isfinite(position) ? position : 0.0, 0.0, limit_);
  }

  void advanceEase(double elapsed) noexcept {
    const auto left = target_ - position_;
    if (std::abs(left) < settled) {
      position_ = target_;
      stop();
      return;
    }
    position_ = bounded(position_ + (left * (1 - std::exp(-elapsed / std::max(1.0, tuning_.wheel_ms)))));
  }

  void advanceFling(double elapsed) noexcept {
    constexpr double most_kept = 0.9999;
    constexpr double stopped = 0.01;
    const auto next = position_ + (velocity_ * elapsed);
    position_ = bounded(next);
    velocity_ *= std::pow(std::clamp(tuning_.friction, 0.0, most_kept), elapsed);
    if (next != position_ || std::abs(velocity_) < stopped) {
      stop();
    }
  }

  void advanceGlide(ScrollTime now) noexcept {
    const auto target = to_end_ ? limit_ : target_;
    const auto progress = std::clamp(now.millisecondsSince(start_) / duration_ms_, 0.0, 1.0);
    const auto eased = 1 - std::pow(1 - progress, 3);
    position_ = bounded(from_ + ((target - from_) * eased));
    if (progress >= 1) {
      position_ = bounded(target);
      stop();
    }
  }

  void beginGlide(Glide glide, ScrollTime now) noexcept {
    const auto view = std::isfinite(glide.viewport) ? std::max(1.0, glide.viewport) : 1.0;
    auto from = position_;
    stop();
    if (std::abs(glide.target - from) > far_views * view) {
      from = glide.target - std::copysign(approach_views * view, glide.target - from);
    }
    position_ = bounded(from);
    const auto distance = std::abs(glide.target - position_);
    if (distance < settled) {
      position_ = glide.target;
      return;
    }
    kind_ = Kind::glide;
    to_end_ = glide.to_end;
    from_ = position_;
    target_ = glide.target;
    start_ = now;
    last_ = now;
    const auto longest = std::max(tuning_.glide_min_ms, tuning_.glide_max_ms);
    duration_ms_ = std::clamp(tuning_.glide_min_ms + (std::sqrt(distance) * glide_ms_per_root_pixel), tuning_.glide_min_ms, longest);
  }

  // The last `sample_capacity` deltas of a gesture, oldest overwritten first.
  void sample(double delta, ScrollTime now) noexcept {
    history_[history_next_] = {.time = now, .delta = delta};
    history_next_ = (history_next_ + 1) % sample_capacity;
    history_size_ = std::min(history_size_ + 1, sample_capacity);
  }

  [[nodiscard]] const Sample &recent(std::size_t back) const noexcept {
    return history_[(history_next_ + sample_capacity - 1 - back) % sample_capacity];
  }

  [[nodiscard]] double recentSpeed(ScrollTime now) const noexcept {
    if (history_size_ < 2) {
      return 0;
    }
    // A gesture that rested before it ended has no speed left to carry on.
    if (now.millisecondsSince(recent(0).time) > speed_window_ms / 2) {
      return 0;
    }
    double distance = 0;
    ScrollTime first = now;
    std::size_t counted = 0;
    for (std::size_t back = 0; back < history_size_ && now.millisecondsSince(recent(back).time) <= speed_window_ms; ++back) {
      distance += recent(back).delta;
      first = recent(back).time;
      ++counted;
    }
    if (counted < 2) {
      return 0;
    }
    constexpr double shortest_ms = 8;
    return distance / std::max(shortest_ms, now.millisecondsSince(first));
  }

  ScrollTuning tuning_;
  double position_ = 0;
  double limit_ = 0;
  double target_ = 0;
  double from_ = 0;
  double velocity_ = 0;
  double duration_ms_ = 0;
  ScrollTime start_;
  ScrollTime last_;
  std::array<Sample, sample_capacity> history_{};
  std::size_t history_size_ = 0;
  std::size_t history_next_ = 0;
  Kind kind_ = Kind::rest;
  bool to_end_ = false;
};

}
