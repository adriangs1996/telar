module telar.gui.foundation.drawing;

import std;
import telar.base.ds;

namespace telar::gui::inline foundation::inline drawing {

  float ModalMotion::sample(ds::Option<std::uint64_t> generation, ds::Option<std::uint64_t> timestamp) noexcept {
    if (!generation) {
      *this = {};

      return 1;
    }

    if (!timestamp) {
      *this = {};
      generation_ = generation;

      return 1;
    }

    if (generation_ != generation) {
      generation_ = generation;
      started_ns_ = timestamp;
    }

    if (!started_ns_) {
      return 1;
    }

    if (*timestamp < *started_ns_) {
      return 0;
    }

    if (*timestamp - *started_ns_ >= duration_ns) {
      return 1;
    }

    const auto progress = static_cast<float>(*timestamp - *started_ns_) / static_cast<float>(duration_ns);
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  ds::Option<std::uint64_t> ModalMotion::deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!started_ns_ || (now_ns >= *started_ns_ && now_ns - *started_ns_ >= duration_ns)) {
      return {};
    }

    if (now_ns < *started_ns_) {
      return started_ns_;
    }

    return std::min(add(now_ns, interval_ns), add(*started_ns_, duration_ns));
  }

  std::uint64_t ModalMotion::add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

}
