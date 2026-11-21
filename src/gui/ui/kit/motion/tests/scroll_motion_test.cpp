#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/motion/scroll_motion.hpp"
#include <cmath>
#include <cstddef>
#include <cstdint>

import telar.testing;

namespace {

  using telar::testing::check;
  using namespace telar::gui;

  constexpr std::int64_t millisecond = 1'000'000;

  ScrollTime at(std::int64_t milliseconds) {
    return {.nanoseconds = milliseconds * millisecond};
  }

  // Advances `motion` frame by frame at 120 Hz until it rests; how many frames it took.
  std::size_t settle(ScrollMotion& motion, ScrollTime& now) {
    constexpr std::int64_t frame = 8'333'333;
    constexpr std::size_t most_frames = 1000;
    std::size_t frames = 0;

    while (motion.advance(now = {.nanoseconds = now.nanoseconds + frame})) {
      ++frames;
      check(frames < most_frames, "a motion must come to rest");
    }

    return frames;
  }

  void wheelEasesToItsTarget() {
    constexpr double limit = 1000;
    constexpr double start = 500;
    constexpr double notch = -66;
    constexpr double target = start + (2 * notch);
    constexpr double far = -10'000;
    constexpr std::size_t fewest_frames = 3;
    ScrollMotion motion;

    motion.setLimit(limit);
    motion.place(start);
    auto now = at(0);

    motion.wheel(notch, now);
    motion.wheel(notch, now);
    check(motion.destination() == target, "notches add to where the last ones were going");
    const auto frames = settle(motion, now);

    check(frames > fewest_frames && motion.position() == target && !motion.moving(), "a notch eases over several frames to its target");
    motion.wheel(far, now);
    settle(motion, now);
    check(motion.position() == 0, "a wheel stops at the top");
  }

  void precisePixelsFollowOneToOne() {
    constexpr double limit = 1000;
    constexpr double start = 100;
    constexpr double down = 3.5;
    constexpr double upward = -1.25;
    constexpr double tolerance = 1e-9;
    constexpr std::int64_t second_ms = 8;
    constexpr std::int64_t frame_ms = 16;
    ScrollMotion motion;

    motion.setLimit(limit);
    motion.place(start);
    motion.follow(down, at(0));
    motion.follow(upward, at(second_ms));
    check(std::abs(motion.position() - (start + down + upward)) < tolerance, "a trackpad's pixels move the rows one to one");
    check(!motion.advance(at(frame_ms)), "a followed gesture needs no frames of its own");
    motion.settle();
    check(!motion.moving(), "a gesture the platform continues ends without a fling");
  }

  void releaseFlings() {
    constexpr double limit = 100'000;
    constexpr double start = 1000;
    constexpr double step_pixels = 20;
    constexpr std::int64_t steps = 6;
    constexpr std::int64_t step_ms = 8;
    constexpr std::int64_t later_ms = 1000;
    constexpr std::int64_t rested_ms = 1200;
    ScrollMotion motion;

    motion.setLimit(limit);
    motion.place(start);
    for (std::int64_t step = 0; step < steps; ++step) {
      motion.follow(step_pixels, at(step * step_ms));
    }

    const auto lifted = at(steps * step_ms);

    motion.release(lifted);
    check(motion.moving() && motion.destination() > motion.position(), "a fast gesture flings on");
    const auto left = motion.position();
    auto now = lifted;

    settle(motion, now);
    check(motion.position() > left, "the fling carries the rows past where the finger left them");

    motion.place(start);
    motion.follow(step_pixels, at(later_ms));
    motion.release(at(rested_ms));
    check(!motion.moving(), "a gesture that rested before it ended does not fling");
  }

  void glidesJumpCloseFirst() {
    constexpr double limit = 100'000;
    constexpr double viewport = 400;
    constexpr double target = 50'000;
    constexpr double approach = target - (1.5 * viewport);
    constexpr std::int64_t partway_ms = 100;
    constexpr double end = 1000;
    constexpr double grown = 1200;
    constexpr std::int64_t growth_ms = 50;
    ScrollMotion motion;

    motion.setLimit(limit);
    motion.place(0);
    motion.glide(target, at(0), viewport);
    check(motion.position() == approach, "a far glide starts a view and a half before its target");
    motion.advance(at(partway_ms));
    check(motion.position() > approach && motion.position() < target, "a glide eases toward its target");
    auto now = at(partway_ms);

    settle(motion, now);
    check(motion.position() == target, "a glide ends on its target");

    motion.setLimit(end);
    motion.place(0);
    motion.glideToEnd(at(0), viewport);
    motion.advance(at(growth_ms));
    motion.setLimit(grown);
    check(motion.towardEnd() && motion.destination() == grown, "a glide to the end follows the end as it grows");
    now = at(growth_ms);
    settle(motion, now);
    check(motion.position() == grown, "a glide to the end arrives at the latest end");
  }

  const telar::testing::Case case_wheel_eases_to_its_target{"scroll_motion.wheel_eases_to_its_target", wheelEasesToItsTarget};
  const telar::testing::Case case_precise_pixels_follow_one_to_one{"scroll_motion.precise_pixels_follow_one_to_one", precisePixelsFollowOneToOne};
  const telar::testing::Case case_release_flings{"scroll_motion.release_flings", releaseFlings};
  const telar::testing::Case case_glides_jump_close_first{"scroll_motion.glides_jump_close_first", glidesJumpCloseFirst};

}
