#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>

namespace telar::gui {

struct HistoryPosition {
  std::size_t index = 0;
  std::uint64_t id = 0;

  bool operator==(const HistoryPosition &) const = default;
};

struct HistoryExpansion {
  float open = 1;
  std::optional<HistoryPosition> leaving;
  float leaving_open = 0;
};

class HistorySelectionMotion {
public:
  static constexpr std::uint64_t duration_ns = 140'000'000;

  [[nodiscard]] HistoryExpansion sample(std::optional<std::uint64_t> generation, std::optional<HistoryPosition> selected, std::optional<std::uint64_t> timestamp) noexcept {
    if (!generation || !selected) {
      *this = {};

      return {};
    }

    if (!timestamp || generation_ != generation) {
      *this = {};
      generation_ = generation;
      selected_ = *selected;

      return {};
    }

    if (selected_.index != selected->index) {
      leaving_from_ = eased(value(*timestamp));
      leaving_ = selected_;
      selected_ = *selected;
      started_ns_ = *timestamp;
      transitioning_ = true;
    } else if (selected_.id != selected->id) {
      selected_ = *selected;
      leaving_.reset();
      transitioning_ = false;
    }

    const auto open = eased(value(*timestamp));
    if (open >= 1) {
      leaving_.reset();
    }

    return {.open = open, .leaving = leaving_, .leaving_open = leaving_from_ * (1 - open)};
  }

  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns, std::uint64_t interval_ns) const noexcept {
    if (!transitioning_) {
      return {};
    }

    if (now_ns < started_ns_) {
      return started_ns_;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return {};
    }

    return std::min(add(now_ns, interval_ns), add(started_ns_, duration_ns));
  }

private:
  [[nodiscard]] static std::uint64_t add(std::uint64_t left, std::uint64_t right) noexcept {
    return left + std::min(std::numeric_limits<std::uint64_t>::max() - left, right);
  }

  [[nodiscard]] static float eased(float progress) noexcept {
    const float remaining = 1 - progress;
    const float square = remaining * remaining;
    const float cube = square * remaining;

    return 1 - cube;
  }

  [[nodiscard]] float value(std::uint64_t now_ns) const noexcept {
    if (!transitioning_) {
      return 1;
    }

    if (now_ns < started_ns_) {
      return 0;
    }

    if (now_ns - started_ns_ >= duration_ns) {
      return 1;
    }

    return static_cast<float>(now_ns - started_ns_) / static_cast<float>(duration_ns);
  }

  std::optional<std::uint64_t> generation_;
  HistoryPosition selected_;
  std::optional<HistoryPosition> leaving_;
  float leaving_from_ = 1;
  std::uint64_t started_ns_ = 0;
  bool transitioning_ = false;
};

}
